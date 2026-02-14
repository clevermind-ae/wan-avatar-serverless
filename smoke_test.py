import base64
import os
import subprocess
import sys
import time
import urllib.request

from minio import Minio

import handler


def wait_http(url: str, timeout_s: int = 120) -> None:
    start = time.time()
    while True:
        try:
            with urllib.request.urlopen(url, timeout=2) as resp:
                if resp.status == 200:
                    return
        except Exception:
            pass
        if time.time() - start > timeout_s:
            raise RuntimeError(f"Timeout waiting for {url}")
        time.sleep(2)


def ffprobe_props(path: str) -> dict:
    # Requires ffprobe in PATH. If absent, just skip validation.
    try:
        out = subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=width,height,avg_frame_rate",
                "-of",
                "default=noprint_wrappers=1:nokey=0",
                path,
            ],
            text=True,
        )
    except Exception:
        return {}

    props = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            props[k.strip()] = v.strip()
    return props


def main() -> int:
    endpoint = os.environ["MINIO_ENDPOINT"]
    access_key = os.environ["MINIO_ACCESS_KEY"]
    secret_key = os.environ["MINIO_SECRET_KEY"]
    bucket = os.environ.get("MINIO_BUCKET", "avatar-templates")
    secure = os.environ.get("MINIO_USE_SSL", "true").lower() == "true"

    image_key = os.environ.get("SMOKE_IMAGE_KEY", "input-avatars/w-employee-1.png")
    driving_key = os.environ.get("SMOKE_DRIVING_VIDEO_KEY", "sitting-woman/video-conference-woman.mp4")

    # Ensure ComfyUI is up before calling the handler.
    wait_http("http://127.0.0.1:8188/", timeout_s=int(os.environ.get("COMFYUI_WAIT", "240")))

    client = Minio(endpoint, access_key=access_key, secret_key=secret_key, secure=secure)
    img_bytes = client.get_object(bucket, image_key).read()

    job = {
        "input": {
            "user_id": "smoke",
            "avatar_id": "smoke",
            "image_base64": base64.b64encode(img_bytes).decode("utf-8"),
            "driving_video_path": driving_key,
        }
    }
    result = handler.handler(job)
    print(result)

    minio_key = result.get("minio_key")
    if not minio_key:
        raise RuntimeError(f"No minio_key in result: {result}")

    out_path = "/tmp/smoke_idle.mp4"
    client.fget_object(bucket, minio_key, out_path)

    props = ffprobe_props(out_path)
    if props:
        w = int(props.get("width", "0"))
        h = int(props.get("height", "0"))
        fr = props.get("avg_frame_rate", "")
        if (w, h) != (1280, 720):
            raise RuntimeError(f"Unexpected resolution: {w}x{h}")
        # avg_frame_rate is like "24/1"
        if not fr.startswith("24/"):
            raise RuntimeError(f"Unexpected fps: {fr}")
        print({"ffprobe": props})
    else:
        print("ffprobe not found; skipped validation")

    return 0


if __name__ == "__main__":
    sys.exit(main())

