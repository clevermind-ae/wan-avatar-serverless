import os

# These env vars must be set before importing huggingface_hub to reliably disable progress bars.
os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

import shutil
from dataclasses import dataclass

from huggingface_hub import hf_hub_download


@dataclass(frozen=True)
class ModelSpec:
    repo_id: str
    filename: str
    dest_path: str
    revision: str = "main"


def _link_or_copy(src: str, dest: str) -> None:
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return
    # huggingface_hub may return a symlink inside the snapshot; ComfyUI model discovery
    # can reject broken links. Resolve to the underlying blob file before linking/copying.
    src_real = os.path.realpath(src)
    tmp = dest + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    try:
        # Hardlink avoids double disk usage if cache + dest on same filesystem.
        os.link(src_real, tmp)
    except OSError:
        shutil.copy2(src_real, tmp)
    os.replace(tmp, dest)


def download_models() -> None:
    specs = [
        ModelSpec(
            repo_id="Kijai/WanVideo_comfy",
            filename="Wan2_1_VAE_bf16.safetensors",
            dest_path="/ComfyUI/models/vae/Wan2_1_VAE_bf16.safetensors",
        ),
        ModelSpec(
            repo_id="Comfy-Org/Wan_2.1_ComfyUI_repackaged",
            filename="split_files/clip_vision/clip_vision_h.safetensors",
            dest_path="/ComfyUI/models/clip_vision/clip_vision_h.safetensors",
        ),
        ModelSpec(
            repo_id="Kijai/WanVideo_comfy",
            filename="umt5-xxl-enc-bf16.safetensors",
            dest_path="/ComfyUI/models/text_encoders/umt5-xxl-enc-bf16.safetensors",
        ),
        ModelSpec(
            repo_id="Kijai/WanVideo_comfy_fp8_scaled",
            filename="Wan22Animate/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors",
            dest_path="/ComfyUI/models/diffusion_models/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors",
        ),
        ModelSpec(
            repo_id="eddy1111111/lightx2v_it2v_adaptive_fusionv_1.safetensors",
            filename="lightx2v_elite_it2v_animate_face.safetensors",
            dest_path="/ComfyUI/models/loras/lightx2v_elite_it2v_animate_face.safetensors",
        ),
        ModelSpec(
            repo_id="eddy1111111/lightx2v_it2v_adaptive_fusionv_1.safetensors",
            filename="WAN22_MoCap_fullbodyCOPY_ED.safetensors",
            dest_path="/ComfyUI/models/loras/WAN22_MoCap_fullbodyCOPY_ED.safetensors",
        ),
        ModelSpec(
            repo_id="eddy1111111/lightx2v_it2v_adaptive_fusionv_1.safetensors",
            filename="FullDynamic_Ultimate_Fusion_Elite.safetensors",
            dest_path="/ComfyUI/models/loras/FullDynamic_Ultimate_Fusion_Elite.safetensors",
        ),
        ModelSpec(
            repo_id="eddy1111111/lightx2v_it2v_adaptive_fusionv_1.safetensors",
            filename="Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors",
            dest_path="/ComfyUI/models/loras/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors",
        ),
        ModelSpec(
            repo_id="Wan-AI/Wan2.2-Animate-14B",
            filename="process_checkpoint/det/yolov10m.onnx",
            dest_path="/ComfyUI/models/detection/yolov10m.onnx",
        ),
        ModelSpec(
            repo_id="Kijai/vitpose_comfy",
            filename="onnx/vitpose_h_wholebody_model.onnx",
            dest_path="/ComfyUI/models/detection/vitpose_h_wholebody_model.onnx",
        ),
        ModelSpec(
            repo_id="Kijai/vitpose_comfy",
            filename="onnx/vitpose_h_wholebody_data.bin",
            dest_path="/ComfyUI/models/detection/vitpose_h_wholebody_data.bin",
        ),
        ModelSpec(
            repo_id="Kijai/sam2-safetensors",
            filename="sam2.1_hiera_base_plus.safetensors",
            dest_path="/ComfyUI/models/sam2/sam2.1_hiera_base_plus.safetensors",
        ),
    ]

    for spec in specs:
        if os.path.exists(spec.dest_path) and os.path.getsize(spec.dest_path) > 0:
            print(f"[models] present: {spec.dest_path}", flush=True)
            continue

        print(f"[models] downloading: {spec.repo_id}::{spec.filename}", flush=True)
        cached = hf_hub_download(
            repo_id=spec.repo_id,
            filename=spec.filename,
            revision=spec.revision,
        )
        _link_or_copy(cached, spec.dest_path)
        print(f"[models] ready: {spec.dest_path}", flush=True)


if __name__ == "__main__":
    download_models()
