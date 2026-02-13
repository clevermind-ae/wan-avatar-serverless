"""
Wan Avatar Replace — RunPod Serverless Client

Usage:
    python client.py --image photo.jpg
    python client.py --image photo.jpg --template idle-default
    python client.py --image-url https://example.com/photo.jpg --user-id user_123 --avatar-id avatar_456
"""

import argparse
import base64
import json
import os
import sys
import time

import requests
from dotenv import load_dotenv

load_dotenv()

RUNPOD_API_KEY = os.getenv("RUNPOD_API_KEY")
RUNPOD_ENDPOINT_ID = os.getenv("RUNPOD_ENDPOINT_ID")


class WanAvatarClient:
    def __init__(self, endpoint_id: str = None, api_key: str = None):
        self.endpoint_id = endpoint_id or RUNPOD_ENDPOINT_ID
        self.api_key = api_key or RUNPOD_API_KEY
        if not self.endpoint_id or not self.api_key:
            raise ValueError(
                "RUNPOD_ENDPOINT_ID and RUNPOD_API_KEY must be set "
                "(via env vars or constructor args)"
            )
        self.base_url = f"https://api.runpod.ai/v2/{self.endpoint_id}"
        self.headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

    def generate(
        self,
        image_url: str = None,
        image_base64: str = None,
        image_path: str = None,
        template_id: str = None,
        driving_video_url: str = None,
        driving_video_path: str = None,
        user_id: str = None,
        avatar_id: str = None,
        prompt: str = None,
        poll_interval: int = 10,
        max_wait: int = 900,
    ) -> dict:
        """Submit a job, poll until complete, return result."""
        payload = {}

        if image_url:
            payload["image_url"] = image_url
        elif image_base64:
            payload["image_base64"] = image_base64
        elif image_path:
            with open(image_path, "rb") as f:
                payload["image_base64"] = base64.b64encode(f.read()).decode("utf-8")
        else:
            raise ValueError("Provide image_url, image_base64, or image_path")

        if template_id:
            payload["template_id"] = template_id
        if driving_video_url:
            payload["driving_video_url"] = driving_video_url
        if driving_video_path:
            payload["driving_video_path"] = driving_video_path

        if user_id:
            payload["user_id"] = user_id
        if avatar_id:
            payload["avatar_id"] = avatar_id
        if prompt:
            payload["prompt"] = prompt

        # Submit job
        resp = requests.post(
            f"{self.base_url}/run",
            headers=self.headers,
            json={"input": payload},
        )
        resp.raise_for_status()
        job = resp.json()
        job_id = job["id"]
        print(f"Job submitted: {job_id}")

        # Poll for completion
        elapsed = 0
        while elapsed < max_wait:
            time.sleep(poll_interval)
            elapsed += poll_interval

            resp = requests.get(
                f"{self.base_url}/status/{job_id}",
                headers=self.headers,
            )
            resp.raise_for_status()
            status = resp.json()

            state = status.get("status")
            print(f"  [{elapsed}s] Status: {state}")

            if state == "COMPLETED":
                return status.get("output", {})
            elif state == "FAILED":
                raise RuntimeError(f"Job failed: {status.get('error', 'unknown')}")

        raise TimeoutError(f"Job {job_id} did not complete within {max_wait}s")

    def save_video(self, result: dict, output_path: str = "output.mp4"):
        """Save video from result to a local file."""
        if "video_base64" in result:
            with open(output_path, "wb") as f:
                f.write(base64.b64decode(result["video_base64"]))
            print(f"Saved video to {output_path}")
        elif "video_url" in result:
            resp = requests.get(result["video_url"])
            resp.raise_for_status()
            with open(output_path, "wb") as f:
                f.write(resp.content)
            print(f"Downloaded video to {output_path}")
        else:
            print("No video data in result")


def main():
    parser = argparse.ArgumentParser(description="Wan Avatar Replace Client")
    parser.add_argument("--image", help="Local image file path")
    parser.add_argument("--image-url", help="Image URL")
    parser.add_argument("--template", help="Template ID (expects /templates/<template>.mp4 in worker)")
    parser.add_argument("--driving-video-url", help="Driving video URL")
    parser.add_argument("--driving-video-path", help="Driving video object key in MinIO bucket")
    parser.add_argument("--user-id", help="User ID for MinIO path")
    parser.add_argument("--avatar-id", help="Avatar ID for MinIO path")
    parser.add_argument("--prompt", help="Custom positive prompt")
    parser.add_argument("--output", default="output.mp4", help="Output file path")
    parser.add_argument("--endpoint-id", help="RunPod endpoint ID")
    parser.add_argument("--api-key", help="RunPod API key")
    args = parser.parse_args()

    client = WanAvatarClient(
        endpoint_id=args.endpoint_id,
        api_key=args.api_key,
    )

    result = client.generate(
        image_url=args.image_url,
        image_path=args.image,
        template_id=args.template,
        driving_video_url=args.driving_video_url,
        driving_video_path=args.driving_video_path,
        user_id=args.user_id,
        avatar_id=args.avatar_id,
        prompt=args.prompt,
    )

    print(f"\nResult: {json.dumps({k: v[:80] + '...' if isinstance(v, str) and len(v) > 80 else v for k, v in result.items()}, indent=2)}")

    if "video_url" in result or "video_base64" in result:
        client.save_video(result, args.output)

    if "minio_key" in result:
        print(f"MinIO key: {result['minio_key']}")


if __name__ == "__main__":
    main()
