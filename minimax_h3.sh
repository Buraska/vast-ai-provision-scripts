#!/bin/bash

set -euo pipefail
cd /workspace/ComfyUI
# Use the latest upstream ComfyUI master, rather than the base-image checkout.
git fetch origin master
git checkout --detach FETCH_HEAD
python -m pip install -r requirements.txt

mkdir -p user/default

cat > user/default/comfy.settings.json <<'EOF'
{
  "Comfy.Locale": "en"
}
EOF

workspace_env="${WORKSPACE:-/workspace}/.env"
mkdir -p "${workspace_env%/*}"
env_tmp="$(mktemp "${workspace_env}.XXXXXX")"
if [[ -f "$workspace_env" ]]; then
  awk -F= '$1 !~ /^[[:space:]]*(export[[:space:]]+)?COMFYUI_ARGS[[:space:]]*$/' "$workspace_env" > "$env_tmp"
fi
printf '%s\n' 'COMFYUI_ARGS="--disable-auto-launch --disable-xformers --port 18188 --enable-cors-header --enable-manager"' >> "$env_tmp"
mv "$env_tmp" "$workspace_env"

: "${HF_TOKEN:?Set HF_TOKEN in the environment before provisioning}"
: "${CIVITAI_TOKEN:?Set CIVITAI_TOKEN in the environment before provisioning}"

mkdir -p ./models/diffusion_models ./models/text_encoders ./models/vae ./models/loras ./models/checkpoints ./models/frame_interpolation ./models/latent_upscale_models

hf auth login --token "$HF_TOKEN"
export NVM_DIR=/opt/nvm
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  printf 'Vast Node.js/NVM runtime missing: %s/nvm.sh\n' "$NVM_DIR" >&2
  exit 1
fi
set +u
. "$NVM_DIR/nvm.sh"
nvm use --lts
set -u
npm install -g @civitai/cli
civitai login --token "$CIVITAI_TOKEN"

# curl and jq are required for resumable, checksum-verified Civitai downloads.
apt-get update
apt-get install -y curl ca-certificates jq

download_civitai_primary() {
  local version_id="$1"
  local output_dir="$2"
  local version_json file_info
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
        -z "$filename" || "$filename" == */* ||
        "$filename" == "." || "$filename" == ".." ||
        "$filename" == *$'\n'* ]]; then
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
    curl --fail --show-error --location --continue-at - \
      --connect-timeout 30 --output "$part_file" --progress-bar \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "$CIVITAI_TOKEN") \
      "https://civitai.com/api/download/models/${version_id}?fileId=${file_id}" || true

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
    printf 'Civitai size mismatch for %s: got %s bytes, expected %s; resumable partial retained.\n' \
      "$filename" "$actual_size" "$expected_size" >&2
    return 1
  fi
  if ! printf '%s  %s\n' "$expected_sha" "$part_file" | sha256sum --check --status; then
    rm -f -- "$part_file"
    printf 'Civitai SHA-256 mismatch; discarded the corrupt file: %s\n' "$filename" >&2
    return 1
  fi

  mv -f -- "$part_file" "$target"
  printf 'Verified: %s\n' "$target"
}


download_hf_file() {
  local repo="$1"
  local remote_path="$2"
  local destination="$3"
  local destination_dir="${destination%/*}"
  local scratch_dir

  if [[ -s "$destination" ]]; then
    printf 'Already present, skipping: %s\n' "$destination"
    return
  fi

  scratch_dir="$(mktemp -d "$destination_dir/.hf-download.XXXXXX")"
  if ! hf download "$repo" "$remote_path" --local-dir "$scratch_dir"; then
    rm -rf -- "$scratch_dir"
    return 1
  fi

  if [[ ! -s "$scratch_dir/$remote_path" ]]; then
    printf 'Expected Hugging Face download missing: %s\n' "$scratch_dir/$remote_path" >&2
    rm -rf -- "$scratch_dir"
    return 1
  fi

  mv -- "$scratch_dir/$remote_path" "$destination"
  rm -rf -- "$scratch_dir"
}


download_hf_file \
  Comfy-Org/MiniMax-H3 \
  vae/minimax_h3_video_vae_fp16.safetensors \
  ./models/vae/minimax_h3_video_vae_fp16.safetensors

download_hf_file \
  Comfy-Org/MiniMax-H3 \
  vae/minimax_h3_audio_vae_fp32.safetensors \
  ./models/vae/minimax_h3_audio_vae_fp32.safetensors

download_hf_file \
  Comfy-Org/MiniMax-H3 \
  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
  ./models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
  

download_hf_file \
  Comfy-Org/frame_interpolation \
  frame_interpolation/rife_v4.26.safetensors \
  ./models/frame_interpolation/rife_v4.26.safetensors

# download_hf_file \
#   LBH-123-AI/Minimax_h3_latent_Upscaler \
#   minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors \
#   ./models/latent_upscale_models/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors

download_civitai_primary 3303468 ./models/loras
download_civitai_primary 3266628 ./models/loras
download_civitai_primary 3354822 ./models/loras

download_civitai_primary 3257589 ./models/loras
download_civitai_primary 3283175 ./models/loras
civitai download --version 3386948 --out-dir ./ComfyUI/models/loras/ # Anime 
download_civitai_primary 3265246 ./models/loras

download_civitai_primary 3203205 ./models/loras
download_civitai_primary 3258590 ./models/loras
download_civitai_primary 3283175 ./models/loras

# h3 max ero
download_civitai_primary 3393047 ./models/diffusion_models


# Install the Gemma GGUF alongside the MiniMax H3 ComfyUI assets.
# GEMMA_REPO="okanity/gemma-4-31B-it-uncensored-heretic-GGUF"
# GEMMA_FILE="gemma-4-31B-it-uncensored-heretic-Q5_K_M.gguf"
# GEMMA_PROJECTOR_FILE="gemma-4-31B-it-mmproj-BF16.gguf"
# GEMMA_NAME="gemma4-heretic:12k-vision"
# OLLAMA_DIR="/workspace/ollama-data"
# OLLAMA_LOG="/workspace/ollama.log"
# GEMMA_PATH="/workspace/models/$GEMMA_FILE"
# GEMMA_PROJECTOR_PATH="/workspace/models/$GEMMA_PROJECTOR_FILE"

# echo "=== Checking GPU for Ollama ==="
# nvidia-smi


# mkdir -p /workspace/models "$OLLAMA_DIR"

# echo "=== Installing Ollama ==="
# if ! command -v ollama >/dev/null 2>&1; then
#   curl -fsSL https://ollama.com/install.sh | sh
# fi

# echo "=== Starting Ollama ==="
# export OLLAMA_HOST="127.0.0.1:11434"
# export OLLAMA_MODELS="$OLLAMA_DIR"
# export OLLAMA_CONTEXT_LENGTH=12288

# if command -v systemctl >/dev/null 2>&1; then
#   systemctl stop ollama 2>/dev/null || true
# fi
# pkill -x ollama 2>/dev/null || true
# sleep 2
# nohup ollama serve > "$OLLAMA_LOG" 2>&1 &
# echo $! > /workspace/ollama.pid

# echo "=== Waiting for Ollama API ==="
# READY=0
# for i in $(seq 1 60); do
#   if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
#     READY=1
#     break
#   fi
#   sleep 2
# done
# if [[ "$READY" -ne 1 ]]; then
#   echo "Ollama failed to start. Log:"
#   tail -80 "$OLLAMA_LOG"
#   exit 1
# fi

# echo "=== Downloading Gemma 4 Q5_K_M and vision projector ==="
# download_hf_file "$GEMMA_REPO" "$GEMMA_FILE" "$GEMMA_PATH"
# download_hf_file "$GEMMA_REPO" "$GEMMA_PROJECTOR_FILE" "$GEMMA_PROJECTOR_PATH"

# cat > /workspace/Modelfile.vision <<EOF
# FROM $GEMMA_PATH
# FROM $GEMMA_PROJECTOR_PATH
# PARAMETER num_ctx 12288
# PARAMETER temperature 0.7
# EOF

# echo "=== Importing Gemma vision model into Ollama ==="
# ollama create "$GEMMA_NAME" -f /workspace/Modelfile.vision
# if ! ollama show "$GEMMA_NAME" | grep -qi vision; then
#   echo "Gemma vision model was created without vision capability." >&2
#   exit 1
# fi
# ollama list

# echo "=== Testing Gemma model ==="
# curl -fsS http://127.0.0.1:11434/api/generate \
#   -H "Content-Type: application/json" \
#   -d '{
#     "model": "gemma4-heretic:12k-vision",
#     "prompt": "Say hello in Russian.",
#     "stream": false,
#     "options": {"num_ctx": 12288, "num_predict": 60}
#   }'
# echo
