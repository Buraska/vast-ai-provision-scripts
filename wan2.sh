#!/bin/bash

set -euo pipefail
cd /workspace/ComfyUI

mkdir -p user/default

cat > user/default/comfy.settings.json <<'EOF'
{
  "Comfy.Locale": "en"
}
EOF

hf auth login --token "$HF_TOKEN"

mkdir -p ./models/diffusion_models ./models/vae ./models/text_encoders ./models/clip_vision ./models/upscale_models

npm install -g @civitai/cli
civitai login --token "$CIVITAI_TOKEN"
civitai download --version 2540892 --out-dir ./models/diffusion_models 
civitai download --version 2540896 --out-dir ./models/diffusion_models 
## REGULAR
# civitai download --version 2668710 --out-dir ./models/diffusion_models 
# civitai download --version 2668712 --out-dir ./models/diffusion_models 

hf download hf://Comfy-Org/Wan_2.2_ComfyUI_Repackaged/split_files/vae/wan_2.1_vae.safetensors --local-dir ./models/vae 
hf download hf://Comfy-Org/Wan_2.1_ComfyUI_repackaged/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors --local-dir ./models/text_encoders
wget -P ./models/clip_vision https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors 

hf download hf://gemasai/4x_NMKD-Siax_200k/4x_NMKD-Siax_200k.pth --local-dir ./models/upscale_models

wget -P ./models/clip_vision https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors 


civitai download --version 2152516 --out-dir ./models/loras
civitai download --version 2152583 --out-dir ./models/loras

civitai download --version 2553271 --out-dir ./models/loras
civitai download --version 2553151 --out-dir ./models/loras

civitai download --version 2235288 --out-dir ./models/loras
civitai download --version 2235299 --out-dir ./models/loras

civitai download --version 2121297 --out-dir ./models/loras

civitai download --version 2352366 --out-dir ./models/loras 
civitai download --version 2352388 --out-dir ./models/loras 

civitai download --model 1869475 --out-dir ./models/loras 
civitai download --version 2116008 --out-dir ./models/loras 
