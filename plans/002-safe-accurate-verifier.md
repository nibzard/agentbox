# Plan 002: Make acceptance checks safe and trustworthy

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- agentbox.sh tests/test_verifier.py tests/support.py` and `git diff -- agentbox.sh tests/test_verifier.py tests/support.py`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P1
- **Effort:** M (S: hours; M: about a day; includes tests)
- **Risk:** MED
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** plan 001
- **Category:** tests
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

agentbox-verify deletes fixed-name resources whether or not it created them. Its listener check can pass when the listener never started, lean installs fail a hardcoded delta assertion, and the new login banner lets missing aliases pass. Correct these together so subsequent live checks cannot destroy unrelated resources and their results mean what they claim.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:885`

```bash
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
```

`agentbox.sh:948`

```bash
t "git: delta as pager"                              'test "$(git config --global core.pager)" = delta'
t "git: pull.rebase true"                            'test "$(git config --global pull.rebase)" = true'
t "git: push.autoSetupRemote true"                   'test "$(git config --global push.autoSetupRemote)" = true'

section "interactive aliases (fresh bash -i)"
for a in yolo cc cr tm tl tk gwt cx cx-yolo oc oc-run pi-p; do
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
```

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_verifier.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- agentbox.sh (agentbox-verify generator only)
- tests/test_verifier.py (create)
- tests/support.py (only fixture support required here)
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/safe-accurate-verifier`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Isolate resources owned by the verifier

Create a unique temporary root below the configured WORKSPACE with mktemp -d, initialize ownership variables before installing EXIT/INT/TERM cleanup, and use a unique tmux session name. Create the scaffold as a child of that temporary root by explicitly passing its parent to new-project. Keep project directory and listener PID in the parent shell, not inside t() subshells. Cleanup may remove only that invocation's temporary root, recorded child process and successfully created tmux session; preserve the original exit code, including on signals. Never delete the old fixed-name paths or kill a session that failed to be created. Add fixtures with pre-existing ab-verify-selftest and abverify resources and verify they survive successful and failed runs.

**Verify:** `python3 -m unittest discover -s tests -p 'test_verifier.py' -v` → Resource ownership, failure and signal cleanup cases pass; sentinel resources are untouched.

### Step 2: Make listener testing assert startup and ownership

Start a Python listener on 127.0.0.1 port 0 and have the child publish its assigned port into the owned temporary root. Record its PID, poll readiness with a bounded deadline, and fail explicitly if startup fails or the process exits. Only invoke killport after ss identifies that recorded child on the assigned port; assert termination afterward. Ensure cleanup kills the owned child even if an assertion fails. Do not use fixed port 18123, kill arbitrary listeners, or mark an empty port as proof of a successful kill. Keep these checks as named functions so setup/cleanup state survives t() subshells.

**Verify:** `python3 -m unittest discover -s tests -p 'test_verifier.py' -v` → Failed-start and wrong-PID cases fail the check; successful-start/kill passes; unrelated listener survives.

### Step 3: Correct alias and profile expectations

Replace alias pipelines ending in grep -q . with checks of bash -ic type's exit status, suppressing output. Add a deliberately missing alias with a banner to prove the failure is detected. On a fresh generated config, expect delta if installed and less otherwise; later plan 007 permits user-selected pagers, so keep the assertion easy to update there. Ensure version execution tests fail on nonzero command status even when stdout includes digits. Keep explicit skips for optional tools and failures for required agents.

**Verify:** `python3 -m unittest discover -s tests -p 'test_verifier.py' -v` → Banner plus missing alias fails; present aliases pass; lean less/full delta cases pass; failed numeric version output fails.

## Test plan

Create/extend `tests/test_verifier.py` using unittest and tests/support.py as described above. Cover:

- Existing sentinel directory/session survives verification and interruption.
- Two fixture invocations allocate distinct resources and cannot clean each other.
- Listener fails to start, exits before readiness, wrong PID, successful start/kill.
- Missing alias with banner, existing alias, no banner, fresh lean and default config.
- Nonzero version command with numeric stdout is not a pass.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_verifier.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- Cleanup cannot establish ownership of a resource.
- A proposed test would send a signal to a process not started by its fixture.

## Maintenance notes

Run this before live E2E from later plans. Keep acquisition and cleanup in the same shell; t() evaluates in a subshell. Plan 007 updates Git assertions to allow intentional user overrides.
