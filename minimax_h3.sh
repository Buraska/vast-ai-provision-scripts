#!/bin/bash

set -euo pipefail
cd /workspace/ComfyUI

mkdir -p user/default

cat > user/default/comfy.settings.json <<'EOF'
{
  "Comfy.Locale": "en"
}
EOF

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

# download_hf_file \
#   Comfy-Org/MiniMax-H3 \
#   text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors \
#   ./models/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors
# hf download Qwen/Qwen3-VL-8B-Instruct --local-dir ./models/llm/Qwen3-VL-8B-Instruct

# download_hf_file \
#   Comfy-Org/MiniMax-H3 \
#   diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors \
#   ./models/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors

# download_hf_file \
#   Comfy-Org/MiniMax-H3 \
#   diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors \
#   ./models/diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors
download_hf_file \
  Comfy-Org/MiniMax-H3 \
  text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors \
  ./models/text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors

download_hf_file \
  Comfy-Org/MiniMax-H3 \
  diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors \
  ./models/diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors

  download_hf_file \
  Comfy-Org/MiniMax-H3 \
  loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors \
  ./models/loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors

download_hf_file \
  Comfy-Org/frame_interpolation \
  frame_interpolation/rife_v4.26.safetensors \
  ./models/frame_interpolation/rife_v4.26.safetensors

# download_hf_file \
#   LBH-123-AI/Minimax_h3_latent_Upscaler \
#   minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors \
#   ./models/latent_upscale_models/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors

civitai download --model 2836176 --out-dir ./models/loras
civitai download --version 3266628 --out-dir ./models/loras
# civitai download --model 2851079 --out-dir ./models/diffusion_models
# civitai download --version 3391862 --out-dir ./models/diffusion_models
civitai download --version 3392061 --out-dir ./models/diffusion_models
# h3 max ero
civitai download --version 3393047 --out-dir ./models/diffusion_models

# ero unlocked lora
civitai download --version 3354822 --out-dir ./models/loras

