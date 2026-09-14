#!/usr/bin/env bash
# Live Steel regression runner. Never deletes a caller-supplied computer.
# AGENTBOX_TEST_PRESERVATION=1 is restricted to newly created disposable VMs.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${STEEL_API_KEY:?export STEEL_API_KEY first}"
command -v steel >/dev/null || { echo 'steel CLI not found' >&2; exit 2; }
command -v jq >/dev/null || { echo 'jq is required before creating a computer' >&2; exit 2; }
AGENTBOX_AGENT_USER=${AGENTBOX_AGENT_USER:-agent}
AGENTBOX_WORKSPACE=${AGENTBOX_WORKSPACE:-/workspace}
PRESERVE=${AGENTBOX_TEST_PRESERVATION:-0}
[[ $PRESERVE == 0 || $PRESERVE == 1 ]] || { echo 'Invalid preservation setting' >&2; exit 2; }
[[ $PRESERVE != 1 || -z ${COMPUTER_ID:-} ]] || { echo 'Preservation requires a newly created computer' >&2; exit 2; }
flags=()
argument_text=${AGENTBOX_ARGS:-}
read -r -a flags <<< "${argument_text//$'\n'/ }"
for flag in ${flags[@]+"${flags[@]}"}; do
  case "$flag" in --lean|--with-dev|--no-copy-auth|--no-tailcat) ;; *) echo "Unsupported AGENTBOX_ARGS flag: $flag" >&2; exit 2;; esac
done
valid_id() { [[ $1 =~ ^cmp[_-][[:alnum:]]+$ ]]; }
CREATED=0
cleanup() {
  status=$?
  trap - EXIT
  if (( CREATED )) && [[ ${KEEP:-0} != 1 ]]; then
    echo "==> deleting $COMPUTER_ID"
    if ! steel computer delete "$COMPUTER_ID" >/dev/null; then
      echo 'Computer deletion failed' >&2
      (( status != 0 )) || status=1
    fi
  fi
  exit "$status"
}
if [[ -z ${COMPUTER_ID:-} ]]; then
  echo '==> creating a Steel computer'
  response=$(steel computer create --wait --timeout 1800 --json)
  COMPUTER_ID=$(jq -er '.data.id | select(type == "string")' <<< "$response")
  valid_id "$COMPUTER_ID" || { echo 'Invalid created computer ID; refusing provisioning or deletion' >&2; exit 2; }
  CREATED=1
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
else
  valid_id "$COMPUTER_ID" || { echo 'Invalid computer ID' >&2; exit 2; }
fi
echo "==> box: $COMPUTER_ID"
RUN_TOKEN="agentbox-e2e-$$-$RANDOM"
remote() {
  # Steel 0.5.0-preview.5 shell_join quotes each argv element itself.
  steel computer ssh "$COMPUTER_ID" -- env "AGENT_USER=$AGENTBOX_AGENT_USER" \
    "WORKSPACE=$AGENTBOX_WORKSPACE" "E2E_TOKEN=$RUN_TOKEN" "E2E_PRESERVE=$PRESERVE" "$@"
}
install() { remote bash -s -- ${flags[@]+"${flags[@]}"} < agentbox.sh; }
echo '==> first run'
install
if [[ $PRESERVE == 1 ]]; then
  echo '==> controlled preservation edits'
  remote bash -s -- preserve <<'REMOTE'
set -euo pipefail
. /etc/agentbox.conf
h=$(getent passwd "$AGENT_USER" | cut -d: -f6)
state=/tmp/$E2E_TOKEN
mkdir -m 700 "$state"
for home in /root "$h"; do
  for file in .inputrc .tmux.conf .vimrc .gitconfig; do
    printf '\n# agentbox preservation sentinel\n' >> "$home/$file"
  done
  git config --file "$home/.gitconfig" user.name 'E2E Fixture'
  git config --file "$home/.gitconfig" user.email 'fixture@example.invalid'
  git config --file "$home/.gitconfig" core.pager cat
  printf '\n# agentbox unmanaged bashrc sentinel\n' >> "$home/.bashrc"
done
printf '\nE2E custom instructions\n' >> "$h/.claude/CLAUDE.md"
# Files under test contain no credentials. Never hash or print auth files.
for home in /root "$h"; do
  sha256sum "$home"/{.inputrc,.tmux.conf,.vimrc,.gitconfig}
done > "$state/checksums"
sha256sum "$h/.claude/CLAUDE.md" >> "$state/checksums"
REMOTE
fi
echo '==> second run'
install
echo '==> behavior and preservation assertions'
remote bash -s -- assertions <<'REMOTE'
set -euo pipefail
expected_user=$AGENT_USER expected_workspace=$WORKSPACE
. /etc/agentbox.conf
[[ $AGENT_USER == "$expected_user" && $WORKSPACE == "$expected_workspace" ]]
h=$(getent passwd "$AGENT_USER" | cut -d: -f6)
state=/tmp/$E2E_TOKEN
if [[ $E2E_PRESERVE == 1 ]]; then
  sha256sum --check --status "$state/checksums"
  for home in /root "$h"; do
    grep -Fxq '# agentbox unmanaged bashrc sentinel' "$home/.bashrc"
    [[ $(git config --file "$home/.gitconfig" user.name) == 'E2E Fixture' ]]
    [[ $(git config --file "$home/.gitconfig" user.email) == fixture@example.invalid ]]
    [[ $(git config --file "$home/.gitconfig" core.pager) == cat ]]
  done
  rm -- "$state/checksums"; rmdir -- "$state"
fi
# Root keeps the distro runtime, independently of the agent's local runtime.
[[ $(readlink -f "$(command -v node)") == /usr/bin/node ]]
. /etc/os-release
printf 'target: %s; arch: %s; root Node: %s\n' "$PRETTY_NAME" "$(uname -m)" "$(node -v)"
printf -v command '%q ' bash -s
su - "$AGENT_USER" -c "$command" <<'AGENT'
set -euo pipefail
. /etc/agentbox.conf
h=$(getent passwd "$AGENT_USER" | cut -d: -f6)
[[ $HOME == "$h" ]]
node -e 'const [a,b,c]=process.versions.node.split(".").map(Number);if(!(a>22||a===22&&(b>19||b===19&&c>=0)))process.exit(1)'
printf 'agent Node: %s (%s)\n' "$(node -v)" "$(command -v node)"
for name in claude codex opencode pi; do
  output=$("$h/.local/bin/$name" --version)
  [[ -n $output ]]
  printf '%s: %s\n' "$name" "${output%%$'\n'*}"
done
curl -fsS --max-time 30 https://registry.npmjs.org/ --output /dev/null
npm ping --registry=https://registry.npmjs.org/ >/dev/null
AGENT
# A PTY exercises the actual work helper; detach clients, retain the owned
# session, then prove both callers attach to exactly the same pane on reruns.
python3 - "$AGENT_USER" "$WORKSPACE" "$E2E_TOKEN" <<'PY'
import fcntl, os, pty, select, shlex, signal, struct, subprocess, sys, termios, time
user, workspace, token = sys.argv[1:]
session = token

def agent(*args, check=True):
    return subprocess.run(['su','-',user,'-c',shlex.join(args)], check=check,
                          text=True, capture_output=True, timeout=15)

def attach(root):
    argv = ['/usr/local/bin/work',session] if root else ['su','-',user,'-c',shlex.join(['/usr/local/bin/work',session])]
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0,termios.TIOCSWINSZ,struct.pack('HHHH',24,100,0,0))
        os.environ['TERM']='xterm-256color'
        os.execvp(argv[0],argv)
    reaped=False
    try:
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            if select.select([fd],[],[],0.1)[0]:
                try: os.read(fd,65536)
                except OSError: raise RuntimeError('work exited before attaching')
            clients=agent('tmux','list-clients','-t',session,'-F','#{client_pid}',check=False)
            if clients.returncode==0 and clients.stdout.strip():
                agent('tmux','detach-client','-s',session)
                break
        else: raise RuntimeError('work did not attach before deadline')
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            done,status=os.waitpid(pid,os.WNOHANG)
            if done:
                reaped=True
                if os.waitstatus_to_exitcode(status)!=0: raise RuntimeError('work failed')
                return
            time.sleep(0.05)
        raise RuntimeError('work did not exit after detach')
    finally:
        if not reaped:
            try: os.kill(pid,signal.SIGKILL)
            except ProcessLookupError: pass
            try: os.waitpid(pid,0)
            except ChildProcessError: pass
        os.close(fd)

for creator_root in (True,False):
    session=token+('-root' if creator_root else '-agent')
    if agent('tmux','has-session','-t',session,check=False).returncode==0:
        raise RuntimeError('refusing to reuse an existing test session')
    try:
        identity=None
        for root in (creator_root,not creator_root,creator_root,not creator_root):
            attach(root)
            pane=agent('tmux','display-message','-p','-t',session,'#{session_id}:#{pane_id}:#{pane_current_path}').stdout.strip()
            if identity is None: identity=pane
            elif pane!=identity: raise RuntimeError('work recreated the session/pane')
            if not pane.endswith(':'+workspace): raise RuntimeError('work used wrong workspace')
    finally:
        agent('tmux','kill-session','-t',session,check=False)
PY
REMOTE
echo '==> agentbox-verify'
steel computer exec "$COMPUTER_ID" --timeout 300 -c 'agentbox-verify'
echo '==> e2e passed'
