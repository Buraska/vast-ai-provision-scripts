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

mkdir -p ./models/diffusion_models ./models/text_encoders ./models/vae ./models/loras ./models/loras/H3 ./models/checkpoints ./models/frame_interpolation ./models/latent_upscale_models ./models/ultralytics/bbox ./models/ultralytics/segm ./models/sams

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
echo "=== Installing custom nodes used by the workflow ==="
mkdir -p ./custom_nodes
install_custom_node() {
  local repo="$1"
  local name="$2"
  local path="${3:-./custom_nodes/$name}"

  if [[ ! -d "$path" ]]; then
    git clone --depth 1 "$repo" "$path"
  fi
  if [[ -f "$path/requirements.txt" ]]; then
    python -m pip install -r "$path/requirements.txt"
  fi
}

install_custom_node https://github.com/kijai/ComfyUI-KJNodes.git ComfyUI-KJNodes
install_custom_node https://github.com/darksidewalker/ComfyUI-DaSiWa-Nodes.git ComfyUI-DaSiWa-Nodes
install_custom_node https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git ComfyUI-Custom-Scripts
install_custom_node https://github.com/ethanfel/ComfyUI-H3-Prompt-IDE.git ComfyUI-H3-Prompt-IDE
install_custom_node https://github.com/pixaroma/ComfyUI-Pixaroma.git ComfyUI-Pixaroma
install_custom_node https://github.com/AHEKOT/ComfyUI_VNCCS_Utils.git ComfyUI_VNCCS_Utils
install_custom_node https://github.com/matlowai/ComfyUI-Dials.git ComfyUI-Dials
install_custom_node https://github.com/xm6018924/BSAI-ComfyUI-FaceRefine BSAI-ComfyUI-FaceRefine
install_custom_node https://github.com/city96/ComfyUI-GGUF.git ComfyUI-GGUF
install_custom_node https://github.com/kael558/ComfyUI-GGUF-FantasyTalking ComfyUI-GGUF-FantasyTalking
install_custom_node https://github.com/badgids/ComfyUI-H3-ExactAudioLock ComfyUI-H3-ExactAudioLock
install_custom_node https://github.com/cicalooo/ComfyUI-H3-PowerLoraStack ComfyUI-H3-PowerLoraStack
install_custom_node https://github.com/Comfy-Org/ComfyUI-Manager ComfyUI-Manager
install_custom_node https://github.com/olduvai-jp/ComfyUI-S3-IO ComfyUI-S3-IO
install_custom_node https://github.com/TripleHeadedMonkey/ComfyUI-Zlycoris ComfyUI-Zlycoris
install_custom_node https://github.com/IAMCCS/IAMCCS-nodes IAMCCS-nodes
install_custom_node https://github.com/helto4real/comfyui-all-on-one-image-generation-node comfyui-all-on-one-image-generation-node
install_custom_node https://github.com/Carasibana/ComfyUI-H3-FaceRefine comfyui-h3-facerefine
install_custom_node https://github.com/ltdrdata/ComfyUI-Impact-Pack comfyui-impact-pack
install_custom_node https://github.com/mickmumpitz/ComfyUI-Mickmumpitz-Nodes.git comfyui-mickmumpitz-nodes
install_custom_node https://github.com/stavsap/comfyui-ollama comfyui-ollama
install_custom_node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite comfyui-videohelpersuite
install_custom_node https://github.com/jtydhr88/ComfyUI-Workflow-Encrypt comfyui-workflow-encrypt
install_custom_node https://github.com/SethRobinson/comfyui-workflow-to-api-converter-endpoint comfyui-workflow-to-api-converter-endpoint
install_custom_node https://github.com/Comfy-Org/ComfyUI_Nvidia_VFX_Nodes.git comfyui_nvidia_rtx_nodes
install_custom_node https://github.com/malkuthro/ComfyUI-Koolook.git koolook
install_custom_node https://github.com/LordLocksley/ComfyUI-Lokken-VideoTools.git lokken-videotools
install_custom_node https://github.com/Pikselkroken/ComfyUI-PixlStash.git pixlstash
install_custom_node https://github.com/rgthree/rgthree-comfy.git rgthree-comfy

# The repository contains the NativeAudioLock node in a nested custom_nodes folder.
# Keep the workflow repository outside custom_nodes, then install only the actual node.
native_audio_source=./provision_sources/MiniMax-H3-NativeAudio-MusicVideo-Workflow
mkdir -p ./provision_sources
install_custom_node https://github.com/Shrek3OnVH5/MiniMax-H3-NativeAudio-MusicVideo-Workflow MiniMax-H3-NativeAudio-MusicVideo-Workflow "$native_audio_source"
mkdir -p ./custom_nodes/ComfyUI-H3-NativeAudioLock
cp -a "$native_audio_source/custom_nodes/ComfyUI-H3-NativeAudioLock/." ./custom_nodes/ComfyUI-H3-NativeAudioLock/

cat > ./custom_nodes/h3_director_guide_size.py <<'PY'
class H3DirectorGuideAtSize:
    """Build a second Director guide without changing the first pass."""

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "guide": ("MINIMAX_H3_DIRECTOR_GUIDE",),
            "width": ("INT", {"min": 32, "max": 16384, "step": 32}),
            "height": ("INT", {"min": 32, "max": 16384, "step": 32}),
        }}

    RETURN_TYPES = ("MINIMAX_H3_DIRECTOR_GUIDE",)
    FUNCTION = "resize_guide"
    CATEGORY = "conditioning/minimax"

    def resize_guide(self, guide, width, height):
        if not isinstance(guide, dict):
            raise ValueError("Expected a MiniMax H3 Director guide.")
        if width < 32 or height < 32 or width % 32 or height % 32:
            raise ValueError("Pass 2 dimensions must be positive multiples of 32.")
        continuity = guide.get("continuity") or {}
        if continuity.get("operation") == "continue":
            raise ValueError("Pass 2 Director conditioning does not support continuation. Use H3 Tiled Upscale for continuation.")
        resized = {**guide, "width": width, "height": height}
        resized.pop("continuity", None)
        return (resized,)


NODE_CLASS_MAPPINGS = {"H3DirectorGuideAtSize": H3DirectorGuideAtSize}
NODE_DISPLAY_NAME_MAPPINGS = {"H3DirectorGuideAtSize": "H3 Director Guide at Size"}
PY

cat > ./custom_nodes/websocket_image_save.py <<'PY'
from PIL import Image
import numpy as np
import comfy.utils
import time


class SaveImageWebsocket:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"images": ("IMAGE",)}}

    RETURN_TYPES = ()
    FUNCTION = "save_images"
    OUTPUT_NODE = True
    CATEGORY = "image"

    def save_images(self, images):
        pbar = comfy.utils.ProgressBar(images.shape[0])
        for step, image in enumerate(images):
            pixels = 255.0 * image.cpu().numpy()
            img = Image.fromarray(np.clip(pixels, 0, 255).astype(np.uint8))
            pbar.update_absolute(step, images.shape[0], ("PNG", img, None))
        return {}

    @classmethod
    def IS_CHANGED(cls, images):
        return time.time()


NODE_CLASS_MAPPINGS = {"SaveImageWebsocket": SaveImageWebsocket}
NODE_DISPLAY_NAME_MAPPINGS = {"SaveImageWebsocket": "Save Image (Websocket)"}
PY


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
  vae/minimax_h3_audio_vae_fp32.safetensors \
  ./models/vae/minimax_h3_audio_vae_fp32.safetensors

download_hf_file \
  Comfy-Org/MiniMax-H3 \
  text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
  ./models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors

# MiniMax H3 Image model and VAE
# download_hf_file \
#   Comfy-Org/MiniMax-H3-Image \
#   diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors \
#   ./models/diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors


  

download_hf_file \
  Comfy-Org/frame_interpolation \
  frame_interpolation/rife_v4.26.safetensors \
  ./models/frame_interpolation/rife_v4.26.safetensors

download_hf_file \
  LBH-123-AI/Minimax_h3_latent_Upscaler \
  minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors \
  ./models/latent_upscale_models/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors
download_hf_file \
  LBH-123-AI/Minimax_h3_latent_Upscaler \
  minimax_h3_latent_upscaler_2d_conv_v1/minimax_h3_latent_upscaler_2d_conv_v1_fp16.safetensors \
  ./models/latent_upscale_models/minimax_h3_latent_upscaler_2d_conv_v1_fp16.safetensors

download_civitai_primary 3303468 ./models/loras
download_civitai_primary 3266628 ./models/loras
download_civitai_primary 3354822 ./models/loras

download_civitai_primary 3257589 ./models/loras
download_civitai_primary 3283175 ./models/loras
download_civitai_primary 3386948 ./models/loras # Anime
download_civitai_primary 3408385 ./models/loras

download_civitai_primary 3203205 ./models/loras
download_civitai_primary 3258590 ./models/loras
 
# hf download hf://Comfy-Org/MiniMax-H3/loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors --local-dir ./ComfyUI/models/loras/
# h3 max 
download_civitai_primary 3429412 ./models/diffusion_models
# Dials loras for ComfyUI-Dials custom node

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_arcane_sigils.safetensors \
  ./models/loras/h3_arcane_sigils.safetensors || echo '[provision] download failed: h3_arcane_sigils, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_aura.safetensors \
  ./models/loras/h3_aura.safetensors || echo '[provision] download failed: h3_aura, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_blur_moving_edges_hook.safetensors \
  ./models/loras/h3_blur_moving_edges_hook.safetensors || echo '[provision] download failed: h3_blur_moving_edges_hook, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_colour_drain.safetensors \
  ./models/loras/h3_colour_drain.safetensors || echo '[provision] download failed: h3_colour_drain, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_dramatic_light.safetensors \
  ./models/loras/h3_dramatic_light.safetensors || echo '[provision] download failed: h3_dramatic_light, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_evil_cold.safetensors \
  ./models/loras/h3_evil_cold.safetensors || echo '[provision] download failed: h3_evil_cold, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_evil_corrupted.safetensors \
  ./models/loras/h3_evil_corrupted.safetensors || echo '[provision] download failed: h3_evil_corrupted, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_evil_creepy.safetensors \
  ./models/loras/h3_evil_creepy.safetensors || echo '[provision] download failed: h3_evil_creepy, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_evil_dread.safetensors \
  ./models/loras/h3_evil_dread.safetensors || echo '[provision] download failed: h3_evil_dread, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_evil_impish.safetensors \
  ./models/loras/h3_evil_impish.safetensors || echo '[provision] download failed: h3_evil_impish, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_evil_seductive.safetensors \
  ./models/loras/h3_evil_seductive.safetensors || echo '[provision] download failed: h3_evil_seductive, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_evil_sinister.safetensors \
  ./models/loras/h3_evil_sinister.safetensors || echo '[provision] download failed: h3_evil_sinister, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_evil_unhinged.safetensors \
  ./models/loras/h3_evil_unhinged.safetensors || echo '[provision] download failed: h3_evil_unhinged, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_impact_frame.safetensors \
  ./models/loras/h3_impact_frame.safetensors || echo '[provision] download failed: h3_impact_frame, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_ink_wash.safetensors \
  ./models/loras/h3_ink_wash.safetensors || echo '[provision] download failed: h3_ink_wash, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_motion.safetensors \
  ./models/loras/h3_motion.safetensors || echo '[provision] download failed: h3_motion, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_motion_lora.safetensors \
  ./models/loras/h3_motion_lora.safetensors || echo '[provision] download failed: h3_motion_lora, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_psychedelic.safetensors \
  ./models/loras/h3_psychedelic.safetensors || echo '[provision] download failed: h3_psychedelic, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_space_warp.safetensors \
  ./models/loras/h3_space_warp.safetensors || echo '[provision] download failed: h3_space_warp, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_storm.safetensors \
  ./models/loras/h3_storm.safetensors || echo '[provision] download failed: h3_storm, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_x_datamosh.safetensors \
  ./models/loras/h3_x_datamosh.safetensors || echo '[provision] download failed: h3_x_datamosh, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_x_film_artifact.safetensors \
  ./models/loras/h3_x_film_artifact.safetensors || echo '[provision] download failed: h3_x_film_artifact, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_x_memory_present.safetensors \
  ./models/loras/h3_x_memory_present.safetensors || echo '[provision] download failed: h3_x_memory_present, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_x_oil_pixel.safetensors \
  ./models/loras/h3_x_oil_pixel.safetensors || echo '[provision] download failed: h3_x_oil_pixel, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_x_order_entropy.safetensors \
  ./models/loras/h3_x_order_entropy.safetensors || echo '[provision] download failed: h3_x_order_entropy, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_x_owl_octopus.safetensors \
  ./models/loras/h3_x_owl_octopus.safetensors || echo '[provision] download failed: h3_x_owl_octopus, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_x_silentfilm_cyberpunk.safetensors \
  ./models/loras/h3_x_silentfilm_cyberpunk.safetensors || echo '[provision] download failed: h3_x_silentfilm_cyberpunk, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_x_sinister_noview.safetensors \
  ./models/loras/h3_x_sinister_noview.safetensors || echo '[provision] download failed: h3_x_sinister_noview, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_x_template_placebo.safetensors \
  ./models/loras/h3_x_template_placebo.safetensors || echo '[provision] download failed: h3_x_template_placebo, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_x_vhs.safetensors \
  ./models/loras/h3_x_vhs.safetensors || echo '[provision] download failed: h3_x_vhs, continuing' >&2

download_hf_file \
  Comfy-Org/MiniMax-H3 \
  vae/minimax_h3_video_vae_int8_convrot.safetensors   \
  ./models/vae/minimax_h3_video_vae_int8_convrot.safetensors   || echo '[provision] download failed: minimax_h3_video_vae_int8.safetensors , continuing' >&2

download_civitai_primary 3421124 ./models/loras || echo '[provision] download failed: [MMH3] Realism Slider - v1.0, continuing' >&2 # [MMH3] Realism Slider - v1.0

install_custom_node https://github.com/LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler Comfyui_Minimax_h3_latent_Upscaler

h3_model_file=./models/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors
h3_misplaced_model=./models/diffusion_models/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors
if [[ ! -s "$h3_model_file" && -s "$h3_misplaced_model" ]]; then
  mv -- "$h3_misplaced_model" "$h3_model_file"
fi

download_hf_file \
  Comfy-Org/MiniMax-H3 \
  diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors \
  ./models/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors || echo '[provision] download failed: minimax_h3_fl2va_pruned_int8_convrot.safetensors, continuing' >&2

download_hf_file \
  Comfy-Org/MiniMax-H3 \
  loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors \
  ./models/loras/H3/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors || echo '[provision] download failed: minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors, continuing' >&2

download_hf_file \
  Bingsu/adetailer \
  face_yolov8m.pt \
  ./models/ultralytics/bbox/face_yolov8m.pt || echo '[provision] download failed: face_yolov8m.pt, continuing' >&2

download_hf_file \
  Bingsu/adetailer \
  person_yolov8m-seg.pt \
  ./models/ultralytics/segm/person_yolov8m-seg.pt || echo '[provision] download failed: person_yolov8m-seg.pt, continuing' >&2

download_hf_file \
  MATLOWAI/H3-Dials \
  dials/h3_motion.safetensors \
  ./models/loras/h3_motion.safetensors || echo '[provision] download failed: h3_motion.safetensors, continuing' >&2

if [[ ! -s ./models/sams/sam_vit_b_01ec64.pth ]]; then
  curl --fail --location --retry 4 --retry-all-errors \
    https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth \
    -o ./models/sams/sam_vit_b_01ec64.pth
fi




# MiniMax H3 Singularity Ref2VA v2 INT8



# GEMMA_REPO="okanity/gemma-4-31B-it-uncensored-heretic-GGUF"
# # GEMMA_FILE="gemma-4-31B-it-uncensored-heretic-Q4_K_M.gguf" 
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
# hf download "$GEMMA_REPO" "$GEMMA_FILE" \
#   --local-dir "$(dirname "$GEMMA_PATH")"

# hf download "$GEMMA_REPO" "$GEMMA_PROJECTOR_FILE" \
#   --local-dir "$(dirname "$GEMMA_PROJECTOR_PATH")"

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
