#!/usr/bin/env bash

set -euo pipefail
cd /workspace

hf auth whoami >/dev/null
civitai whoami >/dev/null

# Sick Ollie Krea 2 checkpoint
civitai download --version 3154408 --out-dir ./ComfyUI/models/diffusion_models


# Wan 2.1 VAE
hf download hf://Comfy-Org/Wan_2.1_ComfyUI_repackaged/split_files/vae/wan_2.1_vae.safetensors --local-dir ./ComfyUI/models/vae

# Uncensored Qwen3-VL encoder
hf download hf://ahmed22xa/Huihui-Qwen3-VL-4B-Instruct-abliterated-comfy/Huihui-Qwen3-VL-4B-Instruct-abliterated.safetensors --local-dir ./ComfyUI/models/text_encoders

# Krea 2 LoRAs
civitai download --model 2761113 --out-dir ./ComfyUI/models/loras
civitai download --version 3071760 --out-dir ./ComfyUI/models/loras
civitai download --version 3168308 --out-dir ./ComfyUI/models/loras

# Qwen Image VAE
wget -P ./ComfyUI/models/vae https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors

