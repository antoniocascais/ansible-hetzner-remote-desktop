#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYBOOK="${REPO_ROOT}/ansible/playbooks/remote-desktop.yml"

ENV_FILE="${REPO_ROOT}/.env"

load_dotenv() {
  local dotenv_file="$1"
  local line=""
  local key=""
  local value=""

  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in
      ''|\#*) continue ;;
    esac

    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"

      value="${value%%$'\r'}"
      if [[ -n $value ]]; then
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
      fi

      if [[ $value == '"'* && $value == *'"' ]]; then
        value="${value:1:-1}"
      elif [[ $value == "'"* && $value == *"'" ]]; then
        value="${value:1:-1}"
      fi

      export "${key}=${value}"
    else
      echo "Warning: ignoring invalid line in ${dotenv_file}: ${line}" >&2
    fi
  done < "${dotenv_file}"
}

if [[ -f "${ENV_FILE}" ]]; then
  load_dotenv "${ENV_FILE}"
fi

if [[ -n "${ANSIBLE_OPERATOR_PUBLIC_KEYS_FILE:-}" && -z "${ANSIBLE_OPERATOR_PUBLIC_KEYS:-}" ]]; then
  if [[ -f "${ANSIBLE_OPERATOR_PUBLIC_KEYS_FILE}" ]]; then
    operator_keys="$(<"${ANSIBLE_OPERATOR_PUBLIC_KEYS_FILE}")"
    export ANSIBLE_OPERATOR_PUBLIC_KEYS="${operator_keys}"
  else
    echo "Warning: ANSIBLE_OPERATOR_PUBLIC_KEYS_FILE=${ANSIBLE_OPERATOR_PUBLIC_KEYS_FILE} not found" >&2
  fi
fi

if [[ -z "${HCLOUD_TOKEN:-}" && -n "${HETZNER_API_TOKEN:-}" ]]; then
  export HCLOUD_TOKEN="${HETZNER_API_TOKEN}"
fi

if [[ -z "${HCLOUD_TOKEN_FILE:-}" && -n "${HETZNER_API_TOKEN_FILE:-}" ]]; then
  export HCLOUD_TOKEN_FILE="${HETZNER_API_TOKEN_FILE}"
fi

if [[ -z "${ANSIBLE_REMOTE_SSH_PORT:-}" && -n "${ANSIBLE_SSH_PORT:-}" ]]; then
  export ANSIBLE_REMOTE_SSH_PORT="${ANSIBLE_SSH_PORT}"
fi

REMOTE_HOST="${ANSIBLE_REMOTE_HOST:-}"
if [[ -z "${REMOTE_HOST}" ]]; then
  echo "ANSIBLE_REMOTE_HOST is required. Set it in .env before running acceptance checks." >&2
  exit 1
fi

REMOTE_HOSTNAME="${ANSIBLE_REMOTE_HOSTNAME:-hetzner_host}"
REMOTE_USER="${ANSIBLE_REMOTE_USER:-root}"
REMOTE_KEY="${ANSIBLE_REMOTE_SSH_KEY:-~/.ssh/id_ed25519}"
REMOTE_PORT="${ANSIBLE_REMOTE_SSH_PORT:-22}"
REMOTE_PYTHON="${ANSIBLE_REMOTE_PYTHON:-/usr/bin/python3}"


expand_path() {
  local path="$1"
  case $path in
    ~*) echo "${path/#\~/${HOME}}" ;;
    *) echo "$path" ;;
  esac
}

REMOTE_KEY="$(expand_path "${REMOTE_KEY}")"
REMOTE_PYTHON="$(expand_path "${REMOTE_PYTHON}")"

TEMP_INVENTORY="$(mktemp "${TMPDIR:-/tmp}/ansible-inventory.XXXXXX")"
if [[ -z ${TEMP_INVENTORY} ]]; then
  echo "Failed to create temporary inventory file" >&2
  exit 1
fi

trap 'rm -f "$TEMP_INVENTORY"' EXIT

printf '[hetzner_remote_desktop]\n%s ansible_host=%s ansible_user=%s ansible_ssh_private_key_file="%s" ansible_port=%s ansible_python_interpreter="%s"\n' \
  "$REMOTE_HOSTNAME" "$REMOTE_HOST" "$REMOTE_USER" "$REMOTE_KEY" "$REMOTE_PORT" "$REMOTE_PYTHON" \
  >"${TEMP_INVENTORY}"

export ANSIBLE_CONFIG="${REPO_ROOT}/ansible/ansible.cfg"

ansible-playbook -i "${TEMP_INVENTORY}" "${PLAYBOOK}" --tags acceptance "$@"
