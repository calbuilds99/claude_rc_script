#!/usr/bin/env bash
#
# setup-claude-vps.sh — provision a resident, least-privilege Claude Code
# instance on a Linux VPS and wire it up for always-on Remote Control
# (driven from claude.ai/code or the Claude mobile app).
#
# Generic: every box-specific value is an environment variable. Nothing about
# your servers, repos, or accounts is baked in. Idempotent — safe to re-run.
# See README.md for the full guide, security model, and manual follow-up steps.
#
# Minimal usage (as root):
#   REPO_GIT_URL=git@github.com:OWNER/REPO.git RC_NAME=my-vps \
#     bash setup-claude-vps.sh
#
# The script does NOT log the instance in to Claude — that is a one-time
# interactive step it prints at the end (OAuth login can't be scripted).
#
set -euo pipefail

# ---------------------------------------------------------------- settings --
# Required:
#   REPO_GIT_URL   SSH URL of the repo Claude will work in,
#                  e.g. git@github.com:OWNER/REPO.git
# Recommended:
#   RC_NAME        instance name shown in the claude.ai environment picker
#                  (defaults to this machine's short hostname)
# Optional:
#   CLAUDE_USER    dedicated unix user to create/use          (default: claude)
#   WORKDIR        where Claude's own clone lives   (default: ~claude/<repo>)
#   LOCAL_SEED_REPO  existing repo on this box (working checkout OR bare
#                  repo) to seed the clone from, so first setup needs no
#                  GitHub credentials; origin is re-pointed at REPO_GIT_URL
#                  afterwards. Leave empty to clone straight from GitHub
#                  (requires the deploy key to be added first, then re-run).
#   RC_CAPACITY    max concurrent remote sessions               (default: 4)
#   SERVICE_NAME   systemd unit name                (default: claude-remote)
#   GIT_EMAIL      git author email for Claude's commits
#                  (default: claude@<short hostname>)
#   MEMORY_MAX     systemd MemoryMax for the service           (default: 4G)
#   SUDO_GRANTS    optional, default EMPTY = no privilege escalation at all.
#                  If you deliberately want Claude to run specific commands
#                  as root or another user, set this to full sudoers lines
#                  (newline-separated, exact commands only — see README).
#                  The result is validated with visudo before install.

REPO_GIT_URL="${REPO_GIT_URL:-}"
CLAUDE_USER="${CLAUDE_USER:-claude}"
CLAUDE_HOME="/home/${CLAUDE_USER}"
RC_NAME="${RC_NAME:-$(hostname -s)}"
RC_CAPACITY="${RC_CAPACITY:-4}"
SERVICE_NAME="${SERVICE_NAME:-claude-remote}"
LOCAL_SEED_REPO="${LOCAL_SEED_REPO:-}"
GIT_EMAIL="${GIT_EMAIL:-claude@$(hostname -s)}"
MEMORY_MAX="${MEMORY_MAX:-4G}"
SUDO_GRANTS="${SUDO_GRANTS:-}"

if [[ -z "${REPO_GIT_URL}" ]]; then
  echo "ERROR: REPO_GIT_URL is required, e.g.:" >&2
  echo "  REPO_GIT_URL=git@github.com:OWNER/REPO.git RC_NAME=my-vps bash $0" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root." >&2
  exit 1
fi

# Derive the default workdir from the repo name: .../foo.git -> ~claude/foo
repo_base="$(basename "${REPO_GIT_URL}")"
repo_base="${repo_base%.git}"
WORKDIR="${WORKDIR:-${CLAUDE_HOME}/${repo_base}}"

echo "==> Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git ca-certificates ripgrep tmux jq >/dev/null

echo "==> User ${CLAUDE_USER} (non-root, no password login)"
if ! id -u "${CLAUDE_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${CLAUDE_USER}"
fi
passwd -l "${CLAUDE_USER}" >/dev/null || true   # reach it via `sudo -iu claude` from root
# journal group = read `journalctl -u <any-service>` with no sudo at all
usermod -aG systemd-journal "${CLAUDE_USER}"

echo "==> Claude Code (native build, installed as ${CLAUDE_USER})"
if [[ ! -x "${CLAUDE_HOME}/.local/bin/claude" ]]; then
  sudo -iu "${CLAUDE_USER}" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
fi
sudo -iu "${CLAUDE_USER}" "${CLAUDE_HOME}/.local/bin/claude" --version || true

echo "==> Deploy key for GitHub (scope it to ONE repo only)"
if [[ ! -f "${CLAUDE_HOME}/.ssh/id_ed25519" ]]; then
  sudo -iu "${CLAUDE_USER}" bash -c \
    'mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "claude@$(hostname -s)"'
fi
sudo -iu "${CLAUDE_USER}" bash -c \
  'grep -q github.com ~/.ssh/known_hosts 2>/dev/null || ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null'
# Print the key here, not just in the final summary, so a failure further down
# never leaves you without it.
echo "    Public deploy key (GitHub -> repo Settings -> Deploy keys):"
sudo -iu "${CLAUDE_USER}" cat "${CLAUDE_HOME}/.ssh/id_ed25519.pub"

echo "==> Repo checkout at ${WORKDIR} (Claude works here, never in a live docroot)"
if [[ ! -d "${WORKDIR}/.git" ]]; then
  seeded=0
  # The seed may be a normal checkout (has .git/) or a bare repo (is itself
  # the git dir, marked by a HEAD file).
  if [[ -n "${LOCAL_SEED_REPO}" && ( -d "${LOCAL_SEED_REPO}/.git" || -f "${LOCAL_SEED_REPO}/HEAD" ) ]]; then
    # A site user's home is often not traversable by other users (don't
    # loosen that), so ${CLAUDE_USER} may not be able to read the seed
    # repo directly. Root stages a throwaway bare mirror it CAN read,
    # hands it over, and the claude user clones from that instead. A local
    # clone runs upload-pack against the resolved .git dir, so BOTH path
    # forms need the dubious-ownership waiver in root's gitconfig.
    git config --global --add safe.directory "${LOCAL_SEED_REPO}"
    git config --global --add safe.directory "${LOCAL_SEED_REPO}/.git"
    SEED_TMP="$(mktemp -d "/tmp/claude-seed.XXXXXX")"
    trap 'rm -rf "${SEED_TMP}"' EXIT
    if git clone -q --bare "${LOCAL_SEED_REPO}" "${SEED_TMP}/repo.git" \
       && chown -R "${CLAUDE_USER}:${CLAUDE_USER}" "${SEED_TMP}" \
       && sudo -iu "${CLAUDE_USER}" git clone -q "${SEED_TMP}/repo.git" "${WORKDIR}"; then
      sudo -iu "${CLAUDE_USER}" git -C "${WORKDIR}" remote set-url origin "${REPO_GIT_URL}"
      seeded=1
    else
      echo "NOTE: local seed clone failed; falling back to cloning from GitHub." >&2
      sudo -iu "${CLAUDE_USER}" rm -rf "${WORKDIR}"
    fi
    rm -rf "${SEED_TMP}"
    trap - EXIT
  fi
  if [[ "${seeded}" -eq 0 ]]; then
    sudo -iu "${CLAUDE_USER}" git clone -q "${REPO_GIT_URL}" "${WORKDIR}" || {
      echo "NOTE: GitHub clone failed — add the deploy key printed above to GitHub, then re-run." >&2
    }
  fi
fi
sudo -iu "${CLAUDE_USER}" git -C "${WORKDIR}" config user.name  "Claude (${RC_NAME})" 2>/dev/null || true
sudo -iu "${CLAUDE_USER}" git -C "${WORKDIR}" config user.email "${GIT_EMAIL}" 2>/dev/null || true

echo "==> Scoped sudo (default: NO grants — nothing on this box escalates)"
SUDOERS_TMP="$(mktemp)"
{
  echo "# Resident Claude Code instance: least-privilege grants."
  echo "# Everything not listed here prompts for a password ${CLAUDE_USER}"
  echo "# does not have. Add exact command lines deliberately (validate with"
  echo "# visudo -cf) — never blanket root, never wildcards on arguments."
  if [[ -n "${SUDO_GRANTS}" ]]; then
    printf '%s\n' "${SUDO_GRANTS}"
  fi
} > "${SUDOERS_TMP}"
if visudo -cf "${SUDOERS_TMP}" >/dev/null; then
  install -m 0440 -o root -g root "${SUDOERS_TMP}" "/etc/sudoers.d/${CLAUDE_USER}"
else
  echo "ERROR: generated sudoers failed validation; not installed." >&2
  cat "${SUDOERS_TMP}" >&2
  rm -f "${SUDOERS_TMP}"
  exit 1
fi
rm -f "${SUDOERS_TMP}"

echo "==> systemd unit: ${SERVICE_NAME}.service (always-on Remote Control)"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=Claude Code Remote Control (${RC_NAME}, user ${CLAUDE_USER})
Documentation=https://code.claude.com/docs/en/remote-control
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CLAUDE_USER}
WorkingDirectory=${WORKDIR}
Environment=HOME=${CLAUDE_HOME}
Environment=PATH=${CLAUDE_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${CLAUDE_HOME}/.local/bin/claude remote-control --name ${RC_NAME} --capacity ${RC_CAPACITY} --spawn worktree
# Remote Control exits if it can't reach Anthropic for ~10 min — just respawn.
Restart=always
RestartSec=15
# The daemon ignores SIGTERM while parked on a prompt or busy; don't let a
# stop/restart hang for systemd's default 90s before the SIGKILL.
TimeoutStopSec=15
# Keep a runaway session from eating a box that also serves live traffic.
MemoryMax=${MEMORY_MAX}
TasksMax=512
# Do NOT set NoNewPrivileges=true here — it would break scoped sudo grants
# if you add any.

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

echo
echo "============================================================"
echo " Provisioned. Two manual steps remain:"
echo "============================================================"
echo
echo " 1) Add this deploy key to GitHub (repo -> Settings -> Deploy keys,"
echo "    'Allow write access' so Claude can push branches):"
echo
sudo -iu "${CLAUDE_USER}" cat "${CLAUDE_HOME}/.ssh/id_ed25519.pub" || true
echo
echo " 2) One-time login + Remote Control consent (interactive; can't be"
echo "    scripted). Run each line SEPARATELY — don't paste the block:"
echo "      sudo -iu ${CLAUDE_USER}"
echo "      cd ${WORKDIR} && claude"
echo "    -> run /login, open the printed URL on your laptop/phone, paste the"
echo "       code back, accept the workspace-trust prompt, then exit. Then:"
echo "      claude remote-control --name ${RC_NAME}"
echo "    -> answer 'y' to 'Enable Remote Control?', wait for 'Connected',"
echo "       then Ctrl+C, then 'exit' back to root. First run only — the"
echo "       consent is stored; without it the headless service parks on"
echo "       that prompt forever."
echo
echo " Then, AS ROOT, start the always-on service:"
echo "      systemctl enable --now ${SERVICE_NAME}"
echo "      journalctl -u ${SERVICE_NAME} -n 20 --no-pager   # 'Connected' + URL"
echo
echo " Start sessions via https://claude.ai/code -> New session -> environment"
echo " '${RC_NAME}' (mobile: Code tab -> new session). Direct link:"
echo "      journalctl -u ${SERVICE_NAME} -o cat | grep -m1 -o 'https://claude.ai[^ ]*'"
echo "============================================================"
