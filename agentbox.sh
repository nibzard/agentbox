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
#  workspace for Claude Code + Codex CLI:
#    • fixes the usual container quirks (/proc, CA certs, PATH persistence)
#    • installs a lean modern CLI toolset (rg, fd, bat, eza, fzf, zoxide,
#      delta, gh, jq, tmux, git, vim, htop, node, python3 …)
#    • creates a non-root `agent` user with passwordless sudo, because
#      `claude --dangerously-skip-permissions` refuses to run as root
#    • installs Claude Code + Codex for that user (native installers, no npm)
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

[[ $EUID -eq 0 ]] || die "run as root"
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
EGRESS_CA=""
for cand in "${NODE_EXTRA_CA_CERTS:-}" "${SSL_CERT_FILE:-}" /run/steel/egress-ca.crt; do
  [[ -n "$cand" && -s "$cand" ]] && { EGRESS_CA="$cand"; break; }
done
if [[ -n "$EGRESS_CA" ]]; then
  install -m 0644 "$EGRESS_CA" /usr/local/share/ca-certificates/sandbox-egress-ca.crt
  update-ca-certificates >/dev/null 2>&1 || true
  {
    echo "# Egress CA env captured by agentbox.sh from the provisioning shell"
    env | grep -E '^(.*_CA_BUNDLE|.*CAINFO|.*CA_CERTS.*|.*CAFILE|.*CACERTS.*|.*_CERT|SSL_CERT_FILE|PIP_CERT|CONDA_SSL_VERIFY|DENO_TLS_CA_STORE|UV_NATIVE_TLS|.*_SSL_CA_FILE)=' \
      | sort | sed 's/^/export /; s/=\(.*\)$/="\1"/'
  } > /etc/profile.d/00-agentbox-egress-ca.sh
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
alias w='cd /workspace'; alias p='cd ~/projects'
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
if [ "$EUID" -eq 0 ] && id agent >/dev/null 2>&1; then
  alias become='cd / && exec su - agent'    # root -> agent user
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
mkdir -p "$AGENT_HOME/.claude" "$AGENT_HOME/.codex" "$AGENT_HOME/.agentbox"

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
# Codex reads AGENTS.md; keep one source of truth.
ln -sfn "$AGENT_HOME/.claude/CLAUDE.md" "$AGENT_HOME/.codex/AGENTS.md"

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
chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_HOME/.claude" "$AGENT_HOME/.codex" "$AGENT_HOME/.agentbox"
ok "CLAUDE.md, AGENTS.md (symlink), settings.json, codex config.toml"

# =============================================================================
hdr "7/10  Install Claude Code + Codex for $AGENT_USER"
# =============================================================================
if as_agent 'test -x "$HOME/.local/bin/claude"'; then
  ok "claude already installed: $(as_agent '"$HOME/.local/bin/claude" --version 2>/dev/null | head -1')"
else
  as_agent 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null 2>&1 \
    && ok "claude installed: $(as_agent '"$HOME/.local/bin/claude" --version 2>/dev/null | head -1')" \
    || warn "Claude Code install failed (check network)"
fi
if as_agent 'test -x "$HOME/.local/bin/codex"'; then
  ok "codex already installed: $(as_agent '"$HOME/.local/bin/codex" --version 2>/dev/null | head -1')"
else
  as_agent 'curl -fsSL https://chatgpt.com/codex/install.sh | sh' >/dev/null 2>&1 \
    && ok "codex installed: $(as_agent '"$HOME/.local/bin/codex" --version 2>/dev/null | head -1')" \
    || warn "Codex install failed (check network)"
fi
if [[ $WITH_DEV -eq 1 ]]; then
  as_agent 'command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh' >/dev/null 2>&1 \
    && ok "uv installed" || warn "uv install failed"
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
    TAILCAT_VERSION=$(curl -fsSL https://api.github.com/repos/tailscale/tailcat/releases/latest 2>/dev/null \
                      | jq -r '.tag_name // empty' | sed 's/^v//')
    [[ -n $TAILCAT_VERSION ]] || { TAILCAT_VERSION=0.6.0; warn "GitHub API unreachable, pinning tailcat $TAILCAT_VERSION"; }
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
[ "$(id -u)" -eq 0 ] && exec su - agent -c "vm-ssh $*"
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
[ "$(id -u)" -eq 0 ] && exec su - agent -c "vm-share $*"
[ -n "${1:-}" ] || { echo "usage: vm-share 3000,8080 | all"; exit 2; }
exec tailcat serve "$@"
EOF
chmod 0755 /usr/local/bin/vm-ssh /usr/local/bin/vm-share
ok "vm-ssh, vm-share"

cat > /usr/local/bin/work <<EOF
#!/usr/bin/env bash
# work [session] — attach-or-create a tmux session in $WORKSPACE (as $AGENT_USER)
s="\${1:-work}"
# tmux exits with "missing or unsuitable terminal" when the box has no terminfo for \$TERM.
infocmp "\${TERM:-dumb}" >/dev/null 2>&1 || export TERM=xterm-256color
if [ "\$(id -u)" -eq 0 ]; then exec su - $AGENT_USER -c "cd $WORKSPACE && (tmux attach -t \$s 2>/dev/null || tmux new -s \$s)"; fi
cd $WORKSPACE 2>/dev/null || cd ~
exec tmux attach -t "\$s" 2>/dev/null || exec tmux new -s "\$s"
EOF

cat > /usr/local/bin/agent-status <<EOF
#!/usr/bin/env bash
# agent-status — one-screen view of the box and the agents
b() { printf '\e[1;34m%s\e[0m\n' "\$*"; }
b "host";    echo "  \$(hostname)  \$(. /etc/os-release; echo \$PRETTY_NAME)  \$(uname -r)"
b "load";    echo "  cpu=\$(nproc) load=\$(cut -d' ' -f1-3 /proc/loadavg) mem=\$(free -m | awk '/Mem/{print \$3"/"\$2" MB"}') disk=\$(df -h / | awk 'NR==2{print \$3"/"\$2}')"
b "agents";
for u in root $AGENT_USER; do
  h=\$(getent passwd \$u | cut -d: -f6)
  c=\$(\$h/.local/bin/claude --version 2>/dev/null | head -1 || echo "-")
  x=\$(\$h/.local/bin/codex --version 2>/dev/null | head -1 || echo "-")
  auth=\$([ -s \$h/.claude/.credentials.json ] && echo "claude:auth✔" || echo "claude:no-auth")
  cauth=\$([ -s \$h/.codex/auth.json ] && echo "codex:auth✔" || echo "codex:no-auth")
  printf '  %-6s claude=%-28s codex=%-22s %s %s\n' "\$u" "\$c" "\$x" "\$auth" "\$cauth"
done
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
name="${1:?usage: new-project <name> [parent-dir]}"; parent="${2:-${WORKSPACE:-/workspace}}"
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
for bin in claude codex; do
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
ok "root shims for claude, codex"

# agentbox-verify: the acceptance checks for this box. Runs as $AGENT_USER (root
# is redirected) and exits non-zero on any failure. Values that depend on the
# install go in the first block; the checks themselves are a quoted heredoc.
cat > /usr/local/bin/agentbox-verify <<EOF
#!/usr/bin/env bash
# ABOUTME: Acceptance checks for a box set up by agentbox.sh: system, user, tools, agents, configs, helpers.
# ABOUTME: Run as the agent user (root is redirected). Exits non-zero when any check fails.
AGENT_USER=$AGENT_USER
WORKSPACE=$WORKSPACE
EOF
cat >> /usr/local/bin/agentbox-verify <<'EOF'
# A fresh exec session can have a stale /proc (see /etc/profile.d/10-agentbox.sh).
[ -e /proc/self/mounts ] || mount -t proc proc /proc 2>/dev/null || sudo -n mount -t proc proc /proc 2>/dev/null
[ "$(id -u)" -eq 0 ] && exec su - "$AGENT_USER" -c "agentbox-verify $*"
pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skp()  { printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip+1)); }
note() { printf '  \033[34mINFO\033[0m %s\n' "$1"; }
# t <label> <shell snippet>: PASS when the snippet exits 0. Runs in a subshell so
# an `exit` inside the snippet cannot end the suite.
t() { if (eval "$2") >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n\033[1;34m== %s ==\033[0m\n' "$1"; }
cleanup() { tmux kill-session -t abverify 2>/dev/null; rm -rf "$WORKSPACE/ab-verify-selftest"; }
trap cleanup EXIT

section "system"
t "/proc works (bun requirement)"                    'test -r /proc/self/cmdline'
if grep -q '^/swapfile' /proc/swaps; then
  t "swapfile active"                                'awk "/SwapTotal/{exit (\$2+0)>0?0:1}" /proc/meminfo'
else skp "swap (not configured on this tier)"; fi
t "HTTPS egress with trusted CA"                     'curl -fsS -o /dev/null -w "%{http_code}" https://api.github.com/zen | grep -q 200'
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
t "node runs"            'node --version | grep -q v'
t "python3 runs"         'python3 -c "print(6*7)" | grep -q 42'

section "agents"
t "claude binary executes"   'claude --version 2>/dev/null | grep -qi claude'
t "codex binary executes"    'codex --version 2>/dev/null | grep -qi codex'
t "claude --help parses"     'claude --help >/dev/null 2>&1'
[ -s ~/.claude/.credentials.json ] && note "claude: signed in" || note "claude: not signed in (run 'claude' once)"
[ -s ~/.codex/auth.json ]          && note "codex: signed in"  || note "codex: not signed in (run 'codex login' once)"

section "agent configs"
t "~/.claude/CLAUDE.md exists"                       'test -s ~/.claude/CLAUDE.md'
t "~/.codex/AGENTS.md symlinks to CLAUDE.md"         'test "$(readlink ~/.codex/AGENTS.md)" = "$HOME/.claude/CLAUDE.md"'
t "settings.json is valid JSON"                      'jq -e . ~/.claude/settings.json'
t "settings.json denies .env reads"                  'jq -e "any(.permissions.deny[]?; test(\"\\\\.env\"))" ~/.claude/settings.json'
t "codex config.toml exists"                         'test -s ~/.codex/config.toml'
t "git: delta as pager"                              'test "$(git config --global core.pager)" = delta'
t "git: pull.rebase true"                            'test "$(git config --global pull.rebase)" = true'
t "git: push.autoSetupRemote true"                   'test "$(git config --global push.autoSetupRemote)" = true'

section "interactive aliases (fresh bash -i)"
for a in yolo cc cr tm tl tk gwt cx cx-yolo; do
  t "alias: $a"  "bash -ic 'type $a' 2>/dev/null | grep -q ."
done

section "helpers, exercised"
t "tmux can create a session"                        'tmux new -d -s abverify && tmux has -t abverify'
t "new-project scaffolds a git repo"                 'new-project ab-verify-selftest >/dev/null && d="$WORKSPACE/ab-verify-selftest" && test -d "$d/.git" && test -L "$d/AGENTS.md" && test -f "$d/CLAUDE.md" && test -f "$d/.gitignore"'
t "new-project made an initial commit"               'test "$(git -C "$WORKSPACE/ab-verify-selftest" rev-list --count HEAD)" -ge 1'
t "killport kills a listener"                        'setsid python3 -m http.server 18123 --bind 127.0.0.1 >/dev/null 2>&1 & sleep 1; ss -tln "sport = :18123" | grep -q 18123 && killport 18123 >/dev/null 2>&1; sleep 0.5; ! ss -tln "sport = :18123" | grep -q 18123'
t "sysinfo runs"                                     'sysinfo | grep -q host'
t "agent-status runs"                                'agent-status | grep -q agents'
t "work helper installed"                            'command -v work'
t "vm-ssh and vm-share installed"                    'command -v vm-ssh && command -v vm-share'
t "root shim: claude tells root what to do"          'sudo -n /usr/local/bin/claude 2>&1 | grep -q "work"'

section "tailcat"
if command -v tailcat >/dev/null 2>&1; then
  t "tailcat runs"                                   'tailcat version 2>/dev/null | grep -q .'
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
    vm-ssh          SSH into this VM from anywhere via tailcat (prints address)
    vm-share PORTS  expose local ports via tailcat  (laptop: tailcat forward <addr> 18080:8080)
    agent-status    versions, auth, tmux, ports
    agentbox-verify acceptance checks for this box

EOF
ok "/etc/motd (printed by interactive shells outside tmux)"

# =============================================================================
printf '\n%s============================================================%s\n' "$c_green" "$c_off"
echo "  Done. Next:"
echo "    work            # opens tmux as $AGENT_USER in $WORKSPACE"
echo "    yolo            # inside: claude --dangerously-skip-permissions"
echo "    agent-status    # verify"
[[ $COPY_AUTH -eq 1 ]] || echo "  Auth: run 'claude' and 'codex login' once as $AGENT_USER."
printf '%s============================================================%s\n' "$c_green" "$c_off"
