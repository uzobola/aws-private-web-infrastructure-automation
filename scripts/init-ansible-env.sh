
#!/usr/bin/env bash

# This script must be sourced so exported variables remain
# available in the current WSL shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "ERROR: Source this script instead of executing it."
  echo "Use: source scripts/init-ansible-env.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_STATE="${REPO_ROOT}/terraform/terraform.tfstate"
ANSIBLE_DIR="${REPO_ROOT}/ansible"

fail() {
  echo "ERROR: $1" >&2
  return 1
}

command -v aws >/dev/null 2>&1 \
  || fail "AWS CLI is not installed in WSL." \
  || return 1

command -v ansible-playbook >/dev/null 2>&1 \
  || fail "Ansible is not installed in WSL." \
  || return 1

command -v python3 >/dev/null 2>&1 \
  || fail "Python 3 is not installed in WSL." \
  || return 1

command -v session-manager-plugin >/dev/null 2>&1 \
  || fail "AWS Session Manager plugin is not installed in WSL." \
  || return 1

if [[ ! -f "${TF_STATE}" ]]; then
  fail "Terraform state not found at ${TF_STATE}." || return 1
fi

CALLER_ARN="$(aws sts get-caller-identity \
  --query Arn \
  --output text 2>/dev/null)" \
  || {
    fail "No valid AWS session. Launch a fresh WSL session through AWS Vault."
    return 1
  }

if [[ "${CALLER_ARN}" != *":assumed-role/challenge3-ansible-execution-role/"* ]]; then
  fail "Unexpected AWS identity: ${CALLER_ARN}"
  return 1
fi

read_tf_output() {
  local output_name="$1"

  python3 - "${TF_STATE}" "${output_name}" <<'PY'
import json
import sys

state_path = sys.argv[1]
output_name = sys.argv[2]

with open(state_path, encoding="utf-8") as fh:
    state = json.load(fh)

try:
    value = state["outputs"][output_name]["value"]
except KeyError:
    raise SystemExit(
        f"Terraform output '{output_name}' was not found in {state_path}"
    )

print(value)
PY
}

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
export ANSIBLE_SSM_BUCKET="$(read_tf_output web_bucket_name)" || return 1
export ALB_DNS="$(read_tf_output alb_dns_name)" || return 1
export ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg"

if [[ -z "${ANSIBLE_SSM_BUCKET}" ]]; then
  fail "ANSIBLE_SSM_BUCKET resolved to an empty value." || return 1
fi

if [[ -z "${ALB_DNS}" ]]; then
  fail "ALB_DNS resolved to an empty value." || return 1
fi

echo "Challenge 3 Ansible environment loaded."
echo
echo "AWS identity : ${CALLER_ARN}"
echo "AWS region   : ${AWS_REGION}"
echo "SSM bucket   : ${ANSIBLE_SSM_BUCKET}"
echo "ALB DNS      : ${ALB_DNS}"
echo "Ansible cfg  : ${ANSIBLE_CONFIG}"

# Make the script executable
chmod +x scripts/init-ansible-env.sh
