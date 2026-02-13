#!/usr/bin/env bash
set -euo pipefail

if [ -z "${RUNPOD_API_KEY:-}" ]; then
  echo "RUNPOD_API_KEY environment variable is required."
  exit 2
fi
API_KEY="${RUNPOD_API_KEY}"
ENDPOINT="https://rest.runpod.io/v1/pods"
IMAGE_NAME="hearmeman/comfyui-wan-template:v11"
PAYLOAD=$(cat <<'EOF'
{
  "name": "wan-avatar-rtx6000-test",
  "imageName": "hearmeman/comfyui-wan-template:v11",
  "cloudType": "COMMUNITY",
  "computeType": "GPU",
  "gpuCount": 1,
  "gpuTypeIds": [
    "NVIDIA RTX PRO 6000 Blackwell Server Edition"
  ],
  "gpuTypePriority": "availability",
  "dataCenterPriority": "availability",
  "allowedCudaVersions": [
    "12.8"
  ],
  "networkVolumeId": "6ruuguvabk",
  "volumeMountPath": "/workspace",
  "ports": ["22/tcp", "8188/http", "8888/http", "8080/http"],
  "supportPublicIp": true,
  "containerDiskInGb": 80,
  "volumeInGb": 50,
  "interruptible": false
}
EOF
)

echo "Retrying pod creation with ${IMAGE_NAME} (CUDA 12.8) every 5s until success."
while true; do
  RESPONSE_BODY_FILE=$(mktemp)
  HTTP_CODE=$(curl -sS -o "${RESPONSE_BODY_FILE}" -w "%{http_code}" -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" --data "${PAYLOAD}" "${ENDPOINT}" 2>/tmp/runpod_retry_error.txt || true)
  RESPONSE_BODY=$(cat "${RESPONSE_BODY_FILE}")
  rm -f "${RESPONSE_BODY_FILE}"
  if [ -n "${RESPONSE_BODY}" ] && echo "${RESPONSE_BODY}" | jq -e 'has("id")' >/dev/null 2>&1; then
    echo "Pod created successfully:"
    echo "${RESPONSE_BODY}" | jq -r '.'
    break
  fi
  if [ -n "${RESPONSE_BODY}" ]; then
    echo "Error response: $(echo "${RESPONSE_BODY}" | jq -r '.error // "unknown error"') (HTTP ${HTTP_CODE})"
  else
    cat /tmp/runpod_retry_error.txt 2>/dev/null | grep -v '^$' || true
    echo "No JSON response (HTTP ${HTTP_CODE})."
  fi
  echo "Retry failed; waiting 5s..."
  sleep 5
done
