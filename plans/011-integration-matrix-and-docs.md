# Plan 011: Validate the combined fixes and reconcile documentation

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- agentbox.sh tests/e2e.sh tests/test_e2e_runner.py tests/support.py README.md` and `git diff -- agentbox.sh tests/e2e.sh tests/test_e2e_runner.py tests/support.py README.md`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P1
- **Effort:** M (S: hours; M: about a day; includes tests)
- **Risk:** MED
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** plan 001, plan 002, plan 003, plan 004, plan 005, plan 006, plan 007, plan 008, plan 009, plan 010
- **Category:** tests
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

The existing E2E runner runs the same setup twice with no intervening user changes. It does not test custom configuration or preservation, and local syntax cannot prove Linux user switching, procfs recovery, apt availability, TLS or real agent execution. Add a small explicit matrix and rerun-preservation exercise, then align public claims with verified behavior.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:190`

```bash
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
```

`agentbox.sh:989`

```bash
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
printf '\n%s============================================================%s\n' "$c_green" "$c_off"
echo "  Done. Next:"
echo "    work            # opens tmux as $AGENT_USER in $WORKSPACE"
echo "    yolo            # inside: claude --dangerously-skip-permissions"
echo "    agent-status    # verify"
[[ $COPY_AUTH -eq 1 ]] || echo "  Auth: run 'claude' and 'codex login' once as $AGENT_USER."
printf '%s============================================================%s\n' "$c_green" "$c_off"
```

`tests/e2e.sh:16`

```bash
AGENTBOX_ARGS="${AGENTBOX_ARGS:-}"
CREATED=0
if [[ -z "${COMPUTER_ID:-}" ]]; then
  echo "==> creating a Steel computer"
  COMPUTER_ID=$(steel computer create --wait --timeout 1800 --json | jq -r '.data.id')
  CREATED=1
fi
echo "==> box: $COMPUTER_ID"

cleanup() {
  if (( CREATED )) && [[ "${KEEP:-0}" != 1 ]]; then
    echo "==> deleting $COMPUTER_ID"
    steel computer delete "$COMPUTER_ID" >/dev/null
  else
    echo "==> keeping $COMPUTER_ID (steel computer ssh $COMPUTER_ID)"
  fi
}
trap cleanup EXIT

# The box has no curl yet, so the script goes in over ssh. Root is the ssh user.
run_script() {
  # shellcheck disable=SC2086
  steel computer ssh "$COMPUTER_ID" -- bash -s -- $AGENTBOX_ARGS < agentbox.sh
}

echo "==> first run"
run_script
echo "==> second run (idempotency)"
run_script

# exec returns the remote exit code, so a failing check fails this script.
echo "==> agentbox-verify"
steel computer exec "$COMPUTER_ID" --timeout 300 -c 'agentbox-verify'
echo "==> e2e passed"
```

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_e2e_runner.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- agentbox.sh (final help/sign-in messaging only; preserve plan 004 failure status handling)
- tests/e2e.sh
- tests/test_e2e_runner.py (create)
- tests/support.py (only fixture support required here)
- README.md
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/integration-matrix-and-docs`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Expose safe configuration inputs in the existing runner

Retain COMPUTER_ID/KEEP behavior. Check jq availability before creating a computer, validate the returned ID before use, and install cleanup as early as an owned ID is known; malformed creation output must not proceed to provisioning or delete an unknown ID. Add AGENTBOX_AGENT_USER and AGENTBOX_WORKSPACE inputs, defaulting to agent and /workspace, and forward them as quoted env arguments to the remote installer. Keep AGENTBOX_ARGS as a whitespace-separated list of known no-value flags; parse to an array and validate instead of eval. Add AGENTBOX_TEST_PRESERVATION=1 to insert controlled user edits between installer runs on a newly created disposable computer only. Refuse that mutation mode with a caller-supplied COMPUTER_ID. Use temporary names and preserve cleanup/remote exit status. Do not log credentials, tailcat addresses or auth contents.

**Verify:** `python3 -m unittest discover -s tests -p 'test_e2e_runner.py' -v` → Fake Steel CLI verifies argv, remote status, owned-computer deletion, KEEP and refusal of preservation mutations on borrowed computers.

### Step 2: Add preservation and behavior assertions

In preservation mode, after first setup assign fixture Git identity and custom pager, append sentinel text to generated user-owned dotfiles/instructions, and record checksums/selected Git values without secret-bearing content. Rerun setup and compare. Exercise real tmux create/attach-or-create behavior through a temporary PTY and unique session, both root and agent, with a bounded timeout and cleanup. Verify helper user/workspace selection, agent-local Node >=22.19.0, all four actual --version exit codes, and trusted HTTPS for curl and npm. Do not sign in to providers or start remotely accessible tailcat servers. Run the generated verifier after the second setup.

**Verify:** `python3 -m unittest discover -s tests -p 'test_e2e_runner.py' -v` → Stubbed runner tests confirm assertions execute in order and every failed remote assertion fails the runner.

### Step 3: Run the local suite and live configuration matrix

First run all local tests, syntax and diff checks. With the already configured Steel CLI and STEEL_API_KEY, run three separate fresh-computer cases shown below. Each case must finish with zero failed acceptance checks and delete only the computer it created. Record observed OS/architecture and actual agent/runtime versions, without credentials. The Steel cases establish its Debian environment only; do not claim Ubuntu or arm64 was executed unless separately provisioned and tested. If no authorized live environment or credentials are available, record local PASS/live NOT RUN and leave this integration plan BLOCKED rather than mark it DONE.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_*.py' -v && git diff --check` → Local exit 0; then run each live command listed under Test plan and require exit 0.

### Step 4: Reconcile public behavior and verification evidence

Update README to say four agents, distinguish installation from authentication, specify Node >=22.19.0 and preserved root distro runtime, describe configuration/rerun ownership and new-project rejection accurately, and replace the "read-only allowlist" claim with an accurate description of preapproved shell commands and file-tool guardrails. Do not change permissions or add hardening flows. Add local/matrix commands and list tested vs untested targets explicitly; do not promise universal idempotency or approximate timings without measurements. Ensure successful setup reports all four sign-in entry points where documentation is shown.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_*.py' -v && git diff --check` → Exit 0; docs describe final behavior and recorded live outcomes without claiming unrun checks.

## Test plan

Create/extend `tests/test_e2e_runner.py` using unittest and tests/support.py as described above. Cover:

- Runner stubs: create/delete, KEEP, borrowed COMPUTER_ID, malformed create response, remote failure and exact env argv.
- Live default: bash tests/e2e.sh
- Live lean: AGENTBOX_ARGS="--lean --no-tailcat" bash tests/e2e.sh
- Live custom/preservation: AGENTBOX_AGENT_USER=dev AGENTBOX_WORKSPACE=/src AGENTBOX_TEST_PRESERVATION=1 bash tests/e2e.sh
- Default distro and configured user use correct Node; real agents execute; npm/curl TLS works; user edits survive rerun.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_e2e_runner.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- Live Steel access is unavailable: record local results and the missing integration evidence; do not mark this plan DONE.
- COMPUTER_ID refers to a user-owned machine and preservation mode would edit its dotfiles.
- A live run fails: retain safe diagnostics and repair the owning earlier plan instead of weakening acceptance checks.

## Maintenance notes

Do not run this matrix during plan creation. Future changes to profiles, required agents or config ownership should add a case here and a cheaper local regression first. No CI deployment, provider login, release or public publishing is part of these plans.
