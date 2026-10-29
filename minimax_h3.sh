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

civitai download --model 2836176 --out-dir ./models/loras
civitai download --version 3266628 --out-dir ./models/loras
civitai download --version 3354822 --out-dir ./models/loras

civitai download --version 3257589 --out-dir ./models/loras
civitai download --version 3283175 --out-dir ./models/loras

civitai download --version 3265246 --out-dir ./models/loras

# h3 max ero
civitai download --version 3393047 --out-dir ./models/diffusion_models


# Install the Gemma GGUF alongside the MiniMax H3 ComfyUI assets.
GEMMA_REPO="okanity/gemma-4-31B-it-uncensored-heretic-GGUF"
GEMMA_FILE="gemma-4-31B-it-uncensored-heretic-Q5_K_M.gguf"
GEMMA_PROJECTOR_FILE="gemma-4-31B-it-mmproj-BF16.gguf"
GEMMA_NAME="gemma4-heretic:12k-vision"
OLLAMA_DIR="/workspace/ollama-data"
OLLAMA_LOG="/workspace/ollama.log"
GEMMA_PATH="/workspace/models/$GEMMA_FILE"
GEMMA_PROJECTOR_PATH="/workspace/models/$GEMMA_PROJECTOR_FILE"

echo "=== Checking GPU for Ollama ==="
nvidia-smi

echo "=== Installing Ollama dependencies ==="
apt-get update
apt-get install -y curl ca-certificates

mkdir -p /workspace/models "$OLLAMA_DIR"

echo "=== Installing Ollama ==="
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi

echo "=== Starting Ollama ==="
export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_MODELS="$OLLAMA_DIR"
export OLLAMA_CONTEXT_LENGTH=12288

if command -v systemctl >/dev/null 2>&1; then
  systemctl stop ollama 2>/dev/null || true
fi
pkill -x ollama 2>/dev/null || true
sleep 2
nohup ollama serve > "$OLLAMA_LOG" 2>&1 &
echo $! > /workspace/ollama.pid

echo "=== Waiting for Ollama API ==="
READY=0
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
if [[ "$READY" -ne 1 ]]; then
  echo "Ollama failed to start. Log:"
  tail -80 "$OLLAMA_LOG"
  exit 1
fi

echo "=== Downloading Gemma 4 Q5_K_M and vision projector ==="
download_hf_file "$GEMMA_REPO" "$GEMMA_FILE" "$GEMMA_PATH"
download_hf_file "$GEMMA_REPO" "$GEMMA_PROJECTOR_FILE" "$GEMMA_PROJECTOR_PATH"

cat > /workspace/Modelfile.vision <<EOF
FROM $GEMMA_PATH
FROM $GEMMA_PROJECTOR_PATH
PARAMETER num_ctx 12288
PARAMETER temperature 0.7
EOF

echo "=== Importing Gemma vision model into Ollama ==="
ollama create "$GEMMA_NAME" -f /workspace/Modelfile.vision
if ! ollama show "$GEMMA_NAME" | grep -qi vision; then
  echo "Gemma vision model was created without vision capability." >&2
  exit 1
fi
ollama list

echo "=== Testing Gemma model ==="
curl -fsS http://127.0.0.1:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-heretic:12k-vision",
    "prompt": "Say hello in Russian.",
    "stream": false,
    "options": {"num_ctx": 12288, "num_predict": 60}
  }'
echo
