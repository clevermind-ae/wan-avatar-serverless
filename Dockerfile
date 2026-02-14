FROM runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404 as runtime

# NOTE:
# - Phase B (low risk): models are downloaded at runtime on cold start.
# - For Phase A (later): set HF_HOME to /runpod-volume/huggingface-cache to leverage cached models.

ENV HF_HUB_ENABLE_HF_TRANSFER=1 \
    HF_HUB_DISABLE_PROGRESS_BARS=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1

COPY requirements.txt /requirements.txt
RUN pip install -U pip && pip install -r /requirements.txt

WORKDIR /

# System deps used by ComfyUI + video pipelines.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git \
      curl \
      ffmpeg \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pin source checkouts so builds are reproducible.
ARG COMFYUI_COMMIT=dc9822b7df4785e77690e93b0e09feaff01e2e12
ARG COMFYUI_MANAGER_COMMIT=77377eeddb3d81867c062f1bee122a395e2e8278
ARG WAN_WRAPPER_COMMIT=3d7b49e2df66bbbe379cd54748baf9decfe678a2
ARG KJ_NODES_COMMIT=50a0837f9aea602b184bbf6dbabf66ed2c7a1d22
ARG VHS_COMMIT=993082e4f2473bf4acaf06f51e33877a7eb38960
ARG WAN_PREPROCESS_COMMIT=1a35b81a418bbba093356ad19b19bf2a76a24f4e
ARG SAM2_NODE_COMMIT=0c35fff5f382803e2310103357b5e985f5437f32
ARG INTELLIGENT_VRAM_COMMIT=3a3fdb41c1b0e01545d9d394304adc846cdde52b
ARG AUTO_WAN_COMMIT=d4f7e6294fc8d1f38c8b3acdb520c64d983099a1
ARG ADAPTIVE_WINDOW_COMMIT=6c46e055f63b031324a0d19f6e2adebcbe76b90b

# Install ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git && \
    cd /ComfyUI && \
    git checkout "${COMFYUI_COMMIT}" && \
    pip install -r requirements.txt

# Custom nodes
RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/Comfy-Org/ComfyUI-Manager.git && \
    cd ComfyUI-Manager && \
    git checkout "${COMFYUI_MANAGER_COMMIT}" && \
    pip install -r requirements.txt

RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper && \
    cd ComfyUI-WanVideoWrapper && \
    git checkout "${WAN_WRAPPER_COMMIT}" && \
    pip install -r requirements.txt

RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/kijai/ComfyUI-KJNodes && \
    cd ComfyUI-KJNodes && \
    git checkout "${KJ_NODES_COMMIT}" && \
    pip install -r requirements.txt

RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite && \
    cd ComfyUI-VideoHelperSuite && \
    git checkout "${VHS_COMMIT}" && \
    pip install -r requirements.txt

RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/kijai/ComfyUI-WanAnimatePreprocess && \
    cd ComfyUI-WanAnimatePreprocess && \
    git checkout "${WAN_PREPROCESS_COMMIT}" && \
    pip install -r requirements.txt

RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/kijai/ComfyUI-segment-anything-2 && \
    cd ComfyUI-segment-anything-2 && \
    git checkout "${SAM2_NODE_COMMIT}" && \
    cd .. && \
    git clone https://github.com/eddyhhlure1Eddy/IntelligentVRAMNode && \
    cd IntelligentVRAMNode && \
    git checkout "${INTELLIGENT_VRAM_COMMIT}" && \
    cd .. && \
    git clone https://github.com/eddyhhlure1Eddy/auto_wan2.2animate_freamtowindow_server && \
    cd auto_wan2.2animate_freamtowindow_server && \
    git checkout "${AUTO_WAN_COMMIT}" && \
    cd .. && \
    git clone https://github.com/eddyhhlure1Eddy/ComfyUI-AdaptiveWindowSize && \
    cd ComfyUI-AdaptiveWindowSize && \
    git checkout "${ADAPTIVE_WINDOW_COMMIT}" && \
    if [ -d "/ComfyUI/custom_nodes/ComfyUI-AdaptiveWindowSize/ComfyUI-AdaptiveWindowSize" ]; then \
      cd /ComfyUI/custom_nodes/ComfyUI-AdaptiveWindowSize/ComfyUI-AdaptiveWindowSize && \
      mv * ../ ; \
    fi

RUN pip install --upgrade onnxruntime-gpu==1.22

# Keep image lean: model files are fetched at container startup when missing.

# Copy project files
COPY handler.py /handler.py
COPY download_models.py /download_models.py
COPY workflow_replace.json /workflow_replace.json
COPY entrypoint.sh /entrypoint.sh
COPY config.ini /config.ini
COPY templates/ /templates/

RUN mkdir -p /ComfyUI/user/__manager
COPY config.ini /ComfyUI/user/__manager/config.ini
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
