import base64
import os
import time
from dataclasses import dataclass

from minio import Minio

import handler


@dataclass(frozen=True)
class JobSpec:
    name: str
    image_key: str
    driving_video_key: str


def get_minio() -> Minio:
    endpoint = os.environ["MINIO_ENDPOINT"]
    access_key = os.environ["MINIO_ACCESS_KEY"]
    secret_key = os.environ["MINIO_SECRET_KEY"]
    secure = os.environ.get("MINIO_USE_SSL", "true").lower() == "true"
    return Minio(endpoint, access_key=access_key, secret_key=secret_key, secure=secure)


def main() -> None:
    bucket = os.environ.get("MINIO_BUCKET", "avatar-templates")
    out_user = os.environ.get("BATCH_USER_ID", "batch")

    specs = [
        JobSpec(
            name="task1_jobs__man1",
            image_key="input-avatars/jobs.png",
            driving_video_key="sitting-woman/video-conference-man-1.mp4",
        ),
        JobSpec(
            name="task1_jobs__woman2",
            image_key="input-avatars/jobs.png",
            driving_video_key="sitting-woman/video-conference-woman-2.mp4",
        ),
        JobSpec(
            name="task2_execwoman__woman1",
            image_key="input-avatars/exec-woman.png",
            driving_video_key="sitting-woman/video-conference-woman.mp4",
        ),
        JobSpec(
            name="task2_execwoman__woman2",
            image_key="input-avatars/exec-woman.png",
            driving_video_key="sitting-woman/video-conference-woman-2.mp4",
        ),
    ]

    client = get_minio()

    for spec in specs:
        marker = f"/tmp/start_avatar_{spec.name}.txt"
        start = time.time()
        with open(marker, "w") as f:
            f.write(
                f"start_unix={start}\n"
                f"image_key={spec.image_key}\n"
                f"driving_video_key={spec.driving_video_key}\n"
            )

        img_bytes = client.get_object(bucket, spec.image_key).read()
        job = {
            "input": {
                "user_id": out_user,
                "avatar_id": spec.name,
                "image_base64": base64.b64encode(img_bytes).decode("utf-8"),
                "driving_video_path": spec.driving_video_key,
            }
        }
        result = handler.handler(job)
        end = time.time()
        duration_s = round(end - start, 2)

        # Write end marker for later inspection (user requested touch/mtime approach).
        with open(marker, "a") as f:
            f.write(f"end_unix={end}\n")
            f.write(f"duration_s={duration_s}\n")
            f.write(f"result={result}\n")

        print(
            {
                "name": spec.name,
                "duration_s": duration_s,
                "minio_key": result.get("minio_key"),
                "video_url": result.get("video_url"),
                "error": result.get("error"),
            },
            flush=True,
        )


if __name__ == "__main__":
    main()

