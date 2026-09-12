# Plan 009: Implement the documented ephemeral vm-share option

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- agentbox.sh tests/test_sharing.py tests/support.py README.md` and `git diff -- agentbox.sh tests/test_sharing.py tests/support.py README.md`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P2
- **Effort:** S (S: hours; M: about a day; includes tests)
- **Risk:** LOW
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** plan 001, plan 006
- **Category:** bug
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

README documents vm-share --ephemeral 3000 but the helper forwards that flag unchanged to tailcat. Tailcat uses --key=new for ephemeral servers; the sibling vm-ssh already translates the public option. Add the same behavior to port sharing while retaining the configured user and safe argument handling from plan 006.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:739`

```bash
set -e
[ "$(id -u)" -eq 0 ] && exec su - agent -c "vm-ssh $*"
key=(); [ "${1:-}" = "--ephemeral" ] && { key=(--key=new); shift; }
if [ -n "${TAILCAT_SSH_KEYS:-}" ]; then
  exec tailcat serve "${key[@]}" --ssh-authorized-keys="$TAILCAT_SSH_KEYS" ssh "$@"
else
  echo "! TAILCAT_SSH_KEYS unset -> no-auth-ssh. Anyone with the address gets a shell as $(id -un)." >&2
  exec tailcat serve "${key[@]}" no-auth-ssh "$@"
fi
```

`agentbox.sh:750`

```bash
cat > /usr/local/bin/vm-share <<'EOF'
#!/usr/bin/env bash
# vm-share <port>[,<port>...] | all   — expose local TCP ports over tailcat.
# On your laptop:  tailcat forward <address> 18080:8080   (then open localhost:18080)
#             or:  tailcat browse <address>               (single web port)
set -e
[ "$(id -u)" -eq 0 ] && exec su - agent -c "vm-share $*"
[ -n "${1:-}" ] || { echo "usage: vm-share 3000,8080 | all"; exit 2; }
exec tailcat serve "$@"
```

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_sharing.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- agentbox.sh (vm-share generator and help text only)
- tests/test_sharing.py (create)
- tests/support.py (only fixture support required here)
- README.md (remote-access examples only if clarification is needed)
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/ephemeral-port-sharing`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Translate the public option before forwarding

Parse a leading --ephemeral into a Bash array containing --key=new, shift it once, then require at least one remaining port/service argument. Preserve remaining arguments exactly with "$@". Keep default saved-key behavior when the option is absent, and let ordinary tailcat flags pass through. Reject ambiguous combinations of --ephemeral with an explicit --key rather than accidentally exposing a persistent address. Preserve root redirection to the configured user from plan 006.

**Verify:** `python3 -m unittest discover -s tests -p 'test_sharing.py' -v` → Ephemeral maps to serve --key=new plus intact arguments; default mode adds no key option; missing/conflicting arguments fail.

### Step 2: Check both user contexts without exposing a tunnel

Use argv-recording stubs for tailcat and root redirection to test vm-share and compare the expected --ephemeral behavior with vm-ssh. Test ports 3000,8080 and all, explicit --key without --ephemeral, and a missing operand. Keep the README example runnable. Do not start a live remote service or print real tailcat addresses in tests.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_sharing.py' -v && git diff --check` → Exit 0; root and agent dispatch yield identical final tailcat argv.

## Test plan

Create/extend `tests/test_sharing.py` using unittest and tests/support.py as described above. Cover:

- Default 3000, comma-separated ports, all, leading --ephemeral.
- --ephemeral without ports, explicit conflicting key, ordinary explicit key.
- Root-to-custom-user argument preservation; no network calls.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_sharing.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- Upstream tailcat no longer accepts --key=new; verify its official help before adapting.
- A proposed fix changes SSH auth policy or saved key contents.

## Maintenance notes

Primary reference: https://github.com/tailscale/tailcat#key-management. Keep vm-ssh and vm-share public option semantics aligned without rotating or deleting keys.
