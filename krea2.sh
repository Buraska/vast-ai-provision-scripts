#!/usr/bin/env bash

set -Eeuo pipefail
cd /workspace

if [[ -f /venv/main/bin/activate ]]; then
  set +u
  source /venv/main/bin/activate
  set -u
fi

export NVM_DIR="${NVM_DIR:-/opt/nvm}"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  set +u
  source "$NVM_DIR/nvm.sh"
  nvm use --lts >/dev/null
  set -u
fi

if ! command -v civitai >/dev/null 2>&1; then
  npm install -g @civitai/cli
fi

for binary in hf civitai curl jq sha256sum stat unzip; do
  command -v "$binary" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$binary" >&2
    exit 1
  }
done

: "${CIVITAI_TOKEN:?Set CIVITAI_TOKEN before running this provisioner}"

if [[ -n "${HF_TOKEN:-}" ]]; then
  hf auth login --token "$HF_TOKEN"
fi
hf auth whoami >/dev/null
civitai login --token "$CIVITAI_TOKEN"
civitai whoami >/dev/null

download_hf() {
  local uri="$1"
  local local_dir="$2"
  local attempt

  mkdir -p -- "$local_dir"
  for ((attempt = 1; attempt <= 5; attempt++)); do
    if hf download "$uri" --local-dir "$local_dir"; then
      return 0
    fi
    if (( attempt < 5 )); then
      printf 'Hugging Face download failed; retrying in %s seconds (attempt %s/5).\n' \
        "$((attempt * 5))" "$attempt" >&2
      sleep "$((attempt * 5))"
    fi
  done

  printf 'Hugging Face download failed after 5 attempts: %s\n' "$uri" >&2
  return 1
}

download_hf_file() {
  local repo="$1"
  local remote_path="$2"
  local destination="$3"
  local destination_dir="${destination%/*}"
  local stage_dir="$destination_dir/.${destination##*/}.hf-partial"
  local staged_file="$stage_dir/$remote_path"
  local attempt

  mkdir -p -- "$destination_dir" "$stage_dir"
  for ((attempt = 1; attempt <= 5; attempt++)); do
    if hf download "$repo" "$remote_path" --local-dir "$stage_dir"; then
      if [[ ! -s "$staged_file" ]]; then
        printf 'Hugging Face download completed without the expected file: %s\n' \
          "$staged_file" >&2
        return 1
      fi
      mv -f -- "$staged_file" "$destination"
      rm -rf -- "$stage_dir"
      return 0
    fi
    if (( attempt < 5 )); then
      printf 'Hugging Face download failed; preserving partial data and retrying in %s seconds (attempt %s/5).\n' \
        "$((attempt * 5))" "$attempt" >&2
      sleep "$((attempt * 5))"
    fi
  done

  printf 'Hugging Face download failed after 5 attempts; partial data retained at %s\n' \
    "$stage_dir" >&2
  return 1
}

download_civitai_primary() {
  local version_id="$1"
  local output_dir="$2"
  local version_json
  local file_info
  local file_id filename expected_sha expected_size
  local target part_file part_size actual_size attempt curl_ok=0

  version_json="$(civitai model-versions get "$version_id" --json)"
  file_info="$(jq -er '
    [.files[] | select(.primary == true)]
    | if length != 1 then error("expected exactly one primary file")
      else .[0] | [.id, .name, .hashes.SHA256, ((.sizeKB * 1024) | round)] | @tsv
      end
  ' <<< "$version_json")"
  IFS=$'\t' read -r file_id filename expected_sha expected_size <<< "$file_info"

  if [[ ! "$file_id" =~ ^[0-9]+$ ||
        ! "$expected_sha" =~ ^[[:xdigit:]]{64}$ ||
        ! "$expected_size" =~ ^[0-9]+$ ||
        -z "$filename" || "$filename" == */* || "$filename" == "." ||
        "$filename" == ".." || "$filename" == *$'\n'* ]]; then
    printf 'Invalid primary file metadata for Civitai version %s\n' "$version_id" >&2
    return 1
  fi

  mkdir -p -- "$output_dir"
  target="$output_dir/$filename"
  part_file="$target.part"

  if [[ -f "$target" ]] &&
     printf '%s  %s\n' "$expected_sha" "$target" | sha256sum --check --status; then
    printf 'Already verified: %s\n' "$target"
    return 0
  fi

  if [[ -f "$part_file" ]]; then
    part_size="$(stat -c '%s' "$part_file")"
    if (( part_size > expected_size )); then
      rm -f -- "$part_file"
    elif (( part_size == expected_size )); then
      if printf '%s  %s\n' "$expected_sha" "$part_file" | sha256sum --check --status; then
        mv -f -- "$part_file" "$target"
        printf 'Resumed and verified: %s\n' "$target"
        return 0
      fi
      rm -f -- "$part_file"
    fi
  fi

  printf 'Downloading Civitai version %s: %s\n' "$version_id" "$filename"
  for ((attempt = 1; attempt <= 5; attempt++)); do
    if curl --fail --show-error --location \
      --continue-at - \
      --connect-timeout 30 \
      --output "$part_file" --progress-bar \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "$CIVITAI_TOKEN") \
      "https://civitai.com/api/download/models/${version_id}?fileId=${file_id}"; then
      curl_ok=1
      break
    fi

    if [[ -f "$part_file" ]]; then
      actual_size="$(stat -c '%s' "$part_file")"
      if (( actual_size == expected_size )); then
        if printf '%s  %s\n' "$expected_sha" "$part_file" | sha256sum --check --status; then
          curl_ok=1
          break
        fi
        rm -f -- "$part_file"
      elif (( actual_size > expected_size )); then
        rm -f -- "$part_file"
      fi
    fi

    if (( attempt < 5 )); then
      printf 'Civitai transfer interrupted; resuming in %s seconds (attempt %s/5).\n' \
        "$((attempt * 5))" "$attempt" >&2
      sleep "$((attempt * 5))"
    fi
  done

  if (( curl_ok == 0 )); then
    printf 'Civitai transfer failed after 5 attempts; resumable data retained at %s\n' \
      "$part_file" >&2
    return 1
  fi

  actual_size="$(stat -c '%s' "$part_file")"
  if (( actual_size != expected_size )); then
    if (( actual_size > expected_size )); then
      rm -f -- "$part_file"
    fi
    printf 'Civitai size mismatch for %s: got %s bytes, expected %s; partial data retained when resumable.\n' \
      "$filename" "$actual_size" "$expected_size" >&2
    return 1
  fi
  if ! printf '%s  %s\n' "$expected_sha" "$part_file" | sha256sum --check --status; then
    rm -f -- "$part_file"
    printf 'Civitai SHA-256 mismatch; discarded the complete corrupt partial file: %s\n' \
      "$filename" >&2
    return 1
  fi

  mv -f -- "$part_file" "$target"
  printf 'Verified: %s\n' "$target"
}

mkdir -p \
  ./ComfyUI/models/diffusion_models \
  ./ComfyUI/models/text_encoders \
  ./ComfyUI/models/vae \
  ./ComfyUI/models/loras

# Sick Ollie Krea 2 checkpoint
download_civitai_primary 3154408 ./ComfyUI/models/diffusion_models



# Uncensored Qwen3-VL encoder
download_hf hf://ahmed22xa/Huihui-Qwen3-VL-4B-Instruct-abliterated-comfy/Huihui-Qwen3-VL-4B-Instruct-abliterated.safetensors ./ComfyUI/models/text_encoders

# Krea 2 LoRAs selected in earlier provisioning sessions; pin exact Civitai versions.
download_civitai_primary 3409322 ./ComfyUI/models/loras # General Edit V2 primary file
hf download conradlocke/krea2-identity-edit krea2_identity_edit_v2.safetensors --local-dir ./ComfyUI/models/loras# Identity Edit v1.2
download_civitai_primary 3071760 ./ComfyUI/models/loras # NSFW LoRA
download_civitai_primary 3168308 ./ComfyUI/models/loras # Mrpopo anime art
download_civitai_primary 3409158 ./ComfyUI/models/loras # IntoRealism
download_civitai_primary 3065628 ./ComfyUI/models/loras # Realism Enhancer
download_civitai_primary 3387132 ./ComfyUI/models/loras # Genderbent Draco
download_civitai_primary 3387608 ./ComfyUI/models/loras # Draconia Malfoid

# Krea 2 and Qwen assets used by the saved identity-edit workflow.
download_hf_file \
  Comfy-Org/Krea-2 \
  diffusion_models/krea2_turbo_int8_convrot.safetensors \
  ./ComfyUI/models/diffusion_models/krea2_turbo_int8_convrot.safetensors

download_hf_file \
  Comfy-Org/Krea-2 \
  text_encoders/qwen3vl_4b_fp8_scaled.safetensors \
  ./ComfyUI/models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors
download_hf_file \
  Comfy-Org/Krea-2 \
  vae/qwen_image_vae.safetensors \
  ./ComfyUI/models/vae/qwen_image_vae.safetensors
download_hf_file \
  conradlocke/krea2-identity-edit \
  krea2_identity_edit_v2.safetensors \
  ./ComfyUI/models/loras/krea2_identity_edit_v2.safetensors

# Additional Krea 2-compatible text encoder and HDR VAE from prior sessions.
download_civitai_primary 3070870 ./ComfyUI/models/text_encoders



printf 'Krea 2 assets are installed.\n'
