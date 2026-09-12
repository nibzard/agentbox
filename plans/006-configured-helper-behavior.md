# Plan 006: Honor custom user/workspace settings and make work attach or create

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- agentbox.sh tests/test_helpers.py tests/support.py` and `git diff -- agentbox.sh tests/test_helpers.py tests/support.py`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P2
- **Effort:** M (S: hours; M: about a day; includes tests)
- **Risk:** MED
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** plan 001, plan 002
- **Category:** bug
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

The README advertises AGENT_USER=dev WORKSPACE=/src. Several generated consumers still hardcode agent or /workspace, and WORKSPACE is not persisted for child processes. Separately work's non-root exec tmux attach replaces the shell before its fallback can run. Fix configuration propagation and argument handling together so default and customized helper workflows behave consistently.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:342`

```bash
alias w='cd /workspace'; alias p='cd ~/projects'
mkcd() { mkdir -p "$1" && cd "$1"; }
```

`agentbox.sh:377`

```bash
if [ "$EUID" -eq 0 ] && id agent >/dev/null 2>&1; then
  alias become='cd / && exec su - agent'    # root -> agent user
fi
```

`agentbox.sh:732`

```bash
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
```

`agentbox.sh:874`

```bash
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
```

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_helpers.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- agentbox.sh (configuration persistence, relevant aliases and helper generators)
- tests/test_helpers.py (create)
- tests/support.py (only fixture support required here)
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/configured-helper-behavior`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Persist and serialize the configured identity

Generate one non-secret /etc/agentbox.conf with POSIX-safe quoted AGENT_USER and WORKSPACE and load/export them from shared profile defaults. Helpers must load it themselves so direct non-login invocations work. Require a supported non-root username, an absolute non-root workspace, and reject invalid values before user/sudoers/filesystem mutations; support spaces and quotes in legitimate workspace paths. Keep AGENT_HOME resolved via getent. Generate or runtime-expand w and become from this configuration, and pass the explicit workspace to verifier scaffolding. Do not store API keys or tailcat addresses in this file.

**Verify:** `python3 -m unittest discover -s tests -p 'test_helpers.py' -v` → Default/dev identity and /workspace,/src,space-containing path cases pass; invalid config is rejected before mutation stubs run.

### Step 2: Preserve arguments across root-to-agent transitions

Remove literal agent from become/vm-ssh/vm-share. Avoid embedding $* or session/path values directly into su -c shell text. Use safely quoted positional arguments or printf %q for the known Bash child, preserving empty arguments and whitespace. Match root shim policy and the configured user's login environment. Apply this convention to work and verifier re-exec, and ensure settings survive fresh login and direct helper execution. Do not change passwordless sudo or SSH authentication defaults.

**Verify:** `python3 -m unittest discover -s tests -p 'test_helpers.py' -v` → Root redirection targets only configured dev/agent; argv survives spaces/quotes/metacharacters without evaluation.

### Step 3: Use one attach-or-create operation

Retain the new infocmp/TERM fallback. Make work use tmux new-session -A -s with a quoted session and the configured workspace (or equivalent checked attach/create without the first exec). Root should re-enter the same helper as the configured user so behavior does not diverge. Report an inaccessible configured workspace instead of silently working in an unintended directory. Verify existing and absent sessions, root and non-root, known and unknown TERM values. An argv-recording stub tests dispatch locally; plan 011 performs real tmux checks.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_helpers.py' -v && git diff --check` → Exit 0; both session states execute attach-or-create with intact session/workspace and correct TERM.

## Test plan

Create/extend `tests/test_helpers.py` using unittest and tests/support.py as described above. Cover:

- Fresh login and direct invocation with default and custom identity/workspace.
- w, become, vm-ssh, vm-share, work, verifier and new-project select the same workspace/user.
- Workspace with spaces/quotes; session argument containing whitespace; shell metacharacters treated as data.
- Existing/missing session; known/missing terminfo; inaccessible workspace yields a clear nonzero status.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_helpers.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- Supporting an existing account requires changing its UID, primary group or login shell; report instead.
- The implementation would change remote authentication or sudo privileges.

## Maintenance notes

Plan 009 adds ephemeral argument translation after this quoting fix. Plan 010 uses the same config in status reporting. Avoid duplicate baked-in defaults drifting across helpers.
