# Plan 004: Return failure when required agents are unavailable

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- agentbox.sh tests/test_installers.py tests/support.py` and `git diff -- agentbox.sh tests/test_installers.py tests/support.py`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P1
- **Effort:** M (S: hours; M: about a day; includes tests)
- **Risk:** MED
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** plan 001, plan 003
- **Category:** bug
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

as_agent invokes a separate login shell; the parent script's pipefail does not make curl|bash inside that shell reliable. Failed downloads can look successful, OpenCode can receive a dangling symlink, and all four required agents can fail while the script still prints Done. Existing executable checks also skip broken installs. Keep native installers and the user-local npm installation, but make success depend on executable health.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:93`

```bash
as_agent() { su - "$AGENT_USER" -c "$*"; }

[[ $EUID -eq 0 ]] || die "run as root"
```

`agentbox.sh:600`

```bash
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
# OpenCode's installer puts the binary in ~/.opencode/bin and edits rc files
# unless that dir is already on PATH. Keep PATH clean: pre-seed it, then link
# the binary into ~/.local/bin next to the other agents.
if as_agent 'test -x "$HOME/.local/bin/opencode"'; then
  ok "opencode already installed: $(as_agent '"$HOME/.local/bin/opencode" --version 2>/dev/null | head -1')"
else
  as_agent 'export PATH="$HOME/.opencode/bin:$PATH"; curl -fsSL https://opencode.ai/install | bash && ln -sfn "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"' >/dev/null 2>&1 \
    && ok "opencode installed: $(as_agent '"$HOME/.local/bin/opencode" --version 2>/dev/null | head -1')" \
    || warn "OpenCode install failed (check network)"
fi
```

`agentbox.sh:643`

```bash
# pi ships as an npm package. A user-level npm prefix puts its binary in
# ~/.local/bin and lets the agent install other globals without sudo.
if as_agent 'test -x "$HOME/.local/bin/pi"'; then
  ok "pi already installed: $(as_agent '"$HOME/.local/bin/pi" --version 2>/dev/null | head -1')"
else
  as_agent 'npm config set prefix "$HOME/.local" && npm install -g --ignore-scripts @earendil-works/pi-coding-agent' >/dev/null 2>&1 \
    && ok "pi installed: $(as_agent '"$HOME/.local/bin/pi" --version 2>/dev/null | head -1')" \
    || warn "pi install failed (check network)"
fi
if [[ $WITH_DEV -eq 1 ]]; then
  as_agent 'command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh' >/dev/null 2>&1 \
    && ok "uv installed" || warn "uv install failed"
fi
```

`agentbox.sh:1005`

```bash
# =============================================================================
printf '\n%s============================================================%s\n' "$c_green" "$c_off"
echo "  Done. Next:"
echo "    work            # opens tmux as $AGENT_USER in $WORKSPACE"
echo "    yolo            # inside: claude --dangerously-skip-permissions"
echo "    agent-status    # verify"
[[ $COPY_AUTH -eq 1 ]] || echo "  Auth: run 'claude' and 'codex login' once as $AGENT_USER."
printf '%s============================================================%s\n' "$c_green" "$c_off"
```

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_installers.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- agentbox.sh (agent installation helpers, step 7 and final outcome reporting)
- tests/test_installers.py (create)
- tests/support.py (only fixture support required here)
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/honest-agent-installation`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Implement checked download and execution paths

Keep as_agent's login environment behavior for existing callers. For installer commands, download to a temporary file owned by the agent using curl -f, execute only after a successful download, and clean up on all exits. Alternatively an explicitly pipefail-enabled child Bash is acceptable only if installer completion and binary validation remain separately checked. Create ~/.local/bin explicitly before linking OpenCode. Do not change upstream URLs, disable TLS, remove pi --ignore-scripts, or log credentials. Preserve complete bounded command errors in a private log or concise redacted diagnostics instead of a generic network-only explanation.

**Verify:** `python3 -m unittest discover -s tests -p 'test_installers.py' -v` → Curl failure never executes downloaded content or creates an OpenCode success symlink; installer failure is nonzero; cleanup passes.

### Step 2: Verify required executable health and accumulate failures

Use the intended absolute user-local agent path and capture the entire --version command's exit code before selecting a display line. An executable is usable only when it exists, returns zero and gives nonempty version output. A pre-existing broken binary must not be logged as already installed successfully; attempt the normal reinstall once or record failure. Track required failures for claude/codex/opencode/pi (and required Node availability), continue enough to create diagnostic helpers, then exit nonzero with a named failure summary instead of Done. Tailcat remains optional, uv remains best effort under --with-dev. Do not run agentbox-verify automatically as a completion check because it has side effects and external dependencies.

**Verify:** `python3 -m unittest discover -s tests -p 'test_installers.py' -v` → Every required failure makes final status nonzero; all healthy agents yield zero; optional-only failures remain warnings.

### Step 3: Protect idempotency and recovery

Test first install, healthy rerun with no installer calls, dangling symlink, missing executable, executable returning nonzero, blank output and numeric output with nonzero exit. Include pi/npm failure and root shims present on rerun so success checks cannot accidentally accept a shim. Keep the new Node LTS code intact; plan 005 owns its detailed version selection and staging.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_installers.py' -v && git diff --check` → Exit 0; all success/failure/recovery cases pass and a healthy rerun performs no reinstall.

## Test plan

Create/extend `tests/test_installers.py` using unittest and tests/support.py as described above. Cover:

- Each required agent: failed download/install/version, blank version, valid version, healthy existing installation.
- OpenCode failed download does not create success symlink.
- pi install failure; Node unavailable; --with-dev uv failure; optional tailcat failure.
- Final summary lists failed required tools and exits nonzero without printing Done.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_installers.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- Fixing these paths would require changing upstream authentication or permission defaults.
- An installer cannot be checked without exposing its secret-bearing output; retain a private diagnostic and report the limitation.

## Maintenance notes

Parent errexit is not a substitute for child-shell checks, especially commands executed in &&/|| contexts. Reuse checked execution for future agents, but do not turn this into a general provisioning framework.
