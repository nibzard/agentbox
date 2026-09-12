# Plan 008: Keep new-project from committing existing work

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- agentbox.sh tests/test_scaffold.py tests/support.py README.md` and `git diff -- agentbox.sh tests/test_scaffold.py tests/support.py README.md`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P2
- **Effort:** S (S: hours; M: about a day; includes tests)
- **Risk:** LOW
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** plan 001, plan 002, plan 006
- **Category:** bug
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

new-project accepts an existing target, then runs git add -A and commits every pending change. It also swallows commit failure and prints created. Make this a predictable new-project operation: accept a new or empty directory outside an existing enclosing Git repository, create only the scaffold, and report commit failure accurately.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:803`

```bash
cat > /usr/local/bin/new-project <<'EOF'
#!/usr/bin/env bash
# new-project <name> [dir] — git repo with CLAUDE.md + AGENTS.md scaffold
set -e
name="${1:?usage: new-project <name> [parent-dir]}"; parent="${2:-${WORKSPACE:-/workspace}}"
d="$parent/$name"; mkdir -p "$d"; cd "$d"
[ -d .git ] || git init -q
[ -f CLAUDE.md ] || cat > CLAUDE.md <<MD
```

`agentbox.sh:825`

```bash
[ -e AGENTS.md ] || ln -s CLAUDE.md AGENTS.md
[ -f .gitignore ] || printf '.env\n.env.*\nnode_modules/\n__pycache__/\n.venv/\n.tmp/\n' > .gitignore
mkdir -p .tmp
git add -A && git commit -qm "chore: scaffold $name" || true
echo "created $d"
```

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_scaffold.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- agentbox.sh (new-project generator only)
- tests/test_scaffold.py (create)
- tests/support.py (only fixture support required here)
- README.md (new-project behavior only)
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/safe-project-scaffolding`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Reject targets containing existing work

Validate a nonempty single project name (not ., .., slash-containing or an option-like name) and the parent path. Before writing anything, reject an existing nonempty directory, a symlink target, an existing repo/worktree and a destination inside an enclosing Git repository. Treat .git files as repositories too; do not rely only on -d .git. Permit an empty directory so verifier fixtures can choose their parent explicitly. Use quoted paths and -- where supported. Return a clear nonzero error without changing files, Git index or HEAD.

**Verify:** `python3 -m unittest discover -s tests -p 'test_scaffold.py' -v` → Dirty repo, worktree, nested repo, nonempty and symlink cases all reject without mutation; fresh/empty destinations proceed.

### Step 2: Commit only scaffold files and propagate failure

Create CLAUDE.md, AGENTS.md symlink, .gitignore and .tmp exactly as before for a valid target. Stage only CLAUDE.md AGENTS.md .gitignore, not git add -A. Let initial commit failure return nonzero and print an actionable message that the scaffold exists but its commit failed; leave the files for inspection. Print created only on the defined successful path. Do not install dependencies or create remote repositories.

**Verify:** `python3 -m unittest discover -s tests -p 'test_scaffold.py' -v` → Successful commit contains only the three scaffold paths; forced commit failure is nonzero with no success message.

### Step 3: Document and verify caller compatibility

Document rejection of existing work and the optional parent directory. Confirm verifier creates the scaffold under its unique temporary root and passes the parent explicitly. Use temporary real Git repositories with fixture-local identity/config to test index and commit contents; avoid the operator's global Git identity/hooks.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_*.py' -v && git diff --check` → Exit 0; scaffold and verifier cases both pass.

## Test plan

Create/extend `tests/test_scaffold.py` using unittest and tests/support.py as described above. Cover:

- Fresh and empty target; existing untracked files; dirty/staged repo; .git worktree file; enclosing repo.
- Invalid/traversing name, symlink destination and parent path with spaces.
- Commit failure preserves generated files, reports failure and never stages unrelated files.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_scaffold.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- A change would modify an existing target repo to make the command succeed.
- A test is about to use the developer repository or global Git config rather than a temporary fixture.

## Maintenance notes

Rejection is an intentional behavior change that protects existing work. If an explicit scaffold-existing mode is desired later, design it separately with narrow staging semantics.
