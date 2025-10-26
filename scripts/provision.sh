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

      [[ -z "${!key:-}" ]] && export "${key}=${value}"
    else
      echo "Warning: ignoring invalid line in ${dotenv_file}: ${line}" >&2
    fi
  done < "${dotenv_file}"
}

if [[ -f "${ENV_FILE}" ]]; then
  load_dotenv "${ENV_FILE}"
fi

# Export ANSIBLE_BECOME_PASSWORD if set in .env (passed to ansible-playbook via --extra-vars)
if [[ -n "${ANSIBLE_BECOME_PASSWORD:-}" ]]; then
  export ANSIBLE_BECOME_PASSWORD
fi

if [[ -n "${ANSIBLE_SSH_PUBLIC_KEYS_FILE:-}" && -z "${ANSIBLE_SSH_PUBLIC_KEYS:-}" ]]; then
  if [[ -f "${ANSIBLE_SSH_PUBLIC_KEYS_FILE}" ]]; then
    ssh_keys="$(<"${ANSIBLE_SSH_PUBLIC_KEYS_FILE}")"
    export ANSIBLE_SSH_PUBLIC_KEYS="${ssh_keys}"
  else
    echo "Warning: ANSIBLE_SSH_PUBLIC_KEYS_FILE=${ANSIBLE_SSH_PUBLIC_KEYS_FILE} not found" >&2
  fi
fi

if [[ -z "${HCLOUD_TOKEN:-}" && -n "${HETZNER_API_TOKEN:-}" ]]; then
  export HCLOUD_TOKEN="${HETZNER_API_TOKEN}"
fi

if [[ -z "${HCLOUD_TOKEN_FILE:-}" && -n "${HETZNER_API_TOKEN_FILE:-}" ]]; then
  export HCLOUD_TOKEN_FILE="${HETZNER_API_TOKEN_FILE}"
fi

# Check for passlib dependency (required for password hashing)
if ! python3 -c "import passlib" 2>/dev/null; then
  echo "Error: passlib Python library is required for password hashing but not found." >&2
  echo "" >&2
  echo "Install it using one of the following methods:" >&2
  echo "  - pip/pip3:       pip install passlib" >&2
  echo "  - Manjaro/Arch:   sudo pacman -S python-passlib" >&2
  echo "  - Debian/Ubuntu:  sudo apt install python3-passlib" >&2
  echo "" >&2
  exit 1
fi

REMOTE_HOST="${ANSIBLE_REMOTE_HOST:-}"
if [[ -z "${REMOTE_HOST}" ]]; then
  echo "ANSIBLE_REMOTE_HOST is required. Set it in .env before provisioning." >&2
  exit 1
fi

TARGET_USER="${ANSIBLE_TARGET_USER:-}"
if [[ -z "${TARGET_USER}" ]]; then
  echo "ANSIBLE_TARGET_USER is required. Set it in .env before provisioning." >&2
  echo "This is the user that will be created/managed on the remote server." >&2
  exit 1
fi

REMOTE_HOSTNAME="${ANSIBLE_HCLOUD_SERVER_NAME:-hetzner_host}"
REMOTE_USER="${ANSIBLE_REMOTE_USER:-root}"
REMOTE_KEY="${ANSIBLE_REMOTE_SSH_KEY:-~/.ssh/id_ed25519}"
REMOTE_PORT="${ANSIBLE_SSH_PORT:-22}"
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

# Warn about SSH host key verification on first provision
if [[ ! -f "${HOME}/.ssh/known_hosts" ]] || ! grep -q "${REMOTE_HOST}" "${HOME}/.ssh/known_hosts" 2>/dev/null; then
  echo "⚠️  SSH host key verification enabled" >&2
  echo "   You will be prompted to accept the host key on first connection." >&2
  echo "   Verify the fingerprint via Hetzner Cloud console if concerned about MITM attacks." >&2
  echo "   To skip verification (insecure): ANSIBLE_HOST_KEY_CHECKING=False make provision" >&2
  echo "" >&2
fi

# Pass become password to Ansible via --extra-vars if set
EXTRA_VARS=()
if [[ -n "${ANSIBLE_BECOME_PASSWORD:-}" ]]; then
  EXTRA_VARS+=(-e "ansible_become_password={{ lookup('env', 'ANSIBLE_BECOME_PASSWORD') }}")
fi

ansible-playbook -i "${TEMP_INVENTORY}" "${PLAYBOOK}" "${EXTRA_VARS[@]}" "$@"
