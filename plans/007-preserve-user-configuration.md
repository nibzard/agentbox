# Plan 007: Preserve user-owned configuration on reruns

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- agentbox.sh tests/test_preservation.py tests/test_verifier.py tests/support.py README.md` and `git diff -- agentbox.sh tests/test_preservation.py tests/test_verifier.py tests/support.py README.md`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P2
- **Effort:** M (S: hours; M: about a day; includes tests)
- **Risk:** MED
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** plan 001, plan 002, plan 006
- **Category:** bug
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

write_dotfiles overwrites Git, tmux, Vim and Readline settings for both root and the agent, while the global instructions and AGENTS.md symlinks are also overwritten. A rerun resets a manually configured Git identity and credential helper. Adopt a narrow preservation policy: create defaults only for absent user-owned files, preserve existing content, and reserve automatic refresh for clearly managed blocks/system files.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:393`

```bash
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
```

`agentbox.sh:445`

```bash
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
```

`agentbox.sh:495`

```bash
  chown -R "$owner:$owner" "$home/.bashrc" "$home/.inputrc" "$home/.tmux.conf" "$home/.gitconfig" "$home/.vimrc"
}

write_dotfiles "$AGENT_HOME" "$AGENT_USER"
write_dotfiles /root root
ok "bash / tmux / git / vim / inputrc for $AGENT_USER and root"

# =============================================================================
hdr "6/10  Agent configs: CLAUDE.md, AGENTS.md, settings, Codex config"
# =============================================================================
mkdir -p "$AGENT_HOME/.claude" "$AGENT_HOME/.codex" "$AGENT_HOME/.config/opencode" "$AGENT_HOME/.pi/agent" "$AGENT_HOME/.agentbox"

cat > "$AGENT_HOME/.claude/CLAUDE.md" <<EOF
```

`agentbox.sh:537`

```bash
# Codex, OpenCode and pi read a global AGENTS.md; keep one source of truth.
ln -sfn "$AGENT_HOME/.claude/CLAUDE.md" "$AGENT_HOME/.codex/AGENTS.md"
ln -sfn "$AGENT_HOME/.claude/CLAUDE.md" "$AGENT_HOME/.config/opencode/AGENTS.md"
ln -sfn "$AGENT_HOME/.claude/CLAUDE.md" "$AGENT_HOME/.pi/agent/AGENTS.md"

# Claude Code user settings (merge-free: only written if absent so re-runs
# don't clobber choices the user made from inside Claude).
if [[ ! -s "$AGENT_HOME/.claude/settings.json" ]]; then
cat > "$AGENT_HOME/.claude/settings.json" <<'EOF'
```

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_preservation.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- agentbox.sh (put_block, write_dotfiles, instruction files/symlinks, affected verifier assertions)
- tests/test_preservation.py (create)
- tests/test_verifier.py (pager/config expectation updates)
- tests/support.py (only fixture support required here)
- README.md (rerun and ownership policy only)
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/preserve-user-configuration`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Make file ownership policy explicit

Keep the existing marker-managed .bashrc behavior and refresh system/helper files as before. For .inputrc, .tmux.conf, .vimrc and .gitconfig, create defaults only when the path is absent; preserve even empty existing files and existing symlinks. If an existing symlink is dangling, report it and leave it intact. Do not auto-migrate unmarked old files or guess whether they were generated; preserving them is the safe upgrade policy. Restrict chown to newly created paths rather than recursively following user configuration. Fix put_block to preserve existing permission bits/ownership during replacement; do not relax a private file to the current umask.

**Verify:** `python3 -m unittest discover -s tests -p 'test_preservation.py' -v` → Fresh files get defaults; modified/empty/symlink paths survive byte-for-byte; .bashrc external text and permissions survive repeated updates.

### Step 2: Preserve identities and agent instructions

For an existing .gitconfig, only apply user.name/user.email if GIT_NAME/GIT_EMAIL were explicitly supplied, using git config --file with properly quoted values. If unspecified, preserve existing identity and credential helpers. Create global CLAUDE.md only when absent and create each AGENTS.md symlink only when no path exists; preserve regular user-authored AGENTS.md and differing symlinks. Keep create-if-absent Claude settings/Codex config semantics and credential copying unchanged. Do not build a include/migration framework for this fix.

**Verify:** `python3 -m unittest discover -s tests -p 'test_preservation.py' -v` → Explicit identity overrides affect only named keys; unspecified settings and user instructions remain identical; new homes receive the shared default symlinks.

### Step 3: Make verification and docs respect customization

Update verifier assertions that mandate delta, pull.rebase, push.autoSetupRemote or exact global instruction symlinks: fresh-default correctness belongs in local generation tests, while acceptance on a customized box should check readability/validity and executable availability without rejecting legitimate user overrides. Test a custom pager, custom Git values and regular AGENTS.md. Document that reruns update managed Bash/system/helper content and preserve existing user-owned dotfiles/instructions; existing generated files do not automatically receive new defaults.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_*.py' -v && git diff --check` → Exit 0; both fresh defaults and intentionally customized configurations pass appropriate tests.

## Test plan

Create/extend `tests/test_preservation.py` using unittest and tests/support.py as described above. Cover:

- Fresh root/agent homes; rerun after editing every affected file; empty and symlinked files.
- Git identity set manually, explicit GIT_NAME-only update, credential helper preserved.
- Custom global CLAUDE.md, regular AGENTS.md and alternate symlink survive.
- Managed .bashrc block occurs once and external content/file mode survives.
- Verifier accepts valid custom Git settings and instruction paths.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_preservation.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- A file cannot be safely classified as absent or user-owned; preserve it and report.
- An existing symlink points outside the expected home and would be followed by a write/chown.

## Maintenance notes

This deliberately favors preservation over retroactive defaults migration. Future configuration migrations must be explicit. Fresh-install tests still enforce the shipped defaults so relaxed acceptance does not hide template errors.
