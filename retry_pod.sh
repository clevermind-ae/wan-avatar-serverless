#!/usr/bin/env bash
set -euo pipefail

if [ -z "${RUNPOD_API_KEY:-}" ]; then
  echo "RUNPOD_API_KEY environment variable is required."
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed."
  exit 2
fi

API_KEY="${RUNPOD_API_KEY}"
ENDPOINT="${RUNPOD_ENDPOINT:-https://rest.runpod.io/v1/pods}"
IMAGE_NAME="${RUNPOD_IMAGE_NAME:-hearmeman/comfyui-wan-template:v11}"
POD_NAME="${RUNPOD_POD_NAME:-wan-avatar-auto-test}"
NETWORK_VOLUME_ID="${RUNPOD_NETWORK_VOLUME_ID:-6ruuguvabk}"
VOLUME_MOUNT_PATH="${RUNPOD_VOLUME_MOUNT_PATH:-/workspace}"
CONTAINER_DISK_GB="${RUNPOD_CONTAINER_DISK_GB:-80}"
VOLUME_GB="${RUNPOD_VOLUME_GB:-50}"
ALLOW_NO_VOLUME_FALLBACK="${RUNPOD_ALLOW_NO_VOLUME_FALLBACK:-true}"
USE_NETWORK_VOLUME="${RUNPOD_USE_NETWORK_VOLUME:-true}"
RETRY_INTERVAL_SECONDS="${RUNPOD_RETRY_INTERVAL_SECONDS:-5}"
CUDA_VERSION="${RUNPOD_CUDA_VERSION:-12.8}"
VERIFY_SSH_ON_CREATE="${RUNPOD_VERIFY_SSH_ON_CREATE:-true}"
SSH_READY_TIMEOUT_SECONDS="${RUNPOD_SSH_READY_TIMEOUT_SECONDS:-1800}"
SSH_CHECK_INTERVAL_SECONDS="${RUNPOD_SSH_CHECK_INTERVAL_SECONDS:-5}"
AUTO_DELETE_UNREACHABLE_PODS="${RUNPOD_AUTO_DELETE_UNREACHABLE_PODS:-true}"
GPU_TYPES=(
  "NVIDIA RTX PRO 6000 Blackwell Server Edition"
  "NVIDIA H100 80GB HBM3"
  "NVIDIA H100 PCIe"
  "NVIDIA H100 NVL"
  "NVIDIA H200"
  "NVIDIA A100-SXM4-80GB"
  "NVIDIA A100 80GB PCIe"
)

delete_pod() {
  local pod_id="$1"
  echo "Deleting unreachable pod ${pod_id}..."
  curl -sS -X DELETE \
    -H "Authorization: Bearer ${API_KEY}" \
    "${ENDPOINT}/${pod_id}" >/dev/null || true
}

wait_for_ssh() {
  local pod_id="$1"
  local attempts
  local i
  local pod_resp
  local pod_ip
  local pod_ssh_port
  local pod_status

  attempts=$((SSH_READY_TIMEOUT_SECONDS / SSH_CHECK_INTERVAL_SECONDS))
  if [ "${attempts}" -lt 1 ]; then
    attempts=1
  fi

  for ((i = 1; i <= attempts; i++)); do
    pod_resp=$(
      curl -sS -H "Authorization: Bearer ${API_KEY}" \
        "${ENDPOINT}/${pod_id}" || true
    )
    pod_status=$(echo "${pod_resp}" | jq -r '.desiredStatus // ""')
    pod_ip=$(echo "${pod_resp}" | jq -r '.publicIp // ""')
    pod_ssh_port=$(echo "${pod_resp}" | jq -r '.portMappings["22"] // ""')
    if [ "${pod_status}" = "RUNNING" ] && [ -n "${pod_ip}" ] && [ -n "${pod_ssh_port}" ]; then
      if nc -z "${pod_ip}" "${pod_ssh_port}" >/dev/null 2>&1; then
        echo "${pod_resp}" >/tmp/runpod_last_pod.json
        echo "SSH is reachable at ${pod_ip}:${pod_ssh_port}"
        return 0
      fi
      echo "Pod ${pod_id} is RUNNING but SSH not reachable yet at ${pod_ip}:${pod_ssh_port} (attempt ${i}/${attempts})"
    else
      echo "Waiting for pod ${pod_id} network readiness (attempt ${i}/${attempts})"
    fi
    sleep "${SSH_CHECK_INTERVAL_SECONDS}"
  done
  return 1
}

create_pod() {
  local gpu_type="$1"
  local placement_mode="$2"
  local response_body_file
  local response_body
  local http_code
  local payload
  if [ "${placement_mode}" = "with_volume" ]; then
    payload=$(jq -n \
      --arg name "${POD_NAME}" \
      --arg image_name "${IMAGE_NAME}" \
      --arg gpu_type "${gpu_type}" \
      --arg cuda_version "${CUDA_VERSION}" \
      --arg network_volume_id "${NETWORK_VOLUME_ID}" \
      --arg volume_mount_path "${VOLUME_MOUNT_PATH}" \
      --argjson container_disk_gb "${CONTAINER_DISK_GB}" \
      --argjson volume_gb "${VOLUME_GB}" \
      '{
        name: $name,
        imageName: $image_name,
        cloudType: "COMMUNITY",
        computeType: "GPU",
        gpuCount: 1,
        gpuTypeIds: [$gpu_type],
        gpuTypePriority: "availability",
        dataCenterPriority: "availability",
        allowedCudaVersions: [$cuda_version],
        networkVolumeId: $network_volume_id,
        volumeMountPath: $volume_mount_path,
        ports: ["22/tcp", "8188/tcp", "8888/http", "8080/http"],
        supportPublicIp: true,
        containerDiskInGb: $container_disk_gb,
        volumeInGb: $volume_gb,
        interruptible: false
      }')
  else
    payload=$(jq -n \
      --arg name "${POD_NAME}" \
      --arg image_name "${IMAGE_NAME}" \
      --arg gpu_type "${gpu_type}" \
      --arg cuda_version "${CUDA_VERSION}" \
      --argjson container_disk_gb "${CONTAINER_DISK_GB}" \
      '{
        name: $name,
        imageName: $image_name,
        cloudType: "COMMUNITY",
        computeType: "GPU",
        gpuCount: 1,
        gpuTypeIds: [$gpu_type],
        gpuTypePriority: "availability",
        dataCenterPriority: "availability",
        allowedCudaVersions: [$cuda_version],
        ports: ["22/tcp", "8188/tcp", "8888/http", "8080/http"],
        supportPublicIp: true,
        containerDiskInGb: $container_disk_gb,
        volumeInGb: 0,
        interruptible: false
      }')
  fi

  response_body_file=$(mktemp)
  http_code=$(
    curl -sS -o "${response_body_file}" -w "%{http_code}" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" \
      --data "${payload}" \
      "${ENDPOINT}" 2>/tmp/runpod_retry_error.txt || true
  )
  response_body=$(cat "${response_body_file}")
  rm -f "${response_body_file}"

  if [ -n "${response_body}" ] && echo "${response_body}" | jq -e 'has("id")' >/dev/null 2>&1; then
    local pod_id
    pod_id=$(echo "${response_body}" | jq -r '.id')
    echo "Pod created successfully on GPU: ${gpu_type} (${placement_mode})"
    echo "${response_body}" | jq -r '.'
    echo "${pod_id}" >/tmp/runpod_last_pod_id

    if [ "${VERIFY_SSH_ON_CREATE}" = "true" ]; then
      if wait_for_ssh "${pod_id}"; then
        return 0
      fi
      echo "Pod ${pod_id} failed SSH readiness checks."
      if [ "${AUTO_DELETE_UNREACHABLE_PODS}" = "true" ]; then
        delete_pod "${pod_id}"
      fi
      return 1
    fi

    echo "${response_body}" >/tmp/runpod_last_pod.json
    return 0
  fi

  if [ -n "${response_body}" ]; then
    echo "GPU '${gpu_type}' (${placement_mode}) failed: $(echo "${response_body}" | jq -r 'if type=="array" then .[0].error // .[0].message // "unknown error" else .error // .message // "unknown error" end') (HTTP ${http_code})"
  else
    cat /tmp/runpod_retry_error.txt 2>/dev/null | grep -v '^$' || true
    echo "GPU '${gpu_type}' (${placement_mode}) failed with empty response (HTTP ${http_code})."
  fi
  return 1
}

echo "Retrying pod creation every ${RETRY_INTERVAL_SECONDS}s."
echo "Image: ${IMAGE_NAME}"
echo "GPU priority order: ${GPU_TYPES[*]}"
if [ "${USE_NETWORK_VOLUME}" = "true" ] && [ -n "${NETWORK_VOLUME_ID}" ]; then
  echo "Primary mode: with network volume (${NETWORK_VOLUME_ID} mounted at ${VOLUME_MOUNT_PATH})"
else
  echo "Primary mode: without network volume"
fi

while true; do
  if [ "${USE_NETWORK_VOLUME}" = "true" ] && [ -n "${NETWORK_VOLUME_ID}" ]; then
    for gpu_type in "${GPU_TYPES[@]}"; do
      if create_pod "${gpu_type}" "with_volume"; then
        exit 0
      fi
    done
  fi

  if [ "${ALLOW_NO_VOLUME_FALLBACK}" = "true" ]; then
    for gpu_type in "${GPU_TYPES[@]}"; do
      if create_pod "${gpu_type}" "without_volume"; then
        exit 0
      fi
    done
  elif [ "${USE_NETWORK_VOLUME}" != "true" ] || [ -z "${NETWORK_VOLUME_ID}" ]; then
    for gpu_type in "${GPU_TYPES[@]}"; do
      if create_pod "${gpu_type}" "without_volume"; then
        exit 0
      fi
    done
  fi

  echo "All GPU options failed across enabled placement modes; waiting ${RETRY_INTERVAL_SECONDS}s before next cycle..."
  sleep "${RETRY_INTERVAL_SECONDS}"
done
