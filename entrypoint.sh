#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail

COMFYUI_HOST="${COMFYUI_HOST:-127.0.0.1}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"

if [ "${DOWNLOAD_MODELS_ON_START:-true}" = "true" ]; then
    echo "Downloading models (if missing)..."
    python3 /download_models.py
fi

# Start ComfyUI in the background
echo "Starting ComfyUI in the background..."
python3 /ComfyUI/main.py --listen 0.0.0.0 --port "${COMFYUI_PORT}" --use-sage-attention &

# Wait for ComfyUI to be ready
echo "Waiting for ComfyUI to be ready..."
max_wait=120
wait_count=0
while [ $wait_count -lt $max_wait ]; do
    if curl -s "http://${COMFYUI_HOST}:${COMFYUI_PORT}/" > /dev/null 2>&1; then
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
