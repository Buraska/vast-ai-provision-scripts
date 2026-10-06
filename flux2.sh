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

mkdir -p ./models/diffusion_models/flux2 ./models/text_encoders ./models/vae ./models/upscale_models ./models/loras

hf auth login --token "$HF_TOKEN"
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
  silveroxides/FLUX.2-dev-fp8_scaled \
  flux-2-klein-9b-fp8mixed.safetensors \
  ./models/diffusion_models/flux2/flux-2-klein-9b-fp8mixed.safetensors

download_hf_file \
  Comfy-Org/flux2-klein-9B \
  split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors \
  ./models/text_encoders/qwen_3_8b_fp8mixed.safetensors

download_hf_file \
  Comfy-Org/flux2-dev \
  split_files/vae/flux2-vae.safetensors \
  ./models/vae/flux2-vae.safetensors

download_hf_file \
  uwg/upscaler \
  ESRGAN/4x_fatal_Anime_500000_G.pth \
  ./models/upscale_models/4x_fatal_Anime_500000_G.pth

civitai download 2960556 --out-dir ./models/loras
civitai download 2986256 --out-dir ./models/loras
civitai download 2792383 --out-dir ./models/loras
civitai download 2740209 --out-dir ./models/diffusion_models/flux2
civitai download 3272965 --out-dir ./models/diffusion_models/flux2
