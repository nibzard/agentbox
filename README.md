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

One bash script that turns a bare [Steel](https://steel.dev) sandbox VM (or any fresh Debian/Ubuntu box) into a ready-to-work environment for **Claude Code**, **Codex CLI**, **OpenCode** and **pi**.

Run it as root on a new VM. About two minutes later you have a non-root `agent` user, modern CLI tools, sane dotfiles, both agents installed and authenticated, and encrypted remote access via [tailcat](https://github.com/tailscale/tailcat). Re-running is safe: every step is idempotent.

## Quick start

From your laptop, with the [Steel CLI](https://github.com/steel-dev/cli) installed. The script goes in over ssh, so the box needs nothing preinstalled:

```bash
steel computer create --wait --use --timeout 28800 --auto-pause
git clone https://github.com/nibzard/agentbox && cd agentbox
steel computer ssh -- bash -s < agentbox.sh
steel computer ssh
```

Or from a root shell on the box. Bare Steel VMs ship without `curl`, so install it first:

```bash
apt-get update && apt-get install -y ca-certificates curl
curl -fsSL https://raw.githubusercontent.com/nibzard/agentbox/main/agentbox.sh | bash
```

Then:

```bash
work              # tmux session as the agent user in /workspace
yolo              # inside: claude --dangerously-skip-permissions
agent-status      # versions, auth, tmux sessions, tailcat, ports
agentbox-verify   # acceptance checks for the box, exits non-zero on failure
```

Every interactive login outside tmux prints a short banner with these commands. Steel's sshd shows no motd on its own, so the shell prints it. Typing `claude`, `codex`, `opencode` or `pi` as root prints a pointer to `work` instead of "command not found". The agents live in the agent user only.

### Copy and paste inside tmux

tmux runs with the mouse on, so a drag selection copies into tmux and is sent to your local clipboard over OSC 52. iTerm2, Ghostty, WezTerm, kitty and Alacritty accept it (iTerm2 needs "Applications in terminal may access clipboard" enabled). Terminal.app does not. When the clipboard stays empty, either hold Option (macOS) or Shift (Linux) while selecting to bypass tmux, or press `C-b m` to turn the mouse off and select natively. Press `C-b m` again to turn it back on.

## Why a non-root user

Claude Code refuses `--dangerously-skip-permissions` when run as root, and Steel VMs log you in as root. The script creates an `agent` user with passwordless sudo, installs the agents there, and gives root the `work` and `become` shortcuts to drop into it. Root's existing Claude login is copied across so you don't sign in twice.

## What it does

| Step | What |
|---|---|
| Preflight | Mounts `/proc` if missing (Bun binaries need it), trusts Steel's egress CA system-wide, persists the CA env vars into `/etc/profile.d` for every user |
| Sizing | Detects vCPU / RAM / disk. Tier `small` (<1.8 GB), `medium` (<5.5 GB), `large`. Creates a swapfile on small and medium boxes |
| Packages | git, tmux, procps, jq, vim, htop, lsof, openssh-client, rsync, sudo, python3, node, npm, plus ripgrep, fd, bat, eza, fzf, zoxide, git-delta, gh, direnv. btop and neovim on medium/large |
| User | `agent` with passwordless sudo, owns `/workspace`, shared history in `/commandhistory` |
| Dotfiles | bash (color prompt, red for root and green for agent, big timestamped history, fzf and zoxide), tmux (mouse, vi keys, no plugins), git (delta, rebase pull, autoSetupRemote, worktree alias), vim, inputrc |
| Agent config | Global `~/.claude/CLAUDE.md` describing the machine and its limits, symlinked as the global `AGENTS.md` for Codex, OpenCode and pi. Claude `settings.json` with a read-only allowlist and denies for `.env` and `curl \| sh`. Codex `config.toml` |
| Agents | Claude Code, Codex CLI and OpenCode via their native installers, pi via npm, all as the agent user. pi needs Node >=22.19.0 and Debian ships 20, so the agent user gets the current Node LTS from the official tarball under `~/.local`, ahead of the system node. Sign-in: `claude`, `codex login`, `opencode auth login`, `pi` then `/login` |
| tailcat | Installed from the GitHub release `.deb` with checksum verification. Persistent key for a stable address |
| Helpers | `work`, `agent-status`, `agentbox-verify`, `new-project`, `killport`, `sysinfo`, `vm-ssh`, `vm-share`, and root shims for `claude`, `codex`, `opencode` and `pi` that point at `work` |

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
| `oc` / `oc-run "..."` | OpenCode, headless run |
| `pi` / `pi-p "..."` | pi, headless print mode |
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

## Running on Steel

Facts about [Steel computers](https://computers-preview.apidocumentation.com) that shape how you use agentbox. Verified against the preview API on 2026-09-12.

- **The clock is set at create time.** The default is one hour, the maximum is eight (`--timeout 28800`). There is no update call, so a box that is running out of time can only be checkpointed and restored with a new timeout.
- **Use `--auto-pause`.** At the deadline the box pauses instead of stopping, and any command sent to it wakes it. A resume starts a fresh timeout window. `--idle-timeout 1800` pauses it after 30 minutes without traffic, so it costs nothing while you are away.
- **Setup is cheap, sign-in is not.** The script rebuilds a box in about two minutes, so do not checkpoint a fresh install. Do checkpoint after the agents you use have signed in once (`claude`, `codex login`, `opencode auth login`, `pi` then `/login`):

  ```bash
  steel computer checkpoint --name authed --wait
  steel checkpoint restore <checkpoint-id> --timeout 28800 --auto-pause --wait --use
  ```

  A checkpoint holds the OAuth tokens. Anyone who can restore it is signed in as you.
- **Keys without files.** Steel can inject a header into every request to a domain, at the egress proxy, so the secret never exists on the box. Store the key once, then create the box with a network secret:

  ```bash
  curl -s https://api.steel.dev/v1/secrets -H "steel-api-key: $STEEL_API_KEY" \
    -H 'content-type: application/json' -d '{"name":"anthropic","value":"sk-ant-..."}'
  curl -s https://api.steel.dev/v1/computers -H "steel-api-key: $STEEL_API_KEY" \
    -H 'content-type: application/json' -d '{"timeoutSeconds":28800,"autoPause":true,
      "networkSecrets":[{"secretId":"<id>","domain":"api.anthropic.com","header":"x-api-key","template":"{{secret}}"}]}'
  ```

  Header injection is verified. Running Claude Code this way needs a placeholder `ANTHROPIC_API_KEY` so it sends the header at all, bills as API usage, and is not yet tested end to end. The `steel` CLI has no secrets or environments commands, so this is HTTP only for now.
- **The egress proxy does not intercept every host.** Steel sets per-tool CA variables (`NPM_CONFIG_CAFILE`, `SSL_CERT_FILE`, `PIP_CERT` and more) to a bundle that holds only its egress CA. Hosts the proxy passes through, such as the npm registry, then fail TLS verification in npm, pip and anything else that treats the variable as the whole trust store. The script redirects those variables to the system bundle, which holds the egress CA and the public roots.
- **ssh and exec live in different mount namespaces.** A fresh namespace has a stale `/proc` with no `/proc/self`, which breaks Bun-based Claude Code and `ss`. The script fixes the namespace it runs in, and every login shell fixes its own on start. `steel computer exec` runs `/bin/sh -c`, which reads no profile, so run agent commands there through a login shell: `steel computer exec -c 'bash -lc "..."'`. One healed session heals all later exec sessions on that box. `agentbox-verify` heals itself.
- **Delete what you are done with.** Five computers per account. `steel computer quota` shows the count.

## Tests

Local regressions require Bash and Python 3, with no third-party packages, root access, credentials, or network:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
```

The local harness extracts selected generated shell templates from `agentbox.sh` and runs them with temporary homes and stub commands. It does not run the installer or establish live VM compatibility. Run live Steel E2E separately:

`agentbox-verify` on the box is the acceptance suite: about 60 checks that the user, tools, agents, configs and helpers work, exercised rather than just present. `tests/e2e.sh` runs it the honest way: it creates a Steel computer, runs the script twice to prove idempotency, runs `agentbox-verify`, and deletes the box.

```bash
export STEEL_API_KEY=ste-...
tests/e2e.sh                              # full cycle, about four minutes
KEEP=1 tests/e2e.sh                       # leave the box running
COMPUTER_ID=cmp_... tests/e2e.sh          # against a box you already have
AGENTBOX_ARGS="--lean --no-tailcat" tests/e2e.sh
```

## Security notes

- Copying root's OAuth credentials into the agent user means anything the agent runs can read them. Fine for a throwaway VM. Use `--no-copy-auth` for anything longer-lived.
- `vm-ssh` without `TAILCAT_SSH_KEYS` runs a no-auth SSH server. The printed address is the credential. Set `TAILCAT_SSH_KEYS=you@github` to require your public keys.
- The global CLAUDE.md tells agents never to paste a tailcat address into a commit, log, or public place.
- Secrets belong in `~/.agentbox/env` (mode 600, sourced by bash) or a gitignored `.env`. The Claude settings deny reading both.

## Requirements

Debian 12/13 or Ubuntu 22.04+, root, outbound HTTPS. `curl` and `ca-certificates` are needed only for the `curl | bash` path; the ssh path installs them. Tested on Steel sandbox VMs (Debian 13) from 1 vCPU / 1 GB to 4 vCPU / 4 GB. Works on x86_64 and arm64.

## Credits

Modeled on the [anthropics/claude-code devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer), [nibzard/riftkit](https://github.com/nibzard/riftkit) and [yulonglin/dotfiles](https://github.com/yulonglin/dotfiles).

## License

MIT
