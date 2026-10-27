#!/usr/bin/env bash

set -euo pipefail
cd /workspace

hf auth whoami >/dev/null
civitai whoami >/dev/null

# Sick Ollie Krea 2 checkpoint
civitai download --version 3154408 --out-dir ./ComfyUI/models/diffusion_models

# Official Krea 2 BF16 diffusion model
hf download hf://Comfy-Org/Krea-2/diffusion_models/krea2_turbo_bf16.safetensors --local-dir ./ComfyUI/models/diffusion_models

# Krea 2 — Qwen3-VL 4B text encoders
hf download hf://Comfy-Org/Krea-2/text_encoders/qwen3vl_4b_bf16.safetensors --local-dir ./ComfyUI/models/text_encoders
hf download hf://Comfy-Org/Krea-2/text_encoders/qwen3vl_4b_fp8_scaled.safetensors --local-dir ./ComfyUI/models/text_encoders

# Wan 2.1 VAE
hf download hf://Comfy-Org/Wan_2.1_ComfyUI_repackaged/split_files/vae/wan_2.1_vae.safetensors --local-dir ./ComfyUI/models/vae

# Uncensored Qwen3-VL encoder
hf download hf://ahmed22xa/Huihui-Qwen3-VL-4B-Instruct-abliterated-comfy/Huihui-Qwen3-VL-4B-Instruct-abliterated.safetensors --local-dir ./ComfyUI/models/text_encoders
civitai download --model 2731465 --out-dir ./ComfyUI/models/text_encoders

# Krea 2 LoRAs
civitai download --model 2761113 --out-dir ./ComfyUI/models/loras
civitai download --version 3071760 --out-dir ./ComfyUI/models/loras
civitai download --version 3168308 --out-dir ./ComfyUI/models/loras

# Qwen Image VAE
wget -P ./ComfyUI/models/vae https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors

# PornMaster Krea2 I2I workflow
civitai download --version 3140696 --out-dir ./ComfyUI/user/default/workflows
unzip -o ./ComfyUI/user/default/workflows/pornmasterKrea2I2i_rawTurboV1.zip -d ./ComfyUI/user/default/workflows
