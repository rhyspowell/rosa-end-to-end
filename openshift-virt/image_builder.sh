#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AWS_REGION="${AWS_REGION:-eu-west-2}"
VPC_NAME="${VPC_NAME:-test-vpc}"
ECR_REPOSITORY="${ECR_REPOSITORY:-rhel10-nginx}"
BASE_QCOW2="${SCRIPT_DIR}/rhel-10.kvm.qcow2"
OUTPUT_DIR="${SCRIPT_DIR}/output"
OUTPUT_QCOW2="${OUTPUT_DIR}/rhel10-nginx.qcow2"
SSH_KEY_DIR="${SCRIPT_DIR}/.packer-ssh"
TOOLS_DIR="${SCRIPT_DIR}/.tools"
export PATH="${TOOLS_DIR}:${PATH}"
USERDATA_TEMPLATE="${SCRIPT_DIR}/cloud-init/user-data.yaml"
USERDATA_OUTPUT="${OUTPUT_DIR}/user-data.yaml"
PACKER_VERSION="${PACKER_VERSION:-1.14.2}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <ami|qcow2|push|userdata|all> [name]

  ami              Build the AWS AMI from the latest RHEL 10 image in ${AWS_REGION}
  qcow2            Build a local qcow2 image from ${BASE_QCOW2}
  push             Package the qcow2 as a container disk and push to ECR
  userdata <name>  Render shared cloud-init user-data that replaces {{name}}
  all              Build AMI, qcow2, then push to ECR

EOF
}

require_packer() {
  if command -v packer >/dev/null 2>&1; then
    echo "Packer found: $(packer version | head -n1)"
    return
  fi

  echo "Packer is not on PATH. Installing ${PACKER_VERSION} into ${TOOLS_DIR}..."
  mkdir -p "${TOOLS_DIR}"
  local zip="${TOOLS_DIR}/packer.zip"
  local url="https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip"
  curl -fsSL -o "${zip}" "${url}"
  unzip -o -q "${zip}" -d "${TOOLS_DIR}"
  rm -f "${zip}"
  chmod +x "${TOOLS_DIR}/packer"
  export PATH="${TOOLS_DIR}:${PATH}"
  echo "Packer found: $(packer version | head -n1)"
}

lookup_rhel10_ami() {
  echo "Looking up latest RHEL 10 AMI in ${AWS_REGION}..."
  SOURCE_AMI=$(aws ec2 describe-images \
    --owners 309956199498 \
    --region "${AWS_REGION}" \
    --filters \
      "Name=name,Values=RHEL-10*-x86_64*" \
      "Name=state,Values=available" \
      "Name=architecture,Values=x86_64" \
    --query 'reverse(sort_by(Images, &CreationDate))[0].ImageId' \
    --output text \
    --no-cli-pager)

  if [ -z "${SOURCE_AMI}" ] || [ "${SOURCE_AMI}" = "None" ]; then
    echo "Could not find a RHEL 10 AMI in ${AWS_REGION}"
    exit 1
  fi

  SOURCE_AMI_NAME=$(aws ec2 describe-images \
    --image-ids "${SOURCE_AMI}" \
    --region "${AWS_REGION}" \
    --query 'Images[0].Name' \
    --output text \
    --no-cli-pager)
  echo "Using source AMI: ${SOURCE_AMI} (${SOURCE_AMI_NAME})"
}

lookup_build_network() {
  echo "Looking up VPC ${VPC_NAME} and a public subnet..."
  BUILD_VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${VPC_NAME}" \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --region "${AWS_REGION}" \
    --no-cli-pager)
  if [ -z "${BUILD_VPC_ID}" ] || [ "${BUILD_VPC_ID}" = "None" ]; then
    echo "Could not find VPC named ${VPC_NAME}"
    exit 1
  fi
  BUILD_SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${BUILD_VPC_ID}" "Name=tag:Name,Values=*public*" \
    --query 'Subnets[0].SubnetId' \
    --output text \
    --region "${AWS_REGION}" \
    --no-cli-pager)
  if [ -z "${BUILD_SUBNET_ID}" ] || [ "${BUILD_SUBNET_ID}" = "None" ]; then
    echo "Could not find a public subnet in ${BUILD_VPC_ID}"
    exit 1
  fi
  echo "Using VPC ${BUILD_VPC_ID} subnet ${BUILD_SUBNET_ID}"
}

require_base_qcow2() {
  if [ ! -f "${BASE_QCOW2}" ]; then
    cat <<EOF
Missing base image: ${BASE_QCOW2}

Download the RHEL 10 KVM Guest Image (.qcow2) from:
  https://access.redhat.com/articles/download-rhel-10
  or
  https://console.redhat.com/insights/image-builder

Then place the file at:
  ${BASE_QCOW2}

Re-run: $(basename "$0") qcow2
EOF
    exit 1
  fi
  echo "Base qcow2 found: ${BASE_QCOW2}"
}

require_qemu() {
  if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    cat <<EOF
qemu-system-x86_64 is required for the qcow2 build but was not found.

On Fedora:
  sudo dnf install -y qemu-kvm qemu-img
EOF
    exit 1
  fi
  echo "QEMU found: $(command -v qemu-system-x86_64)"
}

require_podman() {
  if ! command -v podman >/dev/null 2>&1; then
    echo "podman is required to push the container disk"
    exit 1
  fi
}

prepare_ssh_key() {
  mkdir -p "${SSH_KEY_DIR}"
  chmod 700 "${SSH_KEY_DIR}"
  if [ ! -f "${SSH_KEY_DIR}/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N "" -f "${SSH_KEY_DIR}/id_ed25519" -C "packer-rhel10-nginx"
  fi
  SSH_PRIVATE_KEY_FILE="${SSH_KEY_DIR}/id_ed25519"
  SSH_PUBLIC_KEY=$(cat "${SSH_KEY_DIR}/id_ed25519.pub")
}

build_ami() {
  require_packer
  lookup_rhel10_ami
  lookup_build_network

  local packer_dir="${SCRIPT_DIR}/packer/ami"
  echo "Initializing Packer plugins for AMI build..."
  packer init "${packer_dir}"

  echo "Building AMI..."
  local mr_log
  mr_log=$(mktemp)
  packer build -machine-readable \
    -var "aws_region=${AWS_REGION}" \
    -var "source_ami=${SOURCE_AMI}" \
    -var "vpc_id=${BUILD_VPC_ID}" \
    -var "subnet_id=${BUILD_SUBNET_ID}" \
    "${packer_dir}" | tee "${mr_log}"

  BUILT_AMI_ID=$(awk -F, '/,artifact,0,id,/ {print $NF}' "${mr_log}" | tail -n1 | awk -F: '{print $NF}')
  rm -f "${mr_log}"
  if [ -n "${BUILT_AMI_ID:-}" ]; then
    echo "Published AMI ID: ${BUILT_AMI_ID} (${AWS_REGION})"
  else
    echo "AMI build finished but the AMI ID could not be parsed from Packer output"
  fi
}

build_qcow2() {
  require_packer
  require_qemu
  require_base_qcow2
  prepare_ssh_key

  mkdir -p "${OUTPUT_DIR}"
  find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

  local packer_dir="${SCRIPT_DIR}/packer/qcow2"
  echo "Initializing Packer plugins for qcow2 build..."
  packer init "${packer_dir}"

  echo "Building qcow2..."
  packer build \
    -var "base_qcow2=${BASE_QCOW2}" \
    -var "ssh_private_key_file=${SSH_PRIVATE_KEY_FILE}" \
    -var "ssh_public_key=${SSH_PUBLIC_KEY}" \
    -var "output_directory=${OUTPUT_DIR}" \
    "${packer_dir}"

  echo "qcow2 build complete: ${OUTPUT_QCOW2}"
}

push_container_disk() {
  require_podman
  if [ ! -f "${OUTPUT_QCOW2}" ]; then
    echo "Missing ${OUTPUT_QCOW2}. Run: $(basename "$0") qcow2"
    exit 1
  fi

  local account_id tag ecr_uri
  account_id=$(aws sts get-caller-identity --query Account --output text --no-cli-pager)
  tag=$(date -u +%Y%m%d%H%M%S)
  ecr_uri="${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"

  echo "Ensuring ECR repository ${ECR_REPOSITORY} exists in ${AWS_REGION}..."
  if ! aws ecr describe-repositories --repository-names "${ECR_REPOSITORY}" --region "${AWS_REGION}" --no-cli-pager >/dev/null 2>&1; then
    aws ecr create-repository --repository-name "${ECR_REPOSITORY}" --region "${AWS_REGION}" --no-cli-pager >/dev/null
  fi

  cat > "${OUTPUT_DIR}/Dockerfile" <<EOF
FROM scratch
ADD rhel10-nginx.qcow2 /disk/rhel10-nginx.qcow2
EOF

  echo "Building container disk..."
  podman build -t "${ecr_uri}:${tag}" -t "${ecr_uri}:latest" -f "${OUTPUT_DIR}/Dockerfile" "${OUTPUT_DIR}"

  echo "Logging in to ECR..."
  aws ecr get-login-password --region "${AWS_REGION}" --no-cli-pager \
    | podman login --username AWS --password-stdin "${account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  echo "Pushing ${ecr_uri}:${tag} and :latest..."
  podman push "${ecr_uri}:${tag}"
  podman push "${ecr_uri}:latest"
  echo "Published container disk: ${ecr_uri}:${tag}"
}

render_userdata() {
  local name="${1:-}"
  if [ -z "${name}" ]; then
    echo "Usage: $(basename "$0") userdata <name>"
    exit 1
  fi
  if [ ! -f "${USERDATA_TEMPLATE}" ]; then
    echo "Missing template: ${USERDATA_TEMPLATE}"
    exit 1
  fi
  mkdir -p "${OUTPUT_DIR}"
  python3 - "${USERDATA_TEMPLATE}" "${USERDATA_OUTPUT}" "${name}" <<'PY'
import json
import pathlib
import sys

template_path, output_path, name = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(template_path).read_text()
text = text.replace("__NAME_JSON__", json.dumps(name))
pathlib.Path(output_path).write_text(text)
print(output_path)
PY
  echo "Wrote cloud-init user-data to ${USERDATA_OUTPUT}"
  echo "AMI:  aws ec2 run-instances --user-data file://${USERDATA_OUTPUT} ..."
  echo "VM:   set cloudInitNoCloud.userData to the contents of ${USERDATA_OUTPUT}"
}

main() {
  if [ "${1:-}" = "" ]; then
    usage
    exit 1
  fi

  case "$1" in
    ami)
      build_ami
      ;;
    qcow2)
      build_qcow2
      ;;
    push)
      push_container_disk
      ;;
    userdata)
      render_userdata "${2:-}"
      ;;
    all)
      build_ami
      build_qcow2
      push_container_disk
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown target: $1"
      usage
      exit 1
      ;;
  esac
}

main "$@"
