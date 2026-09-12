```
  ###################                                                         ####
  ###################                #####                                    ####
  ###################                #####                                    ####
  ###################       #################      #####           #####      ####
  ###################     ###################    ####  ####     ####   ###    ####
  ###################    ####        #####     ####     ####   ####     ####  ####
  ####             ##    #####       #####     ####      #### ####      ####  ####
  ###              ##     ######     #####    ############### ##############  ####
  ###            ####      #######   #####    ##############  ##############  ####
  ##            #####        ######  #####    #####           ####            ####
  ##          #######          ##### #####    #####           #####           ####
  ##         ########           #### #####     #####           ####           ####
  ###################           ####  ####      #####           #####         ####
  ###################    ##########    ######      #########      ##########  ####
```

# agentbox

One bash script that turns a bare [Steel](https://steel.dev) sandbox VM (or any fresh Debian/Ubuntu box) into a ready-to-work environment for **Claude Code** and **Codex CLI**.

Run it as root on a new VM. About two minutes later you have a non-root `agent` user, modern CLI tools, sane dotfiles, both agents installed and authenticated, and encrypted remote access via [tailcat](https://github.com/tailscale/tailcat). Re-running is safe: every step is idempotent.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/nibzard/agentbox/main/agentbox.sh | bash
```

Then:

```bash
work            # tmux session as the agent user in /workspace
yolo            # inside: claude --dangerously-skip-permissions
agent-status    # versions, auth, tmux sessions, tailcat, ports
```

## Why a non-root user

Claude Code refuses `--dangerously-skip-permissions` when run as root, and Steel VMs log you in as root. The script creates an `agent` user with passwordless sudo, installs the agents there, and gives root the `work` and `become` shortcuts to drop into it. Root's existing Claude login is copied across so you don't sign in twice.

## What it does

| Step | What |
|---|---|
| Preflight | Mounts `/proc` if missing (Bun binaries need it), trusts Steel's egress CA system-wide, persists the CA env vars into `/etc/profile.d` for every user |
| Sizing | Detects vCPU / RAM / disk. Tier `small` (<2 GB), `medium` (<6 GB), `large`. Creates a swapfile on small and medium boxes |
| Packages | git, tmux, procps, jq, vim, htop, lsof, openssh-client, rsync, sudo, python3, node, npm, plus ripgrep, fd, bat, eza, fzf, zoxide, git-delta, gh, direnv. btop and neovim on medium/large |
| User | `agent` with passwordless sudo, owns `/workspace`, shared history in `/commandhistory` |
| Dotfiles | bash (color prompt, red for root and green for agent, big timestamped history, fzf and zoxide), tmux (mouse, vi keys, no plugins), git (delta, rebase pull, autoSetupRemote, worktree alias), vim, inputrc |
| Agent config | Global `~/.claude/CLAUDE.md` describing the machine and its limits, symlinked as `~/.codex/AGENTS.md`. Claude `settings.json` with a read-only allowlist and denies for `.env` and `curl \| sh`. Codex `config.toml` |
| Agents | Claude Code and Codex CLI via their native installers, as the agent user |
| tailcat | Installed from the GitHub release `.deb` with checksum verification. Persistent key for a stable address |
| Helpers | `work`, `agent-status`, `new-project`, `killport`, `sysinfo`, `vm-ssh`, `vm-share` |

Build parallelism and Node heap size are set at every shell start from the current `nproc` and RAM, so a resized VM picks them up on the next login.

## Flags and environment

```bash
bash agentbox.sh                  # default profile
bash agentbox.sh --lean           # skip the modern CLI extras
bash agentbox.sh --with-dev       # + build-essential, pip/venv, uv, shellcheck, strace
bash agentbox.sh --no-copy-auth   # don't copy root's Claude credentials to the agent user
bash agentbox.sh --no-tailcat     # skip tailcat

AGENT_USER=dev  WORKSPACE=/src            bash agentbox.sh
GIT_NAME="Your Name" GIT_EMAIL=you@x.com  bash agentbox.sh
TAILCAT_SSH_KEYS=you@github               bash agentbox.sh   # vm-ssh requires these keys
SWAP_MB=0                                 bash agentbox.sh   # or SWAP_MB=4096
ANTHROPIC_API_KEY=... OPENAI_API_KEY=...  bash agentbox.sh   # seeded into ~/.agentbox/env
```

## Shell aliases

| Alias | Command |
|---|---|
| `yolo` | `claude --dangerously-skip-permissions` |
| `auto` / `plan` / `edits` / `safe` | Claude permission modes |
| `cc` / `cr` | `claude --continue` / `claude --resume` |
| `loop [prompt.md]` | Headless Claude loop over a prompt file |
| `cx` / `cx-yolo` / `cx-auto` | Codex CLI, bypass, full-auto |
| `tm <name>` / `tl` / `tk` | tmux attach-or-create, list, kill |
| `gwt <branch>` | Git worktree in a sibling directory, for parallel agents |
| `become` | root only: switch to the agent user |
| `tc` / `tc-ping` | tailcat |

## Remote access with tailcat

tailcat is Tailscale's data plane without the control plane: WireGuard, NAT traversal and DERP relays, but no account or tailnet. The server prints an address. Anyone holding that address can connect, so treat it like a password.

On the VM:

```bash
vm-ssh                  # SSH shell; requires TAILCAT_SSH_KEYS, else falls back to no-auth-ssh
vm-share 3000,8080      # expose local ports
vm-share --ephemeral 3000   # one-off address that dies with the process
```

On your laptop (`brew install tailcat` or a GitHub release):

```bash
tailcat ssh <address>
tailcat forward <address> 18080:8080     # then open http://localhost:18080
tailcat browse <address>                 # single web port, opens the browser
```

## Security notes

- Copying root's OAuth credentials into the agent user means anything the agent runs can read them. Fine for a throwaway VM. Use `--no-copy-auth` for anything longer-lived.
- `vm-ssh` without `TAILCAT_SSH_KEYS` runs a no-auth SSH server. The printed address is the credential. Set `TAILCAT_SSH_KEYS=you@github` to require your public keys.
- The global CLAUDE.md tells agents never to paste a tailcat address into a commit, log, or public place.
- Secrets belong in `~/.agentbox/env` (mode 600, sourced by bash) or a gitignored `.env`. The Claude settings deny reading both.

## Requirements

Debian 12/13 or Ubuntu 22.04+, root, outbound HTTPS. Tested on Steel sandbox VMs (Debian 13, 1 vCPU, 1 GB). Works on x86_64 and arm64.

## Credits

Modeled on the [anthropics/claude-code devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer), [nibzard/riftkit](https://github.com/nibzard/riftkit) and [yulonglin/dotfiles](https://github.com/yulonglin/dotfiles).

## License

MIT
