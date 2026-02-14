#!/usr/bin/env bash
set -euo pipefail

# Runtime installer for ComfyUI + required custom nodes + model downloader.
# Intended usage inside a debug pod where the main container command is "sleep infinity".
#
# Example:
#   bash -lc /bootstrap_comfyui.sh
#   DOWNLOAD_MODELS_ON_START=true bash -lc /entrypoint.sh

if ! command -v git >/dev/null 2>&1; then
  echo "git not found in image; this base image is expected to include it."
  exit 1
fi

if [ ! -d /ComfyUI ]; then
  echo "Cloning ComfyUI..."
  git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI
fi

echo "Installing ComfyUI requirements..."
python3 -m pip install -r /ComfyUI/requirements.txt

mkdir -p /ComfyUI/custom_nodes
cd /ComfyUI/custom_nodes

clone_or_update() {
  local url="$1"
  local dir="$2"
  if [ -d "$dir/.git" ]; then
    echo "Updating $dir..."
    git -C "$dir" fetch --all -p
    git -C "$dir" reset --hard origin/HEAD || true
  else
    echo "Cloning $dir..."
    git clone "$url" "$dir"
  fi
}

clone_or_update https://github.com/Comfy-Org/ComfyUI-Manager.git ComfyUI-Manager
python3 -m pip install -r /ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt

clone_or_update https://github.com/kijai/ComfyUI-WanVideoWrapper ComfyUI-WanVideoWrapper
python3 -m pip install -r /ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt

clone_or_update https://github.com/kijai/ComfyUI-KJNodes ComfyUI-KJNodes
python3 -m pip install -r /ComfyUI/custom_nodes/ComfyUI-KJNodes/requirements.txt

clone_or_update https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite ComfyUI-VideoHelperSuite
python3 -m pip install -r /ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt

clone_or_update https://github.com/kijai/ComfyUI-WanAnimatePreprocess ComfyUI-WanAnimatePreprocess
python3 -m pip install -r /ComfyUI/custom_nodes/ComfyUI-WanAnimatePreprocess/requirements.txt

clone_or_update https://github.com/kijai/ComfyUI-segment-anything-2 ComfyUI-segment-anything-2
clone_or_update https://github.com/eddyhhlure1Eddy/IntelligentVRAMNode IntelligentVRAMNode
clone_or_update https://github.com/eddyhhlure1Eddy/auto_wan2.2animate_freamtowindow_server auto_wan2.2animate_freamtowindow_server
clone_or_update https://github.com/eddyhhlure1Eddy/ComfyUI-AdaptiveWindowSize ComfyUI-AdaptiveWindowSize

if [ -d /ComfyUI/custom_nodes/ComfyUI-AdaptiveWindowSize/ComfyUI-AdaptiveWindowSize ]; then
  echo "Fixing ComfyUI-AdaptiveWindowSize layout..."
  cd /ComfyUI/custom_nodes/ComfyUI-AdaptiveWindowSize/ComfyUI-AdaptiveWindowSize
  mv -f ./* ../ || true
fi

echo "Pinning onnxruntime-gpu==1.22.0 (as in Dockerfile)..."
python3 -m pip install --upgrade onnxruntime-gpu==1.22.0

mkdir -p /ComfyUI/user/default/ComfyUI-Manager
cp -f /config.ini /ComfyUI/user/default/ComfyUI-Manager/config.ini

echo "Bootstrap complete."

