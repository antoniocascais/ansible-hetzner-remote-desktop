# Hetzner Remote Desktop Provisioning

This repository provisions a hardened single-user remote desktop on a Hetzner Cloud VPS using Ansible. It installs an Xfce desktop served via xrdp, creates an operator account, and enforces a default-deny edge firewall policy driven by Hetzner Cloud.

The provisioning process automatically updates all system packages and reboots if required (kernel/systemd updates). Firefox ESR (Extended Support Release) is installed instead of snap Firefox due to XRDP X11 authorization compatibility issues.

## Prerequisites
- Ansible 2.16 or newer with Python 3.11+
- Access to a Hetzner Cloud project and API token with read/write privileges
- A freshly created Hetzner VPS running Ubuntu 24.04 LTS with your SSH key seeded for the `root` user
- Local machine with `ansible-galaxy` to install required collections

Install the required Ansible collections:

```bash
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

## Quickstart
1. Copy the sample environment file and tailor values to your host:
   ```bash
   cp .env.example .env
   $EDITOR .env
   ```
   The helper scripts automatically source `.env`, exporting connection details, operator settings, and Hetzner credentials.
2. Install required Ansible collections (idempotent):
   ```bash
   make install
   ```
3. Provision the host:
   ```bash
   make provision
   ```
   Pass additional flags with `EXTRA=...`, e.g. `make provision EXTRA="--limit hetzner_remote_desktop"`.
4. (Optional) Execute the acceptance checks after provisioning:
   ```bash
   make acceptance
   ```
   The helper scripts generate a temporary inventory from your `.env` values, so no host-specific data needs to live in the repository.
   To target a single role/tag, use `make provision-role ROLE=bootstrap` (add `EXTRA="..."` if you need more Ansible arguments).
5. (Optional) Preview changes without applying them:
   ```bash
   make check
   ```

The first run expects to connect as `ANSIBLE_REMOTE_USER` (default `root`). After successful provisioning, use the operator account defined in `ANSIBLE_OPERATOR_USERNAME` for subsequent SSH sessions.

**Security note:** On first provision, you will be prompted to verify the SSH host key. The provision script will warn you about this and suggest verifying the fingerprint via Hetzner Cloud console if concerned about MITM attacks. To skip verification (insecure), run `ANSIBLE_HOST_KEY_CHECKING=False make provision`.

## Configuration Reference
All runtime configuration is supplied through environment variables (see `.env.example`). The most important entries are:

- `ANSIBLE_REMOTE_HOST`, `ANSIBLE_REMOTE_USER`, `ANSIBLE_REMOTE_SSH_KEY`: SSH connection details for the target VPS.
- `ANSIBLE_HCLOUD_SERVER_NAME` or `ANSIBLE_HCLOUD_SERVER_ID`: Hetzner Cloud identifiers used when attaching the edge firewall.
- `ANSIBLE_REMOTE_HOSTNAME`: Optional host alias used in the generated inventory (defaults to `hetzner_host`).
- `ANSIBLE_OPERATOR_USERNAME`, `ANSIBLE_OPERATOR_PUBLIC_KEYS` or `_FILE`: operator Linux account and the public keys allowed to log in.
- `ANSIBLE_BECOME_PASSWORD`: Operator user's sudo password (required for re-provisioning after initial bootstrap when connecting as operator user). Leave empty for first provision.
- `ANSIBLE_FIREWALL_ALLOWED_CIDRS` **(REQUIRED)**: Comma-separated list of allowed source IP ranges for SSH/RDP access. Provisioning fails if not set or if `0.0.0.0/0` is used to prevent accidental global exposure.
- `ANSIBLE_SSH_PORT`: SSH port for firewall rules (default: 22).
- `HCLOUD_TOKEN` or `HCLOUD_TOKEN_FILE`: Hetzner API credentials for firewall management.
- `ANSIBLE_RDP_COLOR_DEPTH`, `ANSIBLE_RDP_DISABLE_COMPOSITOR`: desktop performance tuning switches.
- `ANSIBLE_SYSTEM_AUTO_REBOOT`: automatically reboot after system updates if kernel/systemd requires it (default: `true`).

The values flow into `ansible/vars/defaults.yml`, which can still be overridden with `--extra-vars` if needed.

## System Updates and Reboots

During the bootstrap phase, the playbook performs a full system update (`apt dist-upgrade`) to ensure all packages are current. If kernel or systemd updates are detected (via `/var/run/reboot-required`), the system will automatically reboot and reconnect.

**Controlling reboot behavior:**
- Set `ANSIBLE_SYSTEM_AUTO_REBOOT=false` in `.env` to disable automatic reboots
- Alternatively, use `--extra-vars '{"system_defaults":{"auto_reboot":false}}'` on the command line
- Reboots are idempotent: subsequent runs only reboot if new updates require it

**Note on Firefox:** Ubuntu 24.04 ships Firefox as a snap package by default, which has X11 authorization conflicts with XRDP sessions. The playbook removes the Firefox snap (if present) and installs `firefox-esr` from apt repositories, which works correctly with XRDP.

## Security Model

### Firewall Policy
- **Mandatory CIDR allowlist**: You must specify allowed source IPs via `ANSIBLE_FIREWALL_ALLOWED_CIDRS`
- **No global exposure**: Provisioning fails if `0.0.0.0/0` or `::/0` is present to prevent accidental internet-wide exposure
- **Edge protection**: Firewall rules are enforced at Hetzner Cloud edge (before traffic reaches the VPS)
- **Example**: `ANSIBLE_FIREWALL_ALLOWED_CIDRS="203.0.113.0/24,198.51.100.10/32"` allows access from your home network and office IP

### SSH Hardening
- **Host key verification enabled**: On first provision, you will be prompted to accept the SSH host key
  - Verify fingerprint via Hetzner Cloud console (Graphs → Console) if paranoid about MITM attacks
  - Subsequent provisions verify against `~/.ssh/known_hosts` to detect server replacement attacks
  - Override with `ANSIBLE_HOST_KEY_CHECKING=False make provision` for testing (insecure)
- **Root SSH disabled**: After bootstrap, only the operator user can SSH (configured in bootstrap role)
- **Public-key only**: Password authentication is disabled in sshd_config
- **Post-bootstrap access**: Update `ANSIBLE_REMOTE_USER` in `.env` to the operator username after first provision

### Sudo Access
- **Password required**: The operator user can sudo but must enter their password for each privileged operation
- **Ansible automation**: Store password in `ANSIBLE_BECOME_PASSWORD` in `.env` for automated re-provisioning (scripts auto-export it)
- **Security tradeoff**: Password stored in plaintext in `.env` (gitignored); workstation compromise exposes both SSH key and sudo password
- **Manual operations**: Interactive `sudo` commands will prompt for the operator user's password
- **First provision**: No password needed (connects as root); set `ANSIBLE_BECOME_PASSWORD` after initial bootstrap for subsequent runs

## Connecting via RDP
- **macOS**: Use Microsoft Remote Desktop (App Store). Add a PC, set hostname/IP, username = operator user, and trust the TLS prompt.
- **Windows**: Use `mstsc.exe`. Enter the server IP, choose “More choices → Use a different account”, and log in with the operator user. The first connection may take ~10 seconds while Xfce boots.
- **Linux**: Use `xfreerdp` or `remmina`. Example: `xfreerdp /v:203.0.113.10 /u:operator /p:- /dynamic-resolution /rfx /bpp:16`.
- **iPad**: Install Microsoft Remote Desktop, create a workspace with the VPS IP, username/passwordless (the session prompts for credentials). Reduce display quality for LTE connections.

## Firewall Management
Firewall rules are fully managed by the playbook via Hetzner Cloud. Ensure either `ANSIBLE_HCLOUD_SERVER_ID` (preferred) or `ANSIBLE_HCLOUD_SERVER_NAME` is populated, adjust `ANSIBLE_FIREWALL_ALLOWED_CIDRS` in `.env`, and rerun `./scripts/provision.sh` to converge. The automation enforces a default-deny stance: only SSH and RDP ports are open to the listed CIDRs.

To detach or destroy the firewall:
```bash
ansible-playbook -i ansible/inventories/hetzner.yml ansible/playbooks/remote-desktop.yml \
  --extra-vars '{"hetzner_firewall":{"allowed_cidrs":[]}}' --tags firewall
```

## SSH Key Rotation
1. Replace the old key in `.env` (either update `ANSIBLE_OPERATOR_PUBLIC_KEYS` or the referenced file `ANSIBLE_OPERATOR_PUBLIC_KEYS_FILE`).
2. Re-run `./scripts/provision.sh` to replace the authorized_keys file.
3. Verify the old key fails by attempting login from a terminal still holding it.

## Teardown & Reprovision
1. Delete the Hetzner VPS or rebuild it via the Hetzner console.
2. Optionally run `ansible-playbook ... --extra-vars '{"hetzner_firewall":{"state":"absent"}}' --tags firewall` to remove the firewall.
3. Update `.env` with the new host/IP (and keys if rebuilt) and rerun the provision script.

## Acceptance Checklist
- Provision script completes without Ansible errors.
- Operator user can SSH using public-key auth; root login is rejected.
- RDP session renders an Xfce desktop within ~10 seconds from an allowed client.
- `xrdp` and `xrdp-sesman` systemd services stay running after reboot.
- Firewall blocks SSH/RDP from a non-allowed IP (use a cloud test VM or `nmap` from another network).
- Key rotation via Ansible removes old keys and installs new ones.
