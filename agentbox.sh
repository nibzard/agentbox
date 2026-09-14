#!/usr/bin/env bash
#  ###################                                                         ####
#  ###################                #####                                    ####
#  ###################                #####                                    ####
#  ###################       #################      #####           #####      ####
#  ###################     ###################    ####  ####     ####   ###    ####
#  ###################    ####        #####     ####     ####   ####     ####  ####
#  ####             ##    #####       #####     ####      #### ####      ####  ####
#  ###              ##     ######     #####    ############### ##############  ####
#  ###            ####      #######   #####    ##############  ##############  ####
#  ##            #####        ######  #####    #####           ####            ####
#  ##          #######          ##### #####    #####           #####           ####
#  ##         ########           #### #####     #####           ####           ####
#  ###################           ####  ####      #####           #####         ####
#  ###################    ##########    ######      #########      ##########  ####
#
# =============================================================================
#  agentbox.sh — one-shot install + setup for a disposable agent VM/container
#
#  Turns a bare Debian/Ubuntu box (like a Steel sandbox) into a comfortable
#  workspace for Claude Code, Codex CLI, OpenCode and pi:
#    • fixes the usual container quirks (/proc, CA certs, PATH persistence)
#    • installs a lean modern CLI toolset (rg, fd, bat, eza, fzf, zoxide,
#      delta, gh, jq, tmux, git, vim, htop, node, python3 …)
#    • creates a non-root `agent` user with passwordless sudo, because
#      `claude --dangerously-skip-permissions` refuses to run as root
#    • installs Claude Code, Codex, OpenCode (native installers) and pi (npm on
#      a user-level Node LTS, since Debian's Node 20 is too old) for that user
#    • drops opinionated dotfiles: bash, tmux, git, inputrc, global CLAUDE.md
#      / AGENTS.md, Claude settings, Codex config, agent aliases
#    • adds helpers: work, agent-status, agentbox-verify, new-project, killport, sysinfo
#    • optionally copies root's existing Claude login into the agent user
#
#  Usage (as root):
#    bash agentbox.sh                 # default profile
#    bash agentbox.sh --with-dev      # + build-essential, pip/venv, uv, shellcheck
#    bash agentbox.sh --lean          # agents + essentials only, skip fancy CLI
#    bash agentbox.sh --no-copy-auth  # don't copy root's ~/.claude creds to agent
#    bash agentbox.sh --no-tailcat    # skip tailcat (Tailscale's account-free tunnel/SSH tool)
#    TAILCAT_SSH_KEYS=you@github bash agentbox.sh   # vm-ssh requires these SSH keys
#    AGENT_USER=dev bash agentbox.sh  # pick a different username
#
#  Re-running is safe; every step is idempotent.
#  Inspired by: anthropics/claude-code .devcontainer, nibzard/riftkit,
#  yulonglin/dotfiles.
# =============================================================================
set -euo pipefail

# ---------- config -----------------------------------------------------------
AGENT_USER="${AGENT_USER:-agent}"
WORKSPACE="${WORKSPACE:-/workspace}"
PROFILE="default"          # default | lean
WITH_DEV=0
COPY_AUTH=1
WITH_TAILCAT=1
TAILCAT_VERSION="${TAILCAT_VERSION:-latest}"
TAILCAT_SSH_KEYS="${TAILCAT_SSH_KEYS:-}"   # e.g. "niko@github" or ~/.ssh/authorized_keys
GIT_NAME="${GIT_NAME:-}"
GIT_EMAIL="${GIT_EMAIL:-}"

for arg in "$@"; do
  case "$arg" in
    --lean)         PROFILE="lean" ;;
    --with-dev)     WITH_DEV=1 ;;
    --no-copy-auth) COPY_AUTH=0 ;;
    --no-tailcat)   WITH_TAILCAT=0 ;;
    -h|--help)      sed -n '17,45p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# ---------- helpers ----------------------------------------------------------
c_blue=$'\e[1;34m'; c_green=$'\e[1;32m'; c_yellow=$'\e[1;33m'; c_red=$'\e[1;31m'; c_off=$'\e[0m'
hdr()  { printf '\n%s==> %s%s\n' "$c_blue" "$*" "$c_off"; }
ok()   { printf '%s  ✔ %s%s\n' "$c_green" "$*" "$c_off"; }
info() { printf '  · %s\n' "$*"; }
warn() { printf '%s  ! %s%s\n' "$c_yellow" "$*" "$c_off"; }
die()  { printf '%s  ✘ %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Replace (or append) a marker-delimited block in a file. Idempotent.
# usage: put_block <file> <marker> <<'EOF' ... EOF
put_block() {
  local file="$1" marker="$2" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  mkdir -p "$(dirname "$file")"; touch "$file"
  # drop any previous block (markers included), then append the fresh one
  awk -v m="$marker" '$0=="# >>> " m " >>>"{s=1;next} $0=="# <<< " m " <<<"{s=0;next} !s' "$file" > "$file.new" && mv "$file.new" "$file"
  { printf '\n# >>> %s >>>\n' "$marker"; cat "$tmp"; printf '# <<< %s <<<\n' "$marker"; } >> "$file"
  rm -f "$tmp"
}

as_agent() { su - "$AGENT_USER" -c "$*"; }

# Configured identity helpers.
validate_agentbox_configuration() {
  local entry account password uid gid gecos home shell canonical
  [[ $AGENT_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $AGENT_USER != root ]] || { warn "Invalid non-root AGENT_USER"; return 1; }
  [[ $WORKSPACE == /* && ! $WORKSPACE =~ [[:cntrl:]] ]] || { warn "WORKSPACE must be an absolute path without control characters"; return 1; }
  canonical=$(realpath -m -- "$WORKSPACE") || return 1
  [[ $canonical != / ]] || { warn "WORKSPACE must not resolve to /"; return 1; }
  if entry=$(getent passwd "$AGENT_USER"); then
    IFS=: read -r account password uid gid gecos home shell <<< "$entry"
    [[ $uid =~ ^[0-9]+$ && $uid != 0 && $home == /* && $home != / && ! $home =~ [[:cntrl:]] ]] || { warn "Unsupported existing account identity/home for $AGENT_USER"; return 1; }
    [[ $shell == /bin/bash || $shell == /usr/bin/bash ]] || { warn "Existing $AGENT_USER account must use Bash; its shell was not changed"; return 1; }
    [[ $(id -gn "$AGENT_USER") == "$AGENT_USER" ]] || { warn "Existing $AGENT_USER account must have a matching primary group; its group was not changed"; return 1; }
  fi
}
persist_agentbox_configuration() {
  local destination=$1 temporary
  temporary=$(mktemp "${destination}.tmp.XXXXXXXXXX") || return 1
  if { ca_export AGENT_USER "$AGENT_USER" && ca_export WORKSPACE "$WORKSPACE"; } > "$temporary" \
      && sh -n "$temporary" && chmod 0644 "$temporary" && mv -f -- "$temporary" "$destination"; then
    return 0
  else
    rm -f -- "$temporary"
    return 1
  fi
}
# End configured identity helpers.

[[ $EUID -eq 0 ]] || die "run as root"
validate_agentbox_configuration || die "unsupported agentbox configuration"
export DEBIAN_FRONTEND=noninteractive

printf '%s' "$c_blue"; cat <<'LOGO'
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
LOGO
printf '%s\n           agentbox  ·  agent VM setup for Steel sandboxes\n\n' "$c_off"

# ---------- /proc (before anything reads it) --------------------------------
# Bun-based binaries (Claude Code) need a *working* procfs. On fresh Steel VMs
# /proc is mounted but stale (no /proc/self), so `mountpoint` passes while Bun
# aborts with "panic(main thread)" and `df` cannot read the mount table. Test
# /proc/self and remount over it before the sizing step reads /proc.
# The remount is per mount namespace: Steel gives ssh sessions and exec
# sessions different ones. Login shells repeat this check (step 4) so the
# other namespace heals on first use.
if [[ ! -e /proc/self/mounts ]]; then
  mount -t proc proc /proc && ok "remounted /proc (was stale: no /proc/self)" || warn "could not mount /proc"
else
  ok "/proc healthy"
fi

# ---------- machine sizing (Steel VMs come as 1/2/4 vCPU with varying RAM/disk)
CPUS=$(nproc)
MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
DISK_FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
IS_STEEL=0; [[ -d /run/steel ]] && IS_STEEL=1
if   (( MEM_MB < 1800 )); then TIER=small
elif (( MEM_MB < 5500 )); then TIER=medium
else                            TIER=large; fi
SWAP_MB="${SWAP_MB:-auto}"     # auto | 0 | <MB>
printf '  machine: %s vCPU, %s MB RAM, %s GB free, tier=%s, steel=%s\n' "$CPUS" "$MEM_MB" "$DISK_FREE_GB" "$TIER" "$IS_STEEL"

# =============================================================================
hdr "1/10  Preflight: apt, CA certificates"
# =============================================================================
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg >/dev/null
ok "apt ready"

# Steel (and similar sandboxes) inject an egress CA via env vars. Trust it
# system-wide and persist those vars for every user/login shell.
# CA persistence helpers.
detect_egress_ca() {
  local cand
  EGRESS_CA=
  for cand in "$@"; do
    if [[ -n "$cand" && -s "$cand" ]]; then EGRESS_CA=$cand; break; fi
  done
}
ca_export() {
  local name=$1 value=$2
  value=${value//\'/\'\\\'\'}
  printf "export %s='%s'\n" "$name" "$value"
}
emit_ca_profile() {
  local bundle=$1 additive=$2 name value
  printf '%s\n' '# CA paths use the system bundle (egress CA + public roots).' || return 1
  while IFS= read -r name; do
    case $name in
      *_CA_BUNDLE|*CAINFO|*CA_CERTS*|*CAFILE|*CACERTS*|*_CERT|SSL_CERT_FILE|PIP_CERT|CONDA_SSL_VERIFY|DENO_TLS_CA_STORE|UV_NATIVE_TLS|*_SSL_CA_FILE)
        [[ $name =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
        value=${!name}
        if [[ $name != NODE_EXTRA_CA_CERTS && $value == /* ]]; then value=$bundle; fi
        ca_export "$name" "$value" || return 1
        ;;
    esac
  done < <(compgen -e)
  for name in SSL_CERT_FILE REQUESTS_CA_BUNDLE PIP_CERT NPM_CONFIG_CAFILE; do
    if [[ -z ${!name:-} ]]; then ca_export "$name" "$bundle" || return 1; fi
  done
  if [[ -z ${NODE_EXTRA_CA_CERTS:-} ]]; then ca_export NODE_EXTRA_CA_CERTS "$additive" || return 1; fi
  if [[ -z ${UV_NATIVE_TLS:-} ]]; then ca_export UV_NATIVE_TLS 1 || return 1; fi
  return 0
}
persist_ca_profile() {
  local profile=$1 bundle=$2 additive=$3 temporary
  temporary=$(mktemp "${profile}.tmp.XXXXXXXXXX") || return 1
  if emit_ca_profile "$bundle" "$additive" > "$temporary" \
      && sh -n "$temporary" && chmod 0644 "$temporary" && mv -f -- "$temporary" "$profile"; then
    return 0
  else
    rm -f -- "$temporary"
    return 1
  fi
}
# End CA persistence helpers.
detect_egress_ca "${NODE_EXTRA_CA_CERTS:-}" "${SSL_CERT_FILE:-}" /run/steel/egress-ca.crt
if [[ -n "$EGRESS_CA" ]]; then
  install -m 0644 "$EGRESS_CA" /usr/local/share/ca-certificates/sandbox-egress-ca.crt
  update-ca-certificates >/dev/null
  # The sandbox sets per-tool CA variables to a bundle that holds only the
  # egress CA. Most of those variables REPLACE the trust store, and the proxy
  # passes some hosts through untouched (registry.npmjs.org, for one), so npm
  # and friends then fail with "unable to get local issuer certificate".
  # Point every path-valued variable at the system bundle instead: it now
  # holds the egress CA and the public roots. NODE_EXTRA_CA_CERTS is additive
  # and keeps the single egress CA. Runtimes with their own store get defaults.
  SYS_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  persist_ca_profile /etc/profile.d/00-agentbox-egress-ca.sh "$SYS_BUNDLE" \
    /usr/local/share/ca-certificates/sandbox-egress-ca.crt
  # The rest of this script runs installers as $AGENT_USER through login shells,
  # which read profile.d. Load it here too so nothing in this run misses it.
  . /etc/profile.d/00-agentbox-egress-ca.sh
  chmod 0644 /etc/profile.d/00-agentbox-egress-ca.sh
  ok "trusted egress CA ($EGRESS_CA) and persisted CA env vars"
else
  ok "no sandbox egress CA detected"
fi

# =============================================================================
hdr "2/10  Packages"
# =============================================================================
BASE_PKGS=(
  git tmux procps less unzip zip xz-utils file jq vim htop lsof
  iproute2 openssh-client rsync tree bash-completion sudo man-db
  python3 nodejs npm sqlite3 ncdu
  ncurses-term   # terminfo for xterm-kitty, wezterm, alacritty, foot and more; `work` falls back to xterm-256color for the rest (xterm-ghostty)
)
CLI_PKGS=( ripgrep fd-find bat eza fzf zoxide git-delta gh direnv )
DEV_PKGS=( build-essential python3-pip python3-venv python3-dev shellcheck strace )
BIG_PKGS=( btop neovim )   # only on medium/large boxes

PKGS=( "${BASE_PKGS[@]}" )
[[ $PROFILE == "lean" ]] || PKGS+=( "${CLI_PKGS[@]}" )
[[ $WITH_DEV -eq 1 ]] && PKGS+=( "${DEV_PKGS[@]}" )
[[ $PROFILE != "lean" && $TIER != "small" ]] && PKGS+=( "${BIG_PKGS[@]}" )

# install only what is missing / available
TO_INSTALL=()
for p in "${PKGS[@]}"; do
  if dpkg -s "$p" >/dev/null 2>&1; then continue; fi
  if apt-cache show "$p" >/dev/null 2>&1; then TO_INSTALL+=("$p"); else warn "skip $p (not in repo)"; fi
done
if ((${#TO_INSTALL[@]})); then
  # apt output is hidden, so say up front that this step is the slow one.
  info "installing ${#TO_INSTALL[@]} packages, the slowest step (about 1-2 minutes, apt output hidden)"
  apt-get install -y -qq --no-install-recommends "${TO_INSTALL[@]}" >/dev/null
  ok "installed: ${TO_INSTALL[*]}"
else
  ok "all packages already present"
fi
apt-get clean; rm -rf /var/lib/apt/lists/*

# Swap: small boxes die on node/rust builds without it. Sized to RAM, capped
# by free disk. SWAP_MB=0 disables; SWAP_MB=<n> forces.
if [[ $SWAP_MB == auto ]]; then
  if   (( MEM_MB < 1800 )); then SWAP_MB=2048
  elif (( MEM_MB < 5500 )); then SWAP_MB=1024
  else                           SWAP_MB=0; fi
  (( DISK_FREE_GB < 4 )) && SWAP_MB=0
fi
if (( SWAP_MB > 0 )) && ! grep -q '^/swapfile' /proc/swaps; then
  if fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null && chmod 600 /swapfile \
     && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -qw vm.swappiness=10 2>/dev/null || true
    ok "swapfile ${SWAP_MB} MB active"
  else
    rm -f /swapfile; warn "swap not supported in this VM (skipped)"
  fi
elif grep -q '^/swapfile' /proc/swaps; then ok "swapfile already active"
else ok "no swap needed (tier=$TIER)"; fi

# Debian renames these binaries; give them their upstream names.
[[ -x /usr/bin/batcat && ! -e /usr/local/bin/bat ]] && ln -s /usr/bin/batcat /usr/local/bin/bat
[[ -x /usr/bin/fdfind && ! -e /usr/local/bin/fd ]]  && ln -s /usr/bin/fdfind /usr/local/bin/fd

# =============================================================================
hdr "3/10  Non-root user '$AGENT_USER' + $WORKSPACE"
# =============================================================================
if ! id "$AGENT_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$AGENT_USER"
  ok "created user $AGENT_USER"
else
  ok "user $AGENT_USER exists"
fi
AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
persist_agentbox_configuration /etc/agentbox.conf
echo "$AGENT_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$AGENT_USER"
chmod 0440 "/etc/sudoers.d/90-$AGENT_USER"
mkdir -p "$WORKSPACE" "$AGENT_HOME/projects"
chown "$AGENT_USER:$AGENT_USER" "$WORKSPACE" "$AGENT_HOME/projects"
# Persist bash history across sessions in one well-known place.
mkdir -p /commandhistory && touch /commandhistory/.bash_history
chown -R "$AGENT_USER:$AGENT_USER" /commandhistory
ok "sudo, $WORKSPACE, /commandhistory ready"

# =============================================================================
hdr "4/10  System-wide shell defaults (/etc/profile.d)"
# =============================================================================
cat > /etc/profile.d/10-agentbox.sh <<'EOF'
# agentbox: shared defaults for every login shell (root and agent user)
. /etc/agentbox.conf || return 1
export AGENT_USER WORKSPACE
# Steel runs ssh and exec sessions in separate mount namespaces, and a fresh
# one has a stale /proc (no /proc/self). Bun (Claude Code) and ss need it.
# Mount it once per namespace; the agent user has passwordless sudo for this.
if [ ! -e /proc/self/mounts ]; then
  if [ "$(id -u)" -eq 0 ]; then mount -t proc proc /proc 2>/dev/null
  else sudo -n mount -t proc proc /proc 2>/dev/null; fi
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
export EDITOR=vim VISUAL=vim PAGER=less LESS='-R -F -X'
export LANG="${LANG:-C.UTF-8}" LC_ALL="${LC_ALL:-C.UTF-8}"
export AGENTBOX=1 DEVCONTAINER=true
export PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1
# Size build parallelism and heap to THIS boot's resources (VM may be resized).
__cpus=$(nproc 2>/dev/null || echo 1)
__mem=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024)
export MAKEFLAGS="-j${__cpus}" CARGO_BUILD_JOBS="${__cpus}" UV_CONCURRENT_INSTALLS="${__cpus}"
export NODE_OPTIONS="--max-old-space-size=$(( __mem * 6 / 10 ))"   # ~60% of RAM
export AGENTBOX_TIER=$([ "$__mem" -lt 1800 ] && echo small || { [ "$__mem" -lt 5500 ] && echo medium || echo large; })
unset __cpus __mem
export NPM_CONFIG_FUND=false NPM_CONFIG_UPDATE_NOTIFIER=false
export GIT_EDITOR=true
EOF
chmod 0644 /etc/profile.d/10-agentbox.sh
ok "/etc/profile.d/10-agentbox.sh"

# =============================================================================
hdr "5/10  Dotfiles (agent user, mirrored to root where sensible)"
# =============================================================================
write_dotfiles() {
  local home="$1" owner="$2"

  # ---- .bashrc -------------------------------------------------------------
  put_block "$home/.bashrc" "agentbox" <<'EOF'
# --- environment --------------------------------------------------------------
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
[ -f /etc/profile.d/00-agentbox-egress-ca.sh ] && . /etc/profile.d/00-agentbox-egress-ca.sh
[ -f /etc/profile.d/10-agentbox.sh ] && . /etc/profile.d/10-agentbox.sh
[ -f "$HOME/.agentbox/env" ] && . "$HOME/.agentbox/env"   # API keys etc. (chmod 600)

# --- login banner: Steel's sshd has no PAM motd, so the shell prints it --------
case "$-" in *i*) [ -z "${TMUX:-}" ] && [ -s /etc/motd ] && cat /etc/motd ;; esac

# --- history: big, shared, appended, timestamped ------------------------------
if [ -w /commandhistory/.bash_history ]; then export HISTFILE=/commandhistory/.bash_history; fi
export HISTSIZE=100000 HISTFILESIZE=200000 HISTCONTROL=ignoreboth:erasedups HISTTIMEFORMAT='%F %T  '
shopt -s histappend checkwinsize cmdhist globstar autocd cdspell dirspell 2>/dev/null
PROMPT_COMMAND='history -a'

# --- prompt: coloured by user (red root / green agent), shows git branch -------
__git_ps1_lite() { local b; b=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) && printf ' (%s)' "$b"; }
if [ "$EUID" -eq 0 ]; then __uc='\[\e[1;31m\]'; else __uc='\[\e[1;32m\]'; fi
PS1="${__uc}\u\[\e[0m\]@\[\e[1;36m\]\h\[\e[0m\] \[\e[1;34m\]\w\[\e[0;33m\]\$(__git_ps1_lite)\[\e[0m\]\n\$ "
unset __uc

# --- completion / tool init ---------------------------------------------------
[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion
[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && . /usr/share/doc/fzf/examples/key-bindings.bash
[ -f /usr/share/doc/fzf/examples/completion.bash ]   && . /usr/share/doc/fzf/examples/completion.bash
command -v zoxide >/dev/null && eval "$(zoxide init bash)"
command -v direnv >/dev/null && eval "$(direnv hook bash)"
command -v gh     >/dev/null && eval "$(gh completion -s bash 2>/dev/null)"
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git 2>/dev/null || find . -type f'
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'

# --- aliases: files -----------------------------------------------------------
if command -v eza >/dev/null; then
  alias ls='eza --group-directories-first'; alias ll='eza -la --group-directories-first --git'
  alias la='eza -a --group-directories-first'; alias lt='eza -T -L2 --group-directories-first'
else
  alias ls='ls --color=auto'; alias ll='ls -alF'; alias la='ls -A'
fi
command -v bat >/dev/null && alias cat='bat --paging=never --style=plain'
alias ..='cd ..'; alias ...='cd ../..'
alias w='cd -- "$WORKSPACE"'; alias p='cd ~/projects'
mkcd() { mkdir -p "$1" && cd "$1"; }

# --- aliases: git -------------------------------------------------------------
alias g='git' gs='git status -sb' ga='git add' gaa='git add -A' gc='git commit -m' gca='git commit -am'
alias gp='git push' gpl='git pull --rebase' gco='git checkout' gcb='git checkout -b' gb='git branch'
alias gd='git diff' gds='git diff --staged' gl='git log --oneline -15' gll='git log --oneline --graph --decorate --all'
gwt() { # gwt <branch>  -> create a worktree in ../<repo>.<branch> for a parallel agent
  local root; root=$(git rev-parse --show-toplevel) || return 1
  git worktree add -b "$1" "${root}.${1//\//-}" 2>/dev/null || git worktree add "${root}.${1//\//-}" "$1"
}

# --- aliases: agents ----------------------------------------------------------
# Claude Code. bypass mode only works as a NON-root user.
alias yolo='claude --dangerously-skip-permissions'
alias auto='claude --permission-mode auto'
alias plan='claude --permission-mode plan'
alias edits='claude --permission-mode acceptEdits'
alias safe='claude --permission-mode default'
alias cc='claude --continue'
alias cr='claude --resume'
# headless: loop over a prompt file  (usage: loop [prompt.md] [sleep])
loop() { local f="${1:-prompt.md}" s="${2:-2}"; [ -f "$f" ] || { echo "no $f"; return 1; }
  while :; do claude -p --dangerously-skip-permissions "$(cat "$f")"; sleep "$s"; done; }
# tailcat (account-free encrypted tunnels; see vm-ssh / vm-share)
alias tc='tailcat'
alias tc-ping='tailcat ping --until-direct'
# Codex CLI
alias cx='codex'
alias cx-yolo='codex --dangerously-bypass-approvals-and-sandbox'
alias cx-auto='codex --full-auto'
# OpenCode (`oc`) and pi (`pi`) share the global AGENTS.md via symlinks.
alias oc='opencode'
alias oc-run='opencode run'     # headless: oc-run "prompt"
alias pi-p='pi -p'              # headless: pi-p "prompt"
if [ "$EUID" -eq 0 ] && id "$AGENT_USER" >/dev/null 2>&1; then
  alias become='cd / && exec su - "$AGENT_USER"'    # root -> agent user
fi

# --- aliases: system ----------------------------------------------------------
alias ports='ss -tlnp'
alias mem='free -h'
alias disk='df -h / /tmp'
alias psg='ps aux | grep -v grep | grep -i'
alias tl='tmux ls'
tm() { [ -n "$1" ] || { tmux ls 2>/dev/null || echo "no sessions"; return; }; tmux attach -t "$1" 2>/dev/null || tmux new -s "$1"; }
tk() { tmux kill-session -t "$1"; }
serve() { python3 -m http.server "${1:-8000}" --bind 0.0.0.0; }
EOF

  # ---- .inputrc ------------------------------------------------------------
  cat > "$home/.inputrc" <<'EOF'
$include /etc/inputrc
set completion-ignore-case on
set show-all-if-ambiguous on
set show-all-if-unmodified on
set colored-stats on
set colored-completion-prefix on
set mark-symlinked-directories on
set bell-style none
"\e[A": history-search-backward
"\e[B": history-search-forward
EOF

  # ---- .tmux.conf ----------------------------------------------------------
  cat > "$home/.tmux.conf" <<'EOF'
# agentbox tmux: no plugins, works offline, mouse on, sane defaults
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc"
set -g mouse on
set -g history-limit 100000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -s escape-time 10
set -g focus-events on
# Copy from a mouse selection reaches the local clipboard over OSC 52. The
# outer terminal (through steel ssh) does not advertise the capability, so
# declare it. Terminals without OSC 52 support: use prefix+m and select natively.
set -g set-clipboard on
set -as terminal-features ',*:clipboard'
bind m set -g mouse \; display "mouse #{?mouse,on,off}"
setw -g mode-keys vi
set -g status-interval 5
set -g status-style "bg=colour236,fg=colour250"
set -g status-left "#[bold,fg=colour114] #S #[default]│ "
set -g status-right "#[fg=colour246]#(whoami)@#h │ %H:%M "
setw -g window-status-current-style "bg=colour239,fg=colour114,bold"
# splits: | and -  (prefix stays C-b so nothing surprises a remote user)
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"
bind r source-file ~/.tmux.conf \; display "reloaded"
# vim-style pane movement
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
# quick agent layout: left = agent, right = shell
bind A split-window -h -p 35 -c "#{pane_current_path}" \; select-pane -L
EOF

  # ---- .gitconfig ----------------------------------------------------------
  cat > "$home/.gitconfig" <<EOF
[user]
	name = ${GIT_NAME:-Agent}
	email = ${GIT_EMAIL:-agent@localhost}
[init]
	defaultBranch = main
[push]
	autoSetupRemote = true
	default = current
[pull]
	rebase = true
[fetch]
	prune = true
[rebase]
	autoStash = true
[rerere]
	enabled = true
[core]
	editor = vim
	pager = $(have delta && echo delta || echo less)
[interactive]
	diffFilter = $(have delta && echo "delta --color-only" || echo cat)
[delta]
	navigate = true
	side-by-side = false
	line-numbers = true
[merge]
	conflictstyle = zdiff3
[diff]
	colorMoved = default
[alias]
	st = status -sb
	lg = log --oneline --graph --decorate -20
	wt = worktree
	undo = reset --soft HEAD~1
[safe]
	directory = *
[credential]
	helper = store
EOF

  # ---- .vimrc ----------------------------------------------------------------
  cat > "$home/.vimrc" <<'EOF'
set nocompatible number ruler showcmd wildmenu incsearch hlsearch ignorecase smartcase
set tabstop=4 shiftwidth=4 expandtab autoindent backspace=indent,eol,start
set mouse=a clipboard=unnamedplus laststatus=2 hidden nobackup noswapfile
syntax on
filetype plugin indent on
EOF

  chown -R "$owner:$owner" "$home/.bashrc" "$home/.inputrc" "$home/.tmux.conf" "$home/.gitconfig" "$home/.vimrc"
}

write_dotfiles "$AGENT_HOME" "$AGENT_USER"
write_dotfiles /root root
ok "bash / tmux / git / vim / inputrc for $AGENT_USER and root"

# =============================================================================
hdr "6/10  Agent configs: CLAUDE.md, AGENTS.md, settings, Codex config"
# =============================================================================
mkdir -p "$AGENT_HOME/.claude" "$AGENT_HOME/.codex" "$AGENT_HOME/.config/opencode" "$AGENT_HOME/.pi/agent" "$AGENT_HOME/.agentbox"

cat > "$AGENT_HOME/.claude/CLAUDE.md" <<EOF
# Global instructions for this agent VM

## Environment
- Disposable $( ((IS_STEEL)) && echo "Steel sandbox VM" || echo "Linux sandbox") (Debian $(. /etc/os-release; echo "$VERSION_ID")).
  Sized at setup as $CPUS vCPU / $MEM_MB MB RAM / $DISK_FREE_GB GB free (tier: $TIER). The VM may be
  resized between boots: run \`sysinfo\` before planning heavy work. \`\$AGENTBOX_TIER\` reflects the current boot.
$( case $TIER in
  small)  echo "- Small box: run one thing at a time, prefer incremental builds/tests, avoid parallel test runners and \`npm ci\` on big trees. Swap is enabled but slow." ;;
  medium) echo "- Medium box: parallel builds are fine (MAKEFLAGS/CARGO_BUILD_JOBS follow nproc). Watch memory when running a dev server and a test suite together." ;;
  large)  echo "- Large box: parallel builds, multiple worktrees and concurrent agents are fine." ;;
esac )
- You run as user \`$AGENT_USER\` with passwordless sudo. Work lives in \`$WORKSPACE\` (or \`~/projects\`).
$( ((IS_STEEL)) && echo "- Outbound HTTPS goes through Steel's egress proxy; its CA is trusted system-wide and via env vars. Never disable TLS verification." )
- /tmp is a tmpfs sized to half of RAM. Put large temporary files or build caches under \`$WORKSPACE/.tmp\`.

## Tools available
- Search: \`rg\` (ripgrep) and \`fd\` instead of grep/find. \`jq\` for JSON, \`bat\` for viewing.
- Git: \`delta\` pager, \`gh\` CLI. Use worktrees (\`git worktree add\`) for parallel branches.
- Runtimes: python3, node/npm. Languages beyond that: install with \`sudo apt-get install -y ...\`.
- Remote access: \`tailcat\` (Tailscale data plane, no account). \`vm-share 3000\` exposes a dev server to the
  user's laptop; \`vm-ssh\` exposes a shell. Never paste a tailcat address into a commit, log, or public place.
- Sessions: tmux is installed; long-running servers belong in a tmux window, not the foreground.

## Conventions
- Conventional commits (feat:, fix:, docs:, refactor:, chore:). Small, reviewable commits.
- Never commit secrets. Secrets live in \`~/.agentbox/env\` or per-project \`.env\` (gitignored).
- Follow the project's own CLAUDE.md / AGENTS.md when present; they override this file.
- Before declaring done: run the project's tests/lint, and state plainly what was not verified.
EOF
# Codex, OpenCode and pi read a global AGENTS.md; keep one source of truth.
ln -sfn "$AGENT_HOME/.claude/CLAUDE.md" "$AGENT_HOME/.codex/AGENTS.md"
ln -sfn "$AGENT_HOME/.claude/CLAUDE.md" "$AGENT_HOME/.config/opencode/AGENTS.md"
ln -sfn "$AGENT_HOME/.claude/CLAUDE.md" "$AGENT_HOME/.pi/agent/AGENTS.md"

# Claude Code user settings (merge-free: only written if absent so re-runs
# don't clobber choices the user made from inside Claude).
if [[ ! -s "$AGENT_HOME/.claude/settings.json" ]]; then
cat > "$AGENT_HOME/.claude/settings.json" <<'EOF'
{
  "theme": "dark",
  "env": {
    "COLORTERM": "truecolor",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "0"
  },
  "permissions": {
    "allow": [
      "Bash(git status*)", "Bash(git diff*)", "Bash(git log*)", "Bash(git branch*)",
      "Bash(rg *)", "Bash(fd *)", "Bash(ls *)", "Bash(cat *)", "Bash(jq *)",
      "Bash(npm test*)", "Bash(npm run lint*)", "Bash(python3 -m pytest*)"
    ],
    "deny": [
      "Read(~/.agentbox/env)", "Read(./.env)", "Read(./.env.*)",
      "Bash(curl * | sh*)", "Bash(curl * | bash*)"
    ]
  }
}
EOF
fi

# Codex CLI config
if [[ ! -s "$AGENT_HOME/.codex/config.toml" ]]; then
cat > "$AGENT_HOME/.codex/config.toml" <<'EOF'
# Codex CLI defaults for the agent VM. `cx-yolo` alias bypasses everything.
approval_policy = "on-request"
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = true

[history]
persistence = "save-all"
EOF
fi

# Secrets file (sourced by .bashrc). Seed from the provisioning env if present.
ENVF="$AGENT_HOME/.agentbox/env"
touch "$ENVF"
for k in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY GH_TOKEN GITHUB_TOKEN; do
  v="${!k:-}"
  if [[ -n "$v" ]] && ! grep -q "^export $k=" "$ENVF"; then
    printf 'export %s=%q\n' "$k" "$v" >> "$ENVF"; ok "seeded $k into ~/.agentbox/env"
  fi
done
chmod 0600 "$ENVF"
chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_HOME/.claude" "$AGENT_HOME/.codex" "$AGENT_HOME/.config" "$AGENT_HOME/.pi" "$AGENT_HOME/.agentbox"
ok "CLAUDE.md, AGENTS.md symlinks (codex, opencode, pi), settings.json, codex config.toml"

# =============================================================================
hdr "7/10  Install Claude Code, Codex, OpenCode, pi for $AGENT_USER"
# =============================================================================
# Required agent installation helpers.
required_failures=()
record_required_failure() { required_failures+=("$1"); warn "$1 unavailable; see ~/.agentbox/install-$1.log and ~/.agentbox/health-$1.log as $AGENT_USER"; }
agent_health() (
  set -eu
  umask 077
  local name=$1 output status log
  log="$HOME/.agentbox/health-$name.log"
  mkdir -p "$HOME/.agentbox"
  : > "$log"
  chmod 0600 "$log"
  if ! test -x "$HOME/.local/bin/$name"; then
    printf '%s\n' 'Missing executable at the expected user-local path.' >> "$log"
    exit 1
  fi
  if output=$("$HOME/.local/bin/$name" --version 2> >(head -c 1048576 > "$log"; cat >/dev/null)); then
    if test -n "$output"; then printf '%s\n' "$output"; exit 0; fi
    printf '%s\n' 'Version command returned empty output.' >> "$log"
  else
    status=$?
    printf 'Version command exited %s. Captured stdout follows:\n' "$status" >> "$log"
    printf '%s\n' "$output" | head -c 1048576 >> "$log"
  fi
  exit 1
)
run_agent_installer() (
  set -eu
  umask 077
  local name=$1 url=$2 interpreter=$3
  temporary=
  mkdir -p "$HOME/.agentbox" "$HOME/.local/bin"
  # Bound only the log sink; continue draining so large installers can finish.
  : > "$HOME/.agentbox/install-$name.log"
  chmod 0600 "$HOME/.agentbox/install-$name.log"
  exec > >(head -c 1048576 > "$HOME/.agentbox/install-$name.log"; cat >/dev/null) 2>&1
  log_pid=$!
  trap 'status=$?; rm -f -- "$temporary"; exec 1>&- 2>&-; wait "$log_pid" || true; exit "$status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ "$name" = pi ]; then
    npm config set prefix "$HOME/.local"
    npm install -g --ignore-scripts @earendil-works/pi-coding-agent
  else
    temporary=$(mktemp "$HOME/.agentbox/installer.XXXXXXXXXX")
    curl -fsSL -o "$temporary" "$url"
    if [ "$name" = opencode ]; then export PATH="$HOME/.opencode/bin:$PATH"; fi
    "$interpreter" "$temporary"
    if [ "$name" = opencode ]; then
      test -x "$HOME/.opencode/bin/opencode"
      ln -sfn "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"
    fi
  fi
)
agent_version() {
  local command
  printf -v command 'agent_health %q' "$1"
  as_agent "$(declare -f agent_health); $command"
}
install_required_agent() {
  local name=$1 url=$2 interpreter=$3 version command
  if version=$(agent_version "$name"); then
    ok "$name already installed: ${version%%$'\n'*}"
    return 0
  fi
  printf -v command 'run_agent_installer %q %q %q' "$name" "$url" "$interpreter"
  if as_agent "$(declare -f run_agent_installer); $command" \
      && version=$(agent_version "$name"); then
    ok "$name installed: ${version%%$'\n'*}"
  else
    record_required_failure "$name"
  fi
}
required_installations_ready() {
  if (( ${#required_failures[@]} )); then
    warn "Required installations failed: ${required_failures[*]}. Diagnostic helpers are available; rerun setup after resolving the failures."
    return 1
  fi
}
# End required agent installation helpers.
install_required_agent claude https://claude.ai/install.sh bash
install_required_agent codex https://chatgpt.com/codex/install.sh sh
install_required_agent opencode https://opencode.ai/install bash
# User-local Node runtime helpers.
node_version_supported() {
  [[ ${1:-} =~ ^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || return 1
  (( BASH_REMATCH[1] > 22 || (BASH_REMATCH[1] == 22 && BASH_REMATCH[2] >= 19) ))
}
select_node_release() {
  local index candidates version
  case "$(uname -m)" in
    x86_64) NODE_ARCH=x64;;
    aarch64) NODE_ARCH=arm64;;
    *) warn "Unsupported architecture for the user-local Node runtime"; return 1;;
  esac
  index=$(curl -fsSL https://nodejs.org/dist/index.json) || { warn "Node index download failed"; return 1; }
  candidates=$(printf '%s' "$index" | jq -er 'if type != "array" then error("expected array") else .[] | select(type == "object") | select((.lts | type) == "string") | select(.lts | length > 0) | .version | select(type == "string") end') || { warn "Invalid Node index or no LTS releases"; return 1; }
  while IFS= read -r version; do
    if node_version_supported "$version"; then NODE_VER=$version; return 0; fi
  done <<< "$candidates"
  warn "Node index contains no eligible stable LTS (requires >=22.19.0)"
  return 1
}
install_node_runtime() (
  set -eu
  umask 077
  local version=$1 arch=$2 archive checksum actual destination
  node_temporary=
  mkdir -p "$HOME/.agentbox" "$HOME/.local/bin" "$HOME/.local/lib/agentbox-node"
  : > "$HOME/.agentbox/install-node.log"
  chmod 0600 "$HOME/.agentbox/install-node.log"
  exec > >(head -c 1048576 > "$HOME/.agentbox/install-node.log"; cat >/dev/null) 2>&1
  node_log_pid=$!
  trap 'status=$?; [ -z "$node_temporary" ] || rm -rf -- "$node_temporary"; exec 1>&- 2>&-; wait "$node_log_pid" || true; exit "$status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  node_version_supported "$version"
  case "$arch" in x64|arm64) ;; *) exit 1;; esac
  node_temporary=$(mktemp -d "$HOME/.local/lib/agentbox-node/.staging.XXXXXXXXXX")
  archive="node-$version-linux-$arch.tar.xz"
  curl -fsSL -o "$node_temporary/$archive" "https://nodejs.org/dist/$version/$archive"
  curl -fsSL -o "$node_temporary/checksums" "https://nodejs.org/dist/$version/SHASUMS256.txt"
  checksum=$(awk -v archive="$archive" '$2 == archive { print $1 }' "$node_temporary/checksums")
  [[ $checksum =~ ^[0-9a-fA-F]{64}$ ]]
  (cd "$node_temporary"; printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c --quiet -)
  mkdir "$node_temporary/runtime"
  tar -xJf "$node_temporary/$archive" -C "$node_temporary/runtime" --strip-components=1
  actual=$("$node_temporary/runtime/bin/node" -v)
  node_version_supported "$actual"
  [[ $actual == "$version" ]]
  actual=$("$node_temporary/runtime/bin/node" "$node_temporary/runtime/lib/node_modules/npm/bin/npm-cli.js" --version)
  [[ -n $actual ]]
  test -f "$node_temporary/runtime/lib/node_modules/npm/bin/npm-cli.js"
  test -f "$node_temporary/runtime/lib/node_modules/npm/bin/npx-cli.js"
  # Promote only this validated runtime; npm globals and other local tools stay put.
  destination="$HOME/.local/lib/agentbox-node/runtime-${node_temporary##*.}"
  mv "$node_temporary/runtime" "$destination"
  ln -sfn "$destination/bin/node" "$HOME/.local/bin/node"
  ln -sfn "$destination/lib/node_modules/npm/bin/npm-cli.js" "$HOME/.local/bin/npm"
  ln -sfn "$destination/lib/node_modules/npm/bin/npx-cli.js" "$HOME/.local/bin/npx"
)
ensure_node_runtime() {
  local command version
  if version=$(as_agent 'node -v 2>/dev/null') && node_version_supported "$version"; then
    ok "node $version for $AGENT_USER"
    return 0
  fi
  if ! select_node_release; then return 1; fi
  printf -v command 'install_node_runtime %q %q' "$NODE_VER" "$NODE_ARCH"
  if as_agent "$(declare -f node_version_supported install_node_runtime); $command" \
      && version=$(as_agent 'node -v 2>/dev/null') && node_version_supported "$version"; then
    ok "node $version (LTS) installed for $AGENT_USER in ~/.local"
    return 0
  fi
  return 1
}
# End user-local Node runtime helpers.
# pi needs Node >=22.19.0; keep root and apt on the distro runtime.
if ensure_node_runtime; then
  install_required_agent pi '' ''
else
  record_required_failure node
  record_required_failure pi
  warn "pi installation skipped because its Node runtime is unavailable"
fi
if [[ $WITH_DEV -eq 1 ]]; then
  if agent_version uv >/dev/null 2>&1; then
    ok "uv already installed"
  elif as_agent "$(declare -f run_agent_installer); run_agent_installer uv https://astral.sh/uv/install.sh sh" \
      && agent_version uv >/dev/null 2>&1; then
    ok "uv installed"
  else
    warn "uv install failed; see ~/.agentbox/install-uv.log and ~/.agentbox/health-uv.log as $AGENT_USER"
  fi
fi

# Copy root's existing Claude login so the agent user doesn't have to re-auth.
# NOTE: this puts your OAuth credentials in the agent user's home; anything the
# agent runs can read them. Fine for a throwaway VM, skip with --no-copy-auth.
if [[ $COPY_AUTH -eq 1 && -s /root/.claude/.credentials.json && ! -s "$AGENT_HOME/.claude/.credentials.json" ]]; then
  install -m 0600 -o "$AGENT_USER" -g "$AGENT_USER" /root/.claude/.credentials.json "$AGENT_HOME/.claude/.credentials.json"
  if [[ -s /root/.claude.json ]]; then
    # keep oauthAccount + onboarding flags, drop root's per-project state
    if have jq; then
      jq '{oauthAccount, hasCompletedOnboarding, theme, userID} | with_entries(select(.value != null))' /root/.claude.json \
        > "$AGENT_HOME/.claude.json" 2>/dev/null || cp /root/.claude.json "$AGENT_HOME/.claude.json"
    else
      cp /root/.claude.json "$AGENT_HOME/.claude.json"
    fi
    chown "$AGENT_USER:$AGENT_USER" "$AGENT_HOME/.claude.json"; chmod 0600 "$AGENT_HOME/.claude.json"
  fi
  ok "copied root's Claude credentials to $AGENT_USER"
fi
if [[ $COPY_AUTH -eq 1 && -s /root/.codex/auth.json && ! -s "$AGENT_HOME/.codex/auth.json" ]]; then
  install -m 0600 -o "$AGENT_USER" -g "$AGENT_USER" /root/.codex/auth.json "$AGENT_HOME/.codex/auth.json"
  ok "copied root's Codex auth to $AGENT_USER"
fi

# =============================================================================
hdr "8/10  tailcat (Tailscale data plane, no account): SSH / port tunnels into the VM"
# =============================================================================
# https://github.com/tailscale/tailcat — netcat-like, WireGuard + NAT traversal +
# DERP relays, no tailnet or login. Perfect for reaching a disposable VM whose
# only inbound path is Steel's SSH wrapper. Installed from the GitHub release
# .deb with checksum verification. Needs no root/TUN at runtime.
if [[ $WITH_TAILCAT -eq 1 ]]; then
  TC_ARCH=$(dpkg --print-architecture)            # amd64 | arm64 | armhf
  [[ $TC_ARCH == armhf ]] && TC_ARCH=armv7
  if [[ $TAILCAT_VERSION == latest ]]; then
    if TC_TAG=$(curl -fsSL https://api.github.com/repos/tailscale/tailcat/releases/latest 2>/dev/null) \
        && TC_TAG=$(printf '%s' "$TC_TAG" | jq -er '.tag_name | select(type == "string")') \
        && [[ $TC_TAG =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
      TAILCAT_VERSION=${TC_TAG#v}
    else
      TAILCAT_VERSION=0.6.0
      warn "GitHub release lookup failed, pinning tailcat $TAILCAT_VERSION"
    fi
  fi
  INSTALLED_TC=$(dpkg-query -W -f='${Version}' tailcat 2>/dev/null || true)
  if [[ $INSTALLED_TC == "$TAILCAT_VERSION" ]]; then
    ok "tailcat $TAILCAT_VERSION already installed"
  else
    TC_TMP=$(mktemp -d); TC_BASE="https://github.com/tailscale/tailcat/releases/download/v${TAILCAT_VERSION}"
    TC_DEB="tailcat_${TAILCAT_VERSION}_linux_${TC_ARCH}.deb"
    if curl -fsSL -o "$TC_TMP/$TC_DEB" "$TC_BASE/$TC_DEB" \
       && curl -fsSL -o "$TC_TMP/checksums.txt" "$TC_BASE/checksums.txt" \
       && (cd "$TC_TMP" && grep " $TC_DEB\$" checksums.txt | sha256sum -c --quiet -) \
       && dpkg -i "$TC_TMP/$TC_DEB" >/dev/null; then
      ok "tailcat $(tailcat version 2>/dev/null | head -1 || echo "$TAILCAT_VERSION") installed"
    else
      warn "tailcat install failed (network or checksum)"
    fi
    rm -rf "$TC_TMP"
  fi

  if have tailcat; then
    # Stable address for this VM's lifetime: a saved "default" key for the agent
    # user. Ephemeral (--key=new) is still available for one-off shares.
    if ! as_agent 'test -s ~/.config/tailcat/keys/default.private.json'; then
      as_agent 'tailcat genkey --key=default' >/dev/null 2>&1 && ok "generated persistent tailcat key for $AGENT_USER" \
        || warn "tailcat genkey failed (needs network for relay selection)"
    else
      ok "tailcat default key exists for $AGENT_USER"
    fi
    if [[ -n $TAILCAT_SSH_KEYS ]]; then
      printf 'export TAILCAT_SSH_KEYS=%q\n' "$TAILCAT_SSH_KEYS" > /etc/profile.d/20-agentbox-tailcat.sh
      ok "vm-ssh will require keys from: $TAILCAT_SSH_KEYS"
    fi
  fi
else
  ok "tailcat skipped (--no-tailcat)"
fi

# =============================================================================
hdr "9/10 Helper commands in /usr/local/bin"
# =============================================================================
cat > /usr/local/bin/vm-ssh <<'EOF'
#!/usr/bin/env bash
# vm-ssh [--ephemeral] — expose an SSH shell into this VM over tailcat.
#   With TAILCAT_SSH_KEYS set (e.g. "you@github,~/.ssh/authorized_keys") the
#   server requires those public keys. Without it, falls back to no-auth-ssh,
#   where the printed address IS the credential: share it privately only.
# Connect from anywhere:  tailcat ssh <address>
set -e
. /etc/agentbox.conf || exit 1
export AGENT_USER WORKSPACE
if [ "$(id -u)" -eq 0 ]; then
  printf -v command '%q ' vm-ssh "$@"
  exec su - "$AGENT_USER" -c "$command"
fi
key=(); [ "${1:-}" = "--ephemeral" ] && { key=(--key=new); shift; }
if [ -n "${TAILCAT_SSH_KEYS:-}" ]; then
  exec tailcat serve "${key[@]}" --ssh-authorized-keys="$TAILCAT_SSH_KEYS" ssh "$@"
else
  echo "! TAILCAT_SSH_KEYS unset -> no-auth-ssh. Anyone with the address gets a shell as $(id -un)." >&2
  exec tailcat serve "${key[@]}" no-auth-ssh "$@"
fi
EOF

cat > /usr/local/bin/vm-share <<'EOF'
#!/usr/bin/env bash
# vm-share <port>[,<port>...] | all   — expose local TCP ports over tailcat.
# On your laptop:  tailcat forward <address> 18080:8080   (then open localhost:18080)
#             or:  tailcat browse <address>               (single web port)
set -e
. /etc/agentbox.conf || exit 1
export AGENT_USER WORKSPACE
if [ "$(id -u)" -eq 0 ]; then
  printf -v command '%q ' vm-share "$@"
  exec su - "$AGENT_USER" -c "$command"
fi
[ -n "${1:-}" ] || { echo "usage: vm-share 3000,8080 | all"; exit 2; }
exec tailcat serve "$@"
EOF
chmod 0755 /usr/local/bin/vm-ssh /usr/local/bin/vm-share
ok "vm-ssh, vm-share"

cat > /usr/local/bin/work <<'EOF'
#!/usr/bin/env bash
# work [session] — attach or create a tmux session in the configured workspace.
. /etc/agentbox.conf || exit 1
export AGENT_USER WORKSPACE
if [ "$(id -u)" -eq 0 ]; then
  printf -v command '%q ' work "$@"
  exec su - "$AGENT_USER" -c "$command"
fi
s="${1:-work}"
infocmp "${TERM:-dumb}" >/dev/null 2>&1 || export TERM=xterm-256color
cd -- "$WORKSPACE" 2>/dev/null || { echo "Cannot access configured workspace: $WORKSPACE" >&2; exit 1; }
exec tmux new-session -A -s "$s" -c "$WORKSPACE"
EOF

cat > /usr/local/bin/agent-status <<EOF
#!/usr/bin/env bash
# agent-status — one-screen view of the box and the agents
b() { printf '\e[1;34m%s\e[0m\n' "\$*"; }
b "host";    echo "  \$(hostname)  \$(. /etc/os-release; echo \$PRETTY_NAME)  \$(uname -r)"
b "load";    echo "  cpu=\$(nproc) load=\$(cut -d' ' -f1-3 /proc/loadavg) mem=\$(free -m | awk '/Mem/{print \$3"/"\$2" MB"}') disk=\$(df -h / | awk 'NR==2{print \$3"/"\$2}')"
b "agents";
# one line per agent for the agent user: version and whether an auth file exists.
# Versions run as $AGENT_USER so pi finds the agent's Node LTS, not root's node.
h=\$(getent passwd $AGENT_USER | cut -d: -f6)
while read -r name authf; do
  v=\$(su - $AGENT_USER -c "\$name --version 2>/dev/null" | head -1); [ -n "\$v" ] || v="(not installed)"
  [ -s "\$h/\$authf" ] && a="auth✔" || a="no-auth"
  printf '  %-9s %-34s %s\n' "\$name" "\$v" "\$a"
done <<AGENTS
claude .claude/.credentials.json
codex .codex/auth.json
opencode .local/share/opencode/auth.json
pi .pi/agent/auth.json
AGENTS
b "tailcat"; if command -v tailcat >/dev/null; then
  echo "  $(tailcat version 2>/dev/null | head -1)  saved-keys: $(su - $AGENT_USER -c 'tailcat genkey --list 2>/dev/null' | tr '\n' ' ')"
  pgrep -af 'tailcat serve' | sed 's/^/  running: /' || true
else echo "  (not installed)"; fi
b "tmux";    tmux ls 2>/dev/null | sed 's/^/  /' || echo "  (none)"
b "listen";  ss -tlnp 2>/dev/null | awk 'NR>1{print "  "\$4}' | sort -u
b "workspace"; ls -1 $WORKSPACE 2>/dev/null | sed 's/^/  /' || echo "  (empty)"
EOF

cat > /usr/local/bin/new-project <<'EOF'
#!/usr/bin/env bash
# new-project <name> [dir] — git repo with CLAUDE.md + AGENTS.md scaffold
set -e
. /etc/agentbox.conf || exit 1
export AGENT_USER WORKSPACE
name="${1:?usage: new-project <name> [parent-dir]}"; parent="${2:-$WORKSPACE}"
d="$parent/$name"; mkdir -p "$d"; cd "$d"
[ -d .git ] || git init -q
[ -f CLAUDE.md ] || cat > CLAUDE.md <<MD
# $name

## What this is
(one paragraph)

## Commands
- install:
- dev:
- test:
- lint:

## Conventions
- Follow the global ~/.claude/CLAUDE.md. Project rules here override it.
MD
[ -e AGENTS.md ] || ln -s CLAUDE.md AGENTS.md
[ -f .gitignore ] || printf '.env\n.env.*\nnode_modules/\n__pycache__/\n.venv/\n.tmp/\n' > .gitignore
mkdir -p .tmp
git add -A && git commit -qm "chore: scaffold $name" || true
echo "created $d"
EOF

cat > /usr/local/bin/killport <<'EOF'
#!/usr/bin/env bash
# killport <port> — kill whatever listens on <port>
p="${1:?usage: killport <port>}"
pids=$(ss -tlnp "sport = :$p" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u)
[ -n "$pids" ] || { echo "nothing on :$p"; exit 0; }
echo "$pids" | xargs -r kill -9 && echo "killed $pids on :$p"
EOF

cat > /usr/local/bin/sysinfo <<'EOF'
#!/usr/bin/env bash
printf '%-8s %s\n' host "$(hostname)" os "$(. /etc/os-release; echo $PRETTY_NAME)" kernel "$(uname -r)" \
  cpu "$(nproc)x $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)" \
  mem "$(free -h | awk '/Mem/{print $3" used / "$2}')" swap "$(free -h | awk '/Swap/{print $3" used / "$2}')" \
  tier "${AGENTBOX_TIER:-?}" disk "$(df -h / | awk 'NR==2{print $3" used / "$2" ("$5")"}')" tmp "$(df -h /tmp | awk 'NR==2{print $2" tmpfs"}')" \
  ip "$(hostname -I 2>/dev/null | xargs)" up "$(awk '{printf "%dm", $1/60}' /proc/uptime)" user "$(id -un)"
EOF
chmod 0755 /usr/local/bin/{work,agent-status,new-project,killport,sysinfo}
ok "work, agent-status, new-project, killport, sysinfo"

# The agents are installed for $AGENT_USER only. Root typing `claude` gets a
# hint instead of "command not found". For other users the shim runs their own
# ~/.local/bin copy, so it never shadows a real install in a login shell.
for bin in claude codex opencode pi; do
  cat > "/usr/local/bin/$bin" <<EOF
#!/usr/bin/env bash
# $bin shim: point root at the agent user, run the caller's own install otherwise.
if [ "\$(id -u)" -eq 0 ]; then
  echo "$bin is installed for the '$AGENT_USER' user, not root. Run 'work' (tmux as $AGENT_USER) and then '$bin'." >&2
  exit 1
fi
[ -x "\$HOME/.local/bin/$bin" ] && exec "\$HOME/.local/bin/$bin" "\$@"
echo "$bin is not installed for \$(id -un). Re-run agentbox.sh as root." >&2
exit 127
EOF
  chmod 0755 "/usr/local/bin/$bin"
done
ok "root shims for claude, codex, opencode, pi"

# agentbox-verify: the acceptance checks for this box. Runs as $AGENT_USER (root
# is redirected) and exits non-zero on any failure. Values that depend on the
# install go in the first block; the checks themselves are a quoted heredoc.
cat > /usr/local/bin/agentbox-verify <<EOF
#!/usr/bin/env bash
# ABOUTME: Acceptance checks for a box set up by agentbox.sh: system, user, tools, agents, configs, helpers.
# ABOUTME: Run as the agent user (root is redirected). Exits non-zero when any check fails.
. /etc/agentbox.conf || exit 1
export AGENT_USER WORKSPACE
$(declare -f node_version_supported)
EOF
cat >> /usr/local/bin/agentbox-verify <<'EOF'
# A fresh exec session can have a stale /proc (see /etc/profile.d/10-agentbox.sh).
[ -e /proc/self/mounts ] || mount -t proc proc /proc 2>/dev/null || sudo -n mount -t proc proc /proc 2>/dev/null
if [ "$(id -u)" -eq 0 ]; then
  printf -v command '%q ' agentbox-verify "$@"
  exec su - "$AGENT_USER" -c "$command"
fi
pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skp()  { printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip+1)); }
note() { printf '  \033[34mINFO\033[0m %s\n' "$1"; }
# t <label> <shell snippet>: PASS when the snippet exits 0. Runs in a subshell so
# an `exit` inside the snippet cannot end the suite.
t() { if (eval "$2") >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n\033[1;34m== %s ==\033[0m\n' "$1"; }
# Verifier resource helpers: acquisition must run in the parent shell.
verify_tmp=; verify_session=; session_owned=0; listener_pid=; listener_port=
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "$listener_pid" ]; then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
  fi
  if [ "$session_owned" -eq 1 ]; then tmux kill-session -t "$verify_session" 2>/dev/null || true; fi
  if [ -n "$verify_tmp" ]; then rm -rf -- "$verify_tmp"; fi
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
allocate_resources() {
  verify_tmp=$(mktemp -d "$WORKSPACE/.agentbox-verify.XXXXXXXXXX") || return 1
  verify_session="abverify-${verify_tmp##*.}"
  project_dir="$verify_tmp/project"
}
create_session() {
  tmux new -d -s "$verify_session" || return 1
  session_owned=1
  tmux has -t "$verify_session"
}
check_listener() {
  local attempt owners
  python3 - "$verify_tmp/port" <<'PYLISTENER' >/dev/null 2>&1 &
import socket
import sys
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    with open(sys.argv[1], "w") as ready:
        ready.write(str(listener.getsockname()[1]) + "\n")
    while True:
        connection, _ = listener.accept()
        connection.close()
PYLISTENER
  listener_pid=$!
  for ((attempt=0; attempt<50; attempt++)); do
    kill -0 "$listener_pid" 2>/dev/null || return 1
    [ -s "$verify_tmp/port" ] && break
    sleep 0.1
  done
  [ -s "$verify_tmp/port" ] || return 1
  read -r listener_port < "$verify_tmp/port"
  [[ "$listener_port" =~ ^[0-9]+$ ]] && [ "$listener_port" -gt 0 ] && [ "$listener_port" -le 65535 ] || return 1
  owners=$(ss -H -tlnp "sport = :$listener_port") || return 1
  owners=$(printf '%s\n' "$owners" | grep -o 'pid=[0-9]*' | sort -u)
  [ "$owners" = "pid=$listener_pid" ] || return 1
  kill -0 "$listener_pid" 2>/dev/null || return 1
  killport "$listener_port" >/dev/null 2>&1 || return 1
  for ((attempt=0; attempt<50; attempt++)); do
    if ! kill -0 "$listener_pid" 2>/dev/null; then
      wait "$listener_pid" 2>/dev/null || true
      listener_pid=
      return 0
    fi
    sleep 0.1
  done
  return 1
}
command_matches() {
  local pattern=$1 output
  shift
  output=$("$@" 2>/dev/null) || return 1
  printf '%s\n' "$output" | grep -qiE "$pattern"
}
check_alias() { bash -ic "type $1" >/dev/null 2>&1; }
check_pager() {
  local expected=less
  command -v delta >/dev/null 2>&1 && expected=delta
  [ "$(git config --global core.pager)" = "$expected" ]
}
# End verifier resource helpers.
allocate_resources || { bad "cannot allocate verifier temporary directory"; exit 1; }

section "system"
t "/proc works (bun requirement)"                    'test -r /proc/self/cmdline'
if grep -q '^/swapfile' /proc/swaps; then
  t "swapfile active"                                'awk "/SwapTotal/{exit (\$2+0)>0?0:1}" /proc/meminfo'
else skp "swap (not configured on this tier)"; fi
t "HTTPS egress with trusted CA (curl)"              'curl -fsS -o /dev/null -w "%{http_code}" https://api.github.com/zen | grep -q 200'
t "HTTPS egress with trusted CA (npm, cafile)"       'npm view npm version 2>/dev/null | grep -qE "^[0-9]"'
if [ -s /etc/profile.d/00-agentbox-egress-ca.sh ]; then
  t "egress CA env persisted in profile.d"           'grep -q "CA" /etc/profile.d/00-agentbox-egress-ca.sh'
else skp "egress CA env (no sandbox CA on this box)"; fi
t "/etc/profile.d/10-agentbox.sh present"            'test -s /etc/profile.d/10-agentbox.sh'
t "/etc/motd present"                                'test -s /etc/motd'

section "agent user and workspace"
t "running as non-root '$AGENT_USER'"                'test "$(id -un)" = "$AGENT_USER"'
t "passwordless sudo"                                'sudo -n true'
t "$WORKSPACE owned by $AGENT_USER"                  'test "$(stat -c %U "$WORKSPACE")" = "$AGENT_USER"'
t "shared history file writable"                     'test -w /commandhistory/.bash_history'
t "HISTFILE points at shared history (interactive)"  'bash -ic "echo \$HISTFILE" 2>/dev/null | grep -q "^/commandhistory/.bash_history$"'
t "NODE_OPTIONS heap sized from RAM"                 'case "$NODE_OPTIONS" in *max-old-space-size=*) exit 0;; *) exit 1;; esac'
t "AGENTBOX_TIER exported"                           'test -n "$AGENTBOX_TIER"'

section "CLI tools on PATH"
for c in git tmux jq rsync sqlite3 node python3; do
  t "$c" "command -v $c"
done
for c in rg fd bat eza fzf zoxide delta gh direnv nvim btop; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else skp "$c (not installed: --lean or small tier)"; fi
done
t "node runs"            'command_matches v node --version'
t "python3 runs"         'command_matches 42 python3 -c "print(6*7)"'

section "agents"
t "claude binary executes"   'command_matches "claude" claude --version'
t "codex binary executes"    'command_matches "codex" codex --version'
t "claude --help parses"     'claude --help >/dev/null 2>&1'
t "node >=22.19.0 for the agent user (pi needs it)" 'version=$(node -v) && node_version_supported "$version"'
t "opencode binary executes" 'command_matches "[0-9]" opencode --version'
t "pi binary executes"       'command_matches "[0-9]" pi --version'
[ -s ~/.claude/.credentials.json ]         && note "claude: signed in"   || note "claude: not signed in (run 'claude' once)"
[ -s ~/.codex/auth.json ]                  && note "codex: signed in"    || note "codex: not signed in (run 'codex login' once)"
[ -s ~/.local/share/opencode/auth.json ]   && note "opencode: signed in" || note "opencode: not signed in (run 'opencode auth login' once)"
[ -s ~/.pi/agent/auth.json ]               && note "pi: signed in"       || note "pi: not signed in (run 'pi' then /login once)"

section "agent configs"
t "~/.claude/CLAUDE.md exists"                       'test -s ~/.claude/CLAUDE.md'
t "~/.codex/AGENTS.md symlinks to CLAUDE.md"         'test "$(readlink ~/.codex/AGENTS.md)" = "$HOME/.claude/CLAUDE.md"'
t "opencode and pi AGENTS.md symlink to CLAUDE.md"   'test "$(readlink ~/.config/opencode/AGENTS.md)" = "$HOME/.claude/CLAUDE.md" && test "$(readlink ~/.pi/agent/AGENTS.md)" = "$HOME/.claude/CLAUDE.md"'
t "settings.json is valid JSON"                      'jq -e . ~/.claude/settings.json'
t "settings.json denies .env reads"                  'jq -e "any(.permissions.deny[]?; test(\"\\\\.env\"))" ~/.claude/settings.json'
t "codex config.toml exists"                         'test -s ~/.codex/config.toml'
t "git: configured pager"                           'check_pager'
t "git: pull.rebase true"                            'test "$(git config --global pull.rebase)" = true'
t "git: push.autoSetupRemote true"                   'test "$(git config --global push.autoSetupRemote)" = true'

section "interactive aliases (fresh bash -i)"
for a in yolo cc cr tm tl tk gwt cx cx-yolo oc oc-run pi-p; do
  t "alias: $a"  "check_alias $a"
done

section "helpers, exercised"
if create_session; then ok "tmux can create a session"; else bad "tmux can create a session"; fi
t "new-project scaffolds a git repo"                 'new-project project "$verify_tmp" >/dev/null && test -d "$project_dir/.git" && test -L "$project_dir/AGENTS.md" && test -f "$project_dir/CLAUDE.md" && test -f "$project_dir/.gitignore"'
t "new-project made an initial commit"               'test "$(git -C "$project_dir" rev-list --count HEAD)" -ge 1'
if check_listener; then ok "killport kills a listener"; else bad "killport kills a listener"; fi
t "sysinfo runs"                                     'sysinfo | grep -q host'
t "agent-status runs"                                'agent-status | grep -q agents'
t "work helper installed"                            'command -v work'
t "vm-ssh and vm-share installed"                    'command -v vm-ssh && command -v vm-share'
t "root shim: claude tells root what to do"          'sudo -n /usr/local/bin/claude 2>&1 | grep -q "work"'

section "tailcat"
if command -v tailcat >/dev/null 2>&1; then
  t "tailcat runs"                                   'command_matches . tailcat version'
  t "persistent default key exists"                  'test -s ~/.config/tailcat/keys/default.private.json'
else skp "tailcat (--no-tailcat)"; fi

section "root-side wiring (via sudo)"
t "root bashrc has become alias"                     'sudo -n grep -q "alias become" /root/.bashrc'
t "helpers in /usr/local/bin"                        'for h in work agent-status agentbox-verify new-project killport sysinfo; do test -x /usr/local/bin/$h || exit 1; done'

printf '\n\033[1m%s\033[0m\n' "----------------------------------------"
printf '\033[1m%s passed, %s failed, %s skipped\033[0m\n' "$pass" "$fail" "$skip"
test "$fail" -eq 0
EOF
chmod 0755 /usr/local/bin/agentbox-verify
ok "agentbox-verify"

# =============================================================================
hdr "10/10 Login experience"
# =============================================================================
# SSH/console lands on root; show how to get to the agent user without forcing it.
cat > /etc/motd <<EOF

  agentbox ready.   user=$AGENT_USER   workspace=$WORKSPACE
    work            tmux session as $AGENT_USER in $WORKSPACE   (from root or agent)
    become          switch root -> $AGENT_USER
    yolo | auto | plan | safe     Claude Code permission modes (non-root only)
    cx | cx-yolo    Codex CLI
    oc | pi         OpenCode, pi   (headless: oc-run "..." / pi-p "...")
    vm-ssh          SSH into this VM from anywhere via tailcat (prints address)
    vm-share PORTS  expose local ports via tailcat  (laptop: tailcat forward <addr> 18080:8080)
    agent-status    versions, auth, tmux, ports
    agentbox-verify acceptance checks for this box

EOF
ok "/etc/motd (printed by interactive shells outside tmux)"

# =============================================================================
required_installations_ready || exit 1
printf '\n%s============================================================%s\n' "$c_green" "$c_off"
echo "  Done. Next:"
echo "    work            # opens tmux as $AGENT_USER in $WORKSPACE"
echo "    yolo            # inside: claude --dangerously-skip-permissions"
echo "    agent-status    # verify"
[[ $COPY_AUTH -eq 1 ]] || echo "  Auth: run 'claude' and 'codex login' once as $AGENT_USER."
printf '%s============================================================%s\n' "$c_green" "$c_off"
