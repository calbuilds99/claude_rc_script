# claude_rc_script

Provision a resident, always-on **Claude Code** instance on any Linux VPS,
driven from [claude.ai/code](https://claude.ai/code) or the Claude mobile app
via **Remote Control**. The instance lives where your systems live, so it can
do what a cloud session can't: read service logs, run your deploy scripts (if
you grant them), and debug live behaviour — with you approving anything
sensitive from your phone.

One script, fully generic: `setup-claude-vps.sh`. Everything box-specific is
an environment variable; nothing about any particular server, repo, or account
is baked in. It is **idempotent** — re-running skips whatever already exists.

## Requirements

- Debian/Ubuntu-family VPS (uses `apt-get` and `systemd`).
- Root access for the one-time setup.
- A GitHub repo for Claude to work in, and permission to add a deploy key to it.
- A claude.ai subscription (Pro/Max; on Team/Enterprise an owner must enable
  Remote Control in admin settings first). **No API keys are stored on the box.**

## Security model (read before running)

| Control | How |
|---|---|
| No root agent | Dedicated `claude` user, password login disabled; reach it only via `sudo -iu claude` from root. |
| No escalation by default | `/etc/sudoers.d/claude` is installed **empty**. Claude cannot run anything as root or any other user unless you deliberately add exact command lines (see below). |
| Log access without privileges | The user joins `systemd-journal`, so `journalctl -u <service>` works with no sudo. |
| Secrets stay unreadable | Keep configs/secrets owned by root or your site user with tight modes (600/640). The `claude` user can't read other users' homes — don't loosen permissions for convenience. |
| Own working copy | Claude works in its own clone under `/home/claude/`, with a deploy key scoped to that one repo — never in a live docroot. Changes flow branch → PR/merge → your normal deploy pipeline. |
| Human approval | Keep the **default permission mode**. Approval prompts surface in the claude.ai / mobile UI. Do **not** run this instance with `--dangerously-skip-permissions` / `bypassPermissions` on a production box. |
| Network | Remote Control only dials **out** to Anthropic over TLS. No inbound ports, no firewall changes. |
| Resource caps | The systemd unit sets `MemoryMax` (default 4G) and `TasksMax` so a runaway session can't eat the box. |

## Install

### 1. Get the script onto the box and run it as root

```bash
# copy it over (or fetch it however you prefer), then:
REPO_GIT_URL=git@github.com:OWNER/REPO.git \
RC_NAME=my-vps \
bash setup-claude-vps.sh
```

All variables:

| Variable | Required | Default | What |
|---|---|---|---|
| `REPO_GIT_URL` | **yes** | — | SSH URL of the repo Claude works in |
| `RC_NAME` | recommended | short hostname | Name shown in the claude.ai environment picker |
| `CLAUDE_USER` | no | `claude` | Dedicated unix user |
| `WORKDIR` | no | `/home/claude/<repo>` | Where Claude's clone lives |
| `LOCAL_SEED_REPO` | no | *(empty)* | Existing repo on the box (working checkout **or** bare repo) to seed the clone from, so first setup needs no GitHub creds |
| `RC_CAPACITY` | no | `4` | Max concurrent remote sessions |
| `SERVICE_NAME` | no | `claude-remote` | systemd unit name |
| `GIT_EMAIL` | no | `claude@<hostname>` | Git author email for Claude's commits |
| `MEMORY_MAX` | no | `4G` | systemd MemoryMax for the daemon |
| `SUDO_GRANTS` | no | *(empty — no escalation)* | Full sudoers lines to install, see below |

The script installs base packages, creates the user, installs Claude Code (as
that user, native build), generates a deploy key, clones the repo (seeded
locally when `LOCAL_SEED_REPO` is set, else from GitHub), installs the empty
sudoers file, and writes the systemd unit. It does **not** start anything yet.

### 2. Add the printed deploy key to GitHub

Repo → **Settings → Deploy keys** → paste the key the script printed → tick
**Allow write access** if Claude should push branches. Deploy keys are
per-repo on GitHub, so each box/repo pair gets its own key — that's the point:
the key on the box can reach exactly one repo and nothing else.

(If you skipped `LOCAL_SEED_REPO` and the GitHub clone failed, re-run the
script now — it picks up where it left off.)

### 3. One-time login + Remote Control consent

Interactive; OAuth and the first-run prompt can't be scripted. **Run each
line separately — pasting the whole block breaks** (the `sudo`/`exit` lines
swallow the rest):

```bash
sudo -iu claude
cd ~/<repo> && claude
```

Inside Claude: run `/login`, open the URL it prints on your laptop/phone,
paste the code back, accept the **workspace trust** prompt, then exit Claude.
Do **not** type the next command inside the Claude prompt — exit first, then
at the shell:

```bash
claude remote-control --name <RC_NAME>
```

Answer **`y`** to `Enable Remote Control?`, wait for **Connected**, then
Ctrl+C, then `exit` back to root. First-run-only — the consent is stored.
**Skipping it means the headless service parks on that prompt forever**,
looking healthy in `systemctl status` while never registering.

### 4. Start the service (as root)

```bash
systemctl enable --now claude-remote
journalctl -u claude-remote -n 20 --no-pager
```

You want a `Connected` line and a `https://claude.ai/code?environment=env_…`
URL in the log. That URL is a bookmarkable direct link.

### 5. Use it

**claude.ai/code → New session → environment `<RC_NAME>`** (mobile: **Code**
tab → new session). The machine registers as an *environment* in the
new-session picker — it does not appear in the session list until a session is
running. Server mode (`--capacity 4 --spawn worktree`) hosts concurrent
sessions, each in its own git worktree; ending a chat frees its slot without
touching the daemon.

## Granting privileges (deliberately, never by default)

By default the instance can: work git in its own clone, read journald logs,
and nothing else privileged. If it should run specific commands as root or a
site user, pass exact sudoers lines via `SUDO_GRANTS` (validated with
`visudo -cf` before install), or add them to `/etc/sudoers.d/claude` later:

```bash
SUDO_GRANTS='claude ALL=(root) NOPASSWD: /usr/bin/systemctl restart my-service
claude ALL=(siteuser) NOPASSWD: /bin/bash /path/to/deploy-script.sh' \
REPO_GIT_URL=... RC_NAME=... bash setup-claude-vps.sh
```

Rules of thumb:

- **Exact command + exact arguments only.** No wildcards, no directories, no
  blanket `ALL`.
- Prefer running things as a **non-root** user (`(siteuser)`) where possible.
- If a granted script is writable by someone else (a site user, a CI push),
  whoever writes it can run code as the grant target — make sure that matches
  a trust boundary you already accept.
- Think twice before DB credentials or admin-API secrets: read-only users,
  separate creds, and remember query results may expose customer data.

## Operations

- **Update Claude Code:** `sudo -iu claude claude update` (or just restart the
  service — the native installer self-updates).
- **Watch the daemon:** `journalctl -u claude-remote -f`. The journal is
  chatty (the status screen redraws into it) — cosmetic; rotation handles it.
- **Stops are bounded:** the unit sets `TimeoutStopSec=15` because the daemon
  ignores SIGTERM while parked on a prompt — without it a restart hangs ~90s
  before systemd's SIGKILL (harmless but confusing).
- **Network blips:** reconnects automatically; if Anthropic is unreachable for
  ~10+ minutes the process exits and systemd respawns it (`Restart=always`).
- **Reboot:** credentials persist on disk and the unit is enabled — no
  re-login needed.
- **Decommission:** `systemctl disable --now claude-remote`, remove
  `/etc/sudoers.d/claude` and the unit file, `userdel -r claude`, delete the
  deploy key on GitHub, and sign the device out from claude.ai settings.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Service runs but the environment never appears on claude.ai | The one-time Remote Control consent (step 3) was skipped — the headless daemon is parked on the prompt. Stop the service, do step 3, start it again. |
| `Failed to enable unit: Access denied` | You ran `systemctl enable` as the `claude` user. It must run as **root** (the claude user deliberately has no systemd rights). |
| `user claude is not allowed to execute '/bin/bash' as claude` | You ran `sudo -iu claude` while already being the claude user — usually a sign a pasted block ran lines in the wrong shell. Run the steps one line at a time. |
| Typed `claude remote-control ...` and Claude started "working on" it | You typed it inside the Claude prompt. Exit Claude first; the command runs at the shell. |
| GitHub clone fails | The deploy key isn't on the repo yet (step 2), or the key is already attached to a different repo — GitHub deploy keys are strictly one-repo; generate a distinct key per repo. |
| Local seed clone fails | `LOCAL_SEED_REPO` isn't a git checkout or bare repo, or a permissions oddity — the script falls back to GitHub cloning automatically. |

## Scope: what this is *not* for

Scheduled data pulls and reporting jobs don't belong on a resident instance —
run those as claude.ai Routines against API connectors, with no VPS involved.
The resident instance is for hands-on-the-metal ops work on that box.
