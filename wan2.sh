#!/bin/bash
set -e
hf auth login --token "$HF_TOKEN"

cd /workspace/ComfyUI 
npm install -g @civitai/cli 
civitai login --token "$CIVITAI_TOKEN"
civitai download --version 2540892 --out-dir ./models/diffusion_models 
civitai download --version 2540896 --out-dir ./models/diffusion_models 
hf download hf://Comfy-Org/Wan_2.2_ComfyUI_Repackaged/split_files/vae/wan_2.1_vae.safetensors --local-dir ./models/vae 
hf download hf://Comfy-Org/Wan_2.1_ComfyUI_repackaged/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors --local-dir ./models/text_encoders
wget -P ./models/clip_vision https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors 

