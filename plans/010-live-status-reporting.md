# Plan 010: Query status at runtime in the correct user context

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- agentbox.sh tests/test_status.py tests/support.py` and `git diff -- agentbox.sh tests/test_status.py tests/support.py`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P2
- **Effort:** S (S: hours; M: about a day; includes tests)
- **Risk:** LOW
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** plan 001, plan 006
- **Category:** bug
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

The tailcat version/key-list expressions in the interpolated agent-status heredoc still run during installation, freezing those values in the generated file. Commit 5db381b intentionally changed agent version execution to the configured agent's login environment so pi finds its local Node; preserve that correction. Make status work for both root and the configured agent without unnecessary password-authenticated su calls, and keep private key/address material out of output.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:774`

```bash
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
```

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_status.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- agentbox.sh (agent-status generator only)
- tests/test_status.py (create)
- tests/support.py (only fixture support required here)
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/live-status-reporting`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Defer all status queries to helper execution

Use a quoted status heredoc and load the non-secret configuration from plan 006, or carefully escape every runtime substitution. Do not run tailcat version/genkey --list while rendering the helper. Preserve the agent-version fix: root queries through the configured user's login shell, while a caller already running as that user invokes its own binaries directly with the correct PATH. Do not use su for the same non-root user or attempt password prompts; unsupported other callers receive a clear unavailable indication. Capture command exit status before truncating display output.

**Verify:** `python3 -m unittest discover -s tests -p 'test_status.py' -v` → Rendering invokes zero live status commands; root selects agent environment; agent caller makes zero su calls; command failures display unavailable.

### Step 2: Verify fresh data and bounded diagnostics

Render once, then change mocked tailcat version and saved key names between two invocations; the output must change without reinstalling. Report key names/counts only. Verify all four agent version rows use agent-local tools, never root's distro Node for pi. Preserve distinction between auth-file presence and verified authentication: do not call file existence proof of a valid session. Keep status informational; do not perform login, mutation, or live network health checks.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_status.py' -v && git diff --check` → Exit 0; dynamic values update, missing tools are legible, and root/agent invocations complete without passwords.

## Test plan

Create/extend `tests/test_status.py` using unittest and tests/support.py as described above. Cover:

- One render/two runtime states with different version and saved key names.
- Root caller uses configured agent environment; agent caller needs no su; unsupported caller handled.
- Missing binary, nonzero version output, empty output and absent auth file.
- No private key contents or full tailcat addresses in fixtures/output.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_status.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- The implementation would undo 5db381b by executing pi with root's Node.
- Upstream key listing exposes credentials instead of names; report and reduce the displayed data.

## Maintenance notes

Keep render-time configuration separate from runtime discovery. This plan includes the caller-context edge of the latest status change to avoid introducing a password prompt in the advertised non-root workflow.
