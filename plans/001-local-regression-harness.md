# Plan 001: Establish a local regression harness for generated shell code

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- tests/support.py tests/test_harness.py README.md` and `git diff -- tests/support.py tests/test_harness.py README.md`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P1
- **Effort:** M (S: hours; M: about a day; includes tests)
- **Risk:** LOW
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** none
- **Category:** tests
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

The only existing test runner, tests/e2e.sh, provisions a real Steel computer, runs the installer twice, and invokes the generated agentbox-verify. There is no local test framework or CI configuration. Most defects are in generated shell programs or status handling and can be tested without root, networking, agent credentials, or a VM. Provide this baseline before changing those paths, while keeping the one-file distribution intact.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:83`

```bash
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

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_harness.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- tests/support.py (create)
- tests/test_harness.py (create)
- README.md (Tests section only)
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/local-regression-harness`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Build safe extraction and execution utilities

Create tests/support.py using only Python standard-library unittest/subprocess/tempfile/pathlib. Provide helpers to extract a uniquely identified heredoc or bounded source region using stable textual anchors, not line numbers. Require exactly one match and the expected terminator; ambiguous/missing anchors must raise an exception. Support both quoted and interpolated heredocs and concatenated verifier fragments. For interpolated bodies, render only the explicitly extracted heredoc in Bash with supplied synthetic configuration and explicit stubs for its command substitutions. Never source or execute agentbox.sh as a whole. Never silently replace shell runtime logic with Python equivalents. Each fixture owns a TemporaryDirectory and controls PATH, cwd, stdin and environment; use a copied environment dictionary to override HOME for the child only, never change the operator's HOME. Provide stub executables with argument logging, bounded subprocess timeouts and cleanup. Do not invoke su, sudo, mount, apt, installers, or the Steel CLI on the host.

**Verify:** `python3 -m unittest discover -s tests -p 'test_harness.py' -v` → Harness tests created with the utilities pass; missing and duplicate extraction anchors are explicitly tested.

### Step 2: Exercise actual generated shell bodies

Add tests for quoted vm-share extraction, interpolated work rendering with synthetic username/workspace, and concatenating the two verifier heredocs. Stub tailcat/su before rendering any status template: that source currently contains installation-time command substitutions. Run bash -n on the rendered shell fixtures. Test that changing a mocked command exit status or output changes the executed fixture result; do not count literal source-string assertions as behavioral coverage. Use an explicitly requested harmless region for any installer control-flow fixture; the harness must never offer a "source whole installer" shortcut.

**Verify:** `python3 -m unittest discover -s tests -p 'test_harness.py' -v` → All extraction, syntax, stub and negative-control cases pass without network or host provisioning.

### Step 3: Document the local entry point

Add the standard-library unittest discovery command to README Tests, distinguish local regressions from live Steel E2E, and list Bash/Python 3 prerequisites. Keep current live-test examples. Do not claim a live VM or distro matrix was tested in this step.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_*.py' -v && git diff --check` → Exit 0; all local tests pass and documentation matches the actual command.

## Test plan

Create/extend `tests/test_harness.py` using unittest and tests/support.py as described above. Cover:

- Unique, missing and ambiguous anchors; quoted/interpolated/concatenated heredocs.
- Generated work/vm-share/verifier shell syntax; fake command success and failure.
- Timeout and cleanup behavior; fixture writes remain inside its temporary directory.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_harness.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- A test requires executing the complete installer or touching host system paths.
- A generated substitution cannot be safely stubbed; isolate a smaller explicit region instead of executing it.

## Maintenance notes

Future fixes add tests/test_<topic>.py and reuse support.py. Keep fixtures derived from production source; copied implementations would hide regressions. No package manager install is needed for this harness.
