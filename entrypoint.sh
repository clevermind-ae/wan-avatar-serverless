#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

download_if_missing() {
    local url="$1"
    local dest="$2"
    if [ -f "$dest" ] && [ -s "$dest" ]; then
        echo "Model already present: $dest"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    echo "Downloading model: $dest"
    wget --progress=dot:giga --tries=3 --timeout=60 --waitretry=2 -O "$dest" "$url"
}

if [ "${DOWNLOAD_MODELS_ON_START:-true}" = "true" ]; then
    download_if_missing "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors" "/ComfyUI/models/vae/Wan2_1_VAE_bf16.safetensors"
    download_if_missing "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "/ComfyUI/models/clip_vision/clip_vision_h.safetensors"
    download_if_missing "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors" "/ComfyUI/models/text_encoders/umt5-xxl-enc-bf16.safetensors"
    download_if_missing "https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/Wan22Animate/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors" "/ComfyUI/models/diffusion_models/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors"
    download_if_missing "https://huggingface.co/eddy1111111/lightx2v_it2v_adaptive_fusionv_1.safetensors/resolve/main/lightx2v_elite_it2v_animate_face.safetensors" "/ComfyUI/models/loras/lightx2v_elite_it2v_animate_face.safetensors"
    download_if_missing "https://huggingface.co/eddy1111111/lightx2v_it2v_adaptive_fusionv_1.safetensors/resolve/main/WAN22_MoCap_fullbodyCOPY_ED.safetensors" "/ComfyUI/models/loras/WAN22_MoCap_fullbodyCOPY_ED.safetensors"
    download_if_missing "https://huggingface.co/eddy1111111/lightx2v_it2v_adaptive_fusionv_1.safetensors/resolve/main/FullDynamic_Ultimate_Fusion_Elite.safetensors" "/ComfyUI/models/loras/FullDynamic_Ultimate_Fusion_Elite.safetensors"
    download_if_missing "https://huggingface.co/eddy1111111/lightx2v_it2v_adaptive_fusionv_1.safetensors/resolve/main/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors" "/ComfyUI/models/loras/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors"
    download_if_missing "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx" "/ComfyUI/models/detection/yolov10m.onnx"
    download_if_missing "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx" "/ComfyUI/models/detection/vitpose_h_wholebody_model.onnx"
    download_if_missing "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin" "/ComfyUI/models/detection/vitpose_h_wholebody_data.bin"
    download_if_missing "https://huggingface.co/Kijai/sam2-safetensors/resolve/main/sam2.1_hiera_base_plus.safetensors" "/ComfyUI/models/sam2/sam2.1_hiera_base_plus.safetensors"
fi

# Start ComfyUI in the background
echo "Starting ComfyUI in the background..."
python /ComfyUI/main.py --listen --use-sage-attention &

# Wait for ComfyUI to be ready
echo "Waiting for ComfyUI to be ready..."
max_wait=120
wait_count=0
while [ $wait_count -lt $max_wait ]; do
    if curl -s http://127.0.0.1:8188/ > /dev/null 2>&1; then
        echo "ComfyUI is ready!"
        break
    fi
    echo "Waiting for ComfyUI... ($wait_count/$max_wait)"
    sleep 2
    wait_count=$((wait_count + 2))
done

if [ $wait_count -ge $max_wait ]; then
    echo "Error: ComfyUI failed to start within $max_wait seconds"
    exit 1
fi

# Start the handler in the foreground
echo "Starting the handler..."
exec python handler.py
