#!/usr/bin/env bash
set -euo pipefail

# Provision a RunPod Pod for debugging.
# Key idea: override container start command to "sleep infinity" so the Pod stays up,
# then you can SSH in and run /entrypoint.sh manually.
#
# Requires:
#   - RUNPOD_API_KEY
#   - ~/.ssh/runpod_prod private key already registered on RunPod
#
# Example:
#   RUNPOD_API_KEY=... RUNPOD_IMAGE_NAME=dexsynccom/twin-avatar:wan ./runpod_setup.sh

if [ -z "${RUNPOD_API_KEY:-}" ]; then
  echo "RUNPOD_API_KEY is required."
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed."
  exit 2
fi

API_KEY="${RUNPOD_API_KEY}"
GQL_URL="${RUNPOD_GQL_URL:-https://api.runpod.io/graphql}"

IMAGE_NAME="${RUNPOD_IMAGE_NAME:-dexsynccom/twin-avatar:wan}"
POD_NAME="${RUNPOD_POD_NAME:-wan-avatar-debug}"
CONTAINER_DISK_GB="${RUNPOD_CONTAINER_DISK_GB:-80}"
VOLUME_GB="${RUNPOD_VOLUME_GB:-0}"
MIN_VCPU="${RUNPOD_MIN_VCPU:-2}"
MIN_MEM_GB="${RUNPOD_MIN_MEM_GB:-15}"
PORTS="${RUNPOD_PORTS:-22/tcp,8188/http}"
CUDA_VERSIONS="${RUNPOD_ALLOWED_CUDA_VERSIONS:-12.8}"
CLOUD_TYPE="${RUNPOD_CLOUD_TYPE:-ALL}"

DOCKER_ARGS="${RUNPOD_DOCKER_ARGS:-sleep infinity}"

SSH_KEY_PATH="${RUNPOD_SSH_KEY_PATH:-$HOME/.ssh/runpod_prod}"
SSH_READY_TIMEOUT_SECONDS="${RUNPOD_SSH_READY_TIMEOUT_SECONDS:-1800}"
SSH_POLL_SECONDS="${RUNPOD_SSH_POLL_SECONDS:-10}"

gql_pod_host_id() {
  local pod_id="$1"
  curl -sS "${GQL_URL}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    --data-binary "$(jq -n --arg podId "${pod_id}" '{query:"query($podId:String!){ pod(input:{podId:$podId}){ machine{ podHostId } } }",variables:{podId:$podId}}')" \
    | jq -r '.data.pod.machine.podHostId // empty'
}

wait_for_ssh_proxy() {
  local pod_host_id="$1"
  local deadline=$(( $(date +%s) + SSH_READY_TIMEOUT_SECONDS ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    # "container not found" means the container isn't up yet (often still pulling the image).
    out="$(
      ssh -i "${SSH_KEY_PATH}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        -tt "${pod_host_id}@ssh.runpod.io" \
        'echo SSH_OK; hostname; nvidia-smi -L | head -n 1' 2>&1 || true
    )"
    if echo "${out}" | grep -q '^SSH_OK$'; then
      echo "SSH proxy is ready."
      return 0
    fi
    echo "Waiting for container/SSH (proxy): $(echo "${out}" | tail -n 1)"
    sleep "${SSH_POLL_SECONDS}"
  done
  return 1
}

echo "Deploying debug pod (no network volume)."
echo "Image: ${IMAGE_NAME}"
echo "dockerArgs override: ${DOCKER_ARGS}"
echo "Ports: ${PORTS}"
echo "SSH timeout: ${SSH_READY_TIMEOUT_SECONDS}s"

deploy_pod_graphql() {
  local gpu_type="$1"
  local query
  query=$(
    cat <<'GQL'
mutation Deploy($input: PodFindAndDeployOnDemandInput!) {
  podFindAndDeployOnDemand(input: $input) {
    id
    imageName
    machine { podHostId }
  }
}
GQL
  )

  # Keep input minimal; we only need a running container for SSH.
  local vars
  vars=$(
    jq -n \
      --arg cloudType "${CLOUD_TYPE}" \
      --arg name "${POD_NAME}" \
      --arg imageName "${IMAGE_NAME}" \
      --arg gpuTypeId "${gpu_type}" \
      --arg dockerArgs "${DOCKER_ARGS}" \
      --argjson gpuCount 1 \
      --argjson volumeInGb "${VOLUME_GB}" \
      --argjson containerDiskInGb "${CONTAINER_DISK_GB}" \
      --argjson minVcpuCount "${MIN_VCPU}" \
      --argjson minMemoryInGb "${MIN_MEM_GB}" \
      '{
        input: {
          cloudType: $cloudType,
          gpuCount: $gpuCount,
          volumeInGb: $volumeInGb,
          containerDiskInGb: $containerDiskInGb,
          minVcpuCount: $minVcpuCount,
          minMemoryInGb: $minMemoryInGb,
          gpuTypeId: $gpuTypeId,
          name: $name,
          imageName: $imageName,
          dockerArgs: $dockerArgs
        }
      }'
  )

  local resp
  resp="$(
    curl -sS "${GQL_URL}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_KEY}" \
      --data-binary "$(jq -n --arg q "${query}" --argjson v "${vars}" '{query:$q,variables:$v}')"
  )"

  if echo "${resp}" | jq -e '.errors' >/dev/null 2>&1; then
    echo "Deploy failed for GPU '${gpu_type}': $(echo "${resp}" | jq -r '.errors[0].message // "unknown error"')"
    return 1
  fi

  local pod_id pod_host_id
  pod_id="$(echo "${resp}" | jq -r '.data.podFindAndDeployOnDemand.id // empty')"
  pod_host_id="$(echo "${resp}" | jq -r '.data.podFindAndDeployOnDemand.machine.podHostId // empty')"
  if [ -z "${pod_id}" ] || [ -z "${pod_host_id}" ]; then
    echo "Unexpected response (missing pod id/host id):"
    echo "${resp}" | jq -r '.'
    return 1
  fi

  echo "${pod_id}" >/tmp/runpod_last_pod_id
  echo "${pod_host_id}" >/tmp/runpod_last_pod_host_id
  echo "Pod created: ${pod_id}"
  echo "Pod host id: ${pod_host_id}"
  return 0
}

GPU_TYPES=(
  "NVIDIA RTX PRO 6000 Blackwell Server Edition"
  "NVIDIA RTX 6000 Ada"
  "NVIDIA L40S"
  "NVIDIA RTX A6000"
  "NVIDIA RTX 5090"
  "NVIDIA H100 SXM"
  "NVIDIA H100 NVL"
  "NVIDIA H100 PCIe"
  "NVIDIA H200"
)

POD_ID=""
POD_HOST_ID=""
for gpu in "${GPU_TYPES[@]}"; do
  if deploy_pod_graphql "${gpu}"; then
    POD_ID="$(cat /tmp/runpod_last_pod_id)"
    POD_HOST_ID="$(cat /tmp/runpod_last_pod_host_id)"
    break
  fi
done

if [ -z "${POD_ID}" ] || [ -z "${POD_HOST_ID}" ]; then
  echo "Failed to create a pod on all candidate GPUs."
  exit 1
fi

echo
echo "Waiting for proxy SSH on ${POD_HOST_ID}..."
if ! wait_for_ssh_proxy "${POD_HOST_ID}"; then
  echo "Timed out waiting for SSH proxy. Pod id: ${POD_ID}"
  echo "Terminate it manually to avoid charges:"
  echo "  curl -X DELETE -H 'Authorization: Bearer <RUNPOD_API_KEY>' https://rest.runpod.io/v1/pods/${POD_ID}"
  exit 1
fi

echo
echo "Connect:"
echo "  ssh -i ${SSH_KEY_PATH} -tt ${POD_HOST_ID}@ssh.runpod.io"
echo
echo "Then run (manual debug):"
echo "  bash -lc /entrypoint.sh"
echo
