FROM wlsdml1114/multitalk-base:1.7 as runtime

ENV HF_HUB_ENABLE_HF_TRANSFER=1 \
    HF_HUB_DISABLE_PROGRESS_BARS=1

COPY requirements.txt /requirements.txt
RUN pip install -U pip && pip install -r /requirements.txt

WORKDIR /

# Install ComfyUI
RUN git clone https://github.com/comfyanonymous/ComfyUI.git && \
    cd /ComfyUI && \
    pip install -r requirements.txt

# Custom nodes
RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/Comfy-Org/ComfyUI-Manager.git && \
    cd ComfyUI-Manager && \
    pip install -r requirements.txt

RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper && \
    cd ComfyUI-WanVideoWrapper && \
    pip install -r requirements.txt

RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/kijai/ComfyUI-KJNodes && \
    cd ComfyUI-KJNodes && \
    pip install -r requirements.txt

RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite && \
    cd ComfyUI-VideoHelperSuite && \
    pip install -r requirements.txt

RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/kijai/ComfyUI-WanAnimatePreprocess && \
    cd ComfyUI-WanAnimatePreprocess && \
    pip install -r requirements.txt

RUN cd /ComfyUI/custom_nodes && \
    git clone https://github.com/kijai/ComfyUI-segment-anything-2 && \
    git clone https://github.com/eddyhhlure1Eddy/IntelligentVRAMNode && \
    git clone https://github.com/eddyhhlure1Eddy/auto_wan2.2animate_freamtowindow_server && \
    git clone https://github.com/eddyhhlure1Eddy/ComfyUI-AdaptiveWindowSize && \
    cd ComfyUI-AdaptiveWindowSize/ComfyUI-AdaptiveWindowSize && \
    mv * ../

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
