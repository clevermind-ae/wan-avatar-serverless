#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail

COMFYUI_HOST="${COMFYUI_HOST:-127.0.0.1}"
COMFYUI_PORT="${COMFYUI_PORT:-8188}"
COMFYUI_READY_TIMEOUT="${COMFYUI_READY_TIMEOUT:-600}" # seconds
COMFYUI_USE_SAGE_ATTENTION="${COMFYUI_USE_SAGE_ATTENTION:-false}"
COMFYUI_EXTRA_ARGS="${COMFYUI_EXTRA_ARGS:-}"

if [ "${DOWNLOAD_MODELS_ON_START:-true}" = "true" ]; then
    echo "Downloading models (if missing)..."
    python3 /download_models.py
fi

# Start ComfyUI in the background
echo "Starting ComfyUI in the background..."
COMFY_ARGS=(--listen 0.0.0.0 --port "${COMFYUI_PORT}")
if [ "${COMFYUI_USE_SAGE_ATTENTION}" = "true" ]; then
  COMFY_ARGS+=(--use-sage-attention)
fi
# Allow passing any additional args (space-separated) from the environment.
if [ -n "${COMFYUI_EXTRA_ARGS}" ]; then
  # shellcheck disable=SC2206
  COMFY_ARGS+=(${COMFYUI_EXTRA_ARGS})
fi
python3 -u /ComfyUI/main.py "${COMFY_ARGS[@]}" &

# Wait for ComfyUI to be ready
echo "Waiting for ComfyUI to be ready..."
wait_count=0
while [ $wait_count -lt "${COMFYUI_READY_TIMEOUT}" ]; do
    if curl -s "http://${COMFYUI_HOST}:${COMFYUI_PORT}/" > /dev/null 2>&1; then
        echo "ComfyUI is ready!"
        break
    fi
    echo "Waiting for ComfyUI... (${wait_count}/${COMFYUI_READY_TIMEOUT})"
    sleep 2
    wait_count=$((wait_count + 2))
done

if [ $wait_count -ge "${COMFYUI_READY_TIMEOUT}" ]; then
    echo "Error: ComfyUI failed to start within ${COMFYUI_READY_TIMEOUT} seconds"
    exit 1
fi

# Start the handler in the foreground
echo "Starting the handler..."
exec python handler.py
