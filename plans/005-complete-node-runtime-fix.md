# Plan 005: Enforce the complete pi Node requirement and validate runtime installation

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- agentbox.sh tests/test_node_runtime.py tests/support.py README.md` and `git diff -- agentbox.sh tests/test_node_runtime.py tests/support.py README.md`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P1
- **Effort:** M (S: hours; M: about a day; includes tests)
- **Risk:** MED
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** plan 001, plan 004
- **Category:** bug
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

The original missing-Node finding is partially addressed at 338f977: the script installs a checksum-verified current Node LTS under the agent's ~/.local when the distro major is too old. Do not replace or remove that solution. The remaining check accepts every Node 22 release, including 22.0 through 22.18, although the recorded pi requirement is >=22.19.0. The verifier repeats that incomplete check; failed Node lookup/install handling also needs the required-install outcome introduced by plan 004.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:624`

```bash
# pi needs Node >= 22.19 and Debian ships 20. Give $AGENT_USER the current Node
# LTS from the official tarball (checksum verified) under ~/.local, ahead of
# the system node on PATH. Root and apt keep the distro node.
NODE_MAJOR=$(as_agent 'node -v 2>/dev/null' | sed -E 's/^v([0-9]+).*/\1/')
if (( ${NODE_MAJOR:-0} >= 22 )); then
  ok "node $(as_agent 'node -v') for $AGENT_USER"
else
  NODE_ARCH=$(uname -m); case "$NODE_ARCH" in x86_64) NODE_ARCH=x64;; aarch64) NODE_ARCH=arm64;; esac
  NODE_VER=$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version')
  if [[ -n $NODE_VER ]] && as_agent "set -e; t=\$(mktemp -d); cd \"\$t\"
      curl -fsSL -o node.tar.xz https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-linux-$NODE_ARCH.tar.xz
      curl -fsSL https://nodejs.org/dist/$NODE_VER/SHASUMS256.txt | grep \" node-$NODE_VER-linux-$NODE_ARCH.tar.xz\$\" | sed 's# .*# node.tar.xz#' | sha256sum -c --quiet -
      mkdir -p ~/.local && tar -xJf node.tar.xz -C ~/.local --strip-components=1 --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE'
      cd / && rm -rf \"\$t\"" >/dev/null 2>&1; then
    ok "node $NODE_VER (LTS) installed for $AGENT_USER in ~/.local"
  else
    warn "node LTS install for $AGENT_USER failed; pi needs node >= 22"
  fi
```

`agentbox.sh:929`

```bash
section "agents"
t "claude binary executes"   'claude --version 2>/dev/null | grep -qi claude'
t "codex binary executes"    'codex --version 2>/dev/null | grep -qi codex'
t "claude --help parses"     'claude --help >/dev/null 2>&1'
t "node >= 22 for the agent user (pi needs it)"  'test "$(node -v | sed -E "s/^v([0-9]+).*/\1/")" -ge 22'
t "opencode binary executes" 'opencode --version 2>/dev/null | grep -qE "[0-9]"'
t "pi binary executes"       'pi --version 2>/dev/null | grep -qE "[0-9]"'
```

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_node_runtime.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- agentbox.sh (Node runtime helper/install block and Node verifier assertion)
- tests/test_node_runtime.py (create)
- tests/support.py (only fixture support required here)
- README.md (Node requirement wording only)
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/complete-node-runtime-fix`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Use a complete numeric version comparison

Implement a small pure Bash version predicate for stable vMAJOR.MINOR.PATCH output; reject malformed/empty output and command failure. Compare against 22.19.0 using numeric components, not lexicographic text or only the major. Use the same definition in installation and generated verification (render the function/minimum into the verifier or generate both from one definition). Verify the published pi engine requirement before implementation; if its current minimum differs, stop to refresh this plan rather than guess. Keep npm installs unpinned as current behavior; arbitrary runtime/version pinning is outside scope.

**Verify:** `python3 -m unittest discover -s tests -p 'test_node_runtime.py' -v` → 20.x, 22.0.0 and 22.18.9 fail; 22.19.0, 22.19.1 and 24.0.0 pass; malformed output fails.

### Step 2: Harden the existing user-local LTS installation

Check node -v and the Node index lookup explicitly so set -e cannot bypass diagnostics. Select a valid stable LTS satisfying the minimum; reject null, empty, malformed JSON/version and unsupported architecture before constructing URLs. Preserve official nodejs.org downloads and SHA256 checks. Download and validate in an owned temporary directory with guaranteed cleanup; inspect the extracted Node version before copying it into ~/.local. Never modify /usr/bin/node or apt's runtime, and do not delete unrelated ~/.local content. Feed any required runtime failure into plan 004's failure outcome and skip pi installation if its runtime is unusable.

**Verify:** `python3 -m unittest discover -s tests -p 'test_node_runtime.py' -v` → Both supported architecture mappings, index failures, checksum failures and staged-version failures are covered; no failed validation promotes runtime files.

### Step 3: Keep installed paths and documentation consistent

Assert a fresh agent login selects the user-local Node and npm while root continues using distro Node; use a stubbed login PATH locally and the live matrix in plan 011. Update README's generic Node 22 claim to the exact supported minimum. On reruns with a compatible runtime, make zero download calls. Preserve the npm CA profile from c7539ac and pi --ignore-scripts.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_node_runtime.py' -v && git diff --check` → Exit 0; healthy rerun skips downloads; agent/root PATH selection and precise minimum cases pass.

## Test plan

Create/extend `tests/test_node_runtime.py` using unittest and tests/support.py as described above. Cover:

- Version boundary table: 18/20, 22.0.0, 22.18.9, 22.19.0, 22.19.1, 24.0.0, invalid/empty.
- Node query failure, index HTTP/JSON failure, no eligible LTS, unsupported arch.
- Missing/wrong checksum and archive extraction error leave no promoted bad runtime or temp files.
- Healthy existing runtime skips download; new agent PATH chooses local runtime without altering root.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_node_runtime.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- The latest pi engines.node requirement differs from >=22.19.0; refresh evidence and scope before implementing.
- Runtime installation would overwrite unrelated user-local executables or require modifying the distro Node.

## Maintenance notes

Primary references: https://registry.npmjs.org/@earendil-works/pi-coding-agent/latest and https://nodejs.org/dist/index.json. Reconcile changing upstream requirements explicitly. The stock-runtime issue is superseded by this narrower completion plan.
