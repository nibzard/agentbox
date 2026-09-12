# Plan 003: Handle empty CA environments and release lookup failures explicitly

> **Executor instructions:** Read this entire plan before editing. Execute each step and its checks. No source fixes were implemented during planning. Update only your status row in plans/README.md when complete; do not mark DONE with required verification outstanding.
>
> **Drift check:** `git diff --stat 338f977..HEAD -- agentbox.sh tests/test_bootstrap.py tests/support.py` and `git diff -- agentbox.sh tests/test_bootstrap.py tests/support.py`. Compare the excerpts below with current code. Changes explicitly described by prerequisites are expected; accommodate those changes rather than reverting them. Stop for unexplained semantic drift. Line numbers are navigation aids, not extraction anchors.

## Status

- **Priority:** P1
- **Effort:** M (S: hours; M: about a day; includes tests)
- **Risk:** LOW
- **Confidence:** HIGH for the evidenced defect; live Linux behavior still requires the integration plan.
- **Depends on:** plan 001
- **Category:** bug
- **Planned at:** commit `338f977`, 2026-09-12; clean working tree before plans were added.

## Why this matters

The latest commit repairs npm trust by redirecting replacement CA variables to the combined system bundle. Preserve that repair. The env|grep pipeline still aborts setup under set -euo pipefail when the egress certificate exists but no matching variables are exported. Tailcat's unchecked release-lookup assignment likewise exits before its fallback. CA values are also interpolated as shell syntax rather than serialized safely.

## Current state

Repository: `/Users/nikola/dev/steel/agentbox`. Run commands from the repository root (or your isolated checkout's root). `agentbox.sh` is a Bash root provisioner for disposable Debian/Ubuntu VMs and generates its helpers/configs with heredocs. `tests/e2e.sh` provisions a Steel computer, runs the installer twice, invokes `agentbox-verify`, and deletes only computers it owns. README.md is the public interface documentation.

`agentbox.sh:154`

```bash
if [[ -n "$EGRESS_CA" ]]; then
  install -m 0644 "$EGRESS_CA" /usr/local/share/ca-certificates/sandbox-egress-ca.crt
  update-ca-certificates >/dev/null 2>&1 || true
  # The sandbox sets per-tool CA variables to a bundle that holds only the
  # egress CA. Most of those variables REPLACE the trust store, and the proxy
  # passes some hosts through untouched (registry.npmjs.org, for one), so npm
  # and friends then fail with "unable to get local issuer certificate".
  # Point every path-valued variable at the system bundle instead: it now
  # holds the egress CA and the public roots. NODE_EXTRA_CA_CERTS is additive
  # and keeps the single egress CA. Runtimes with their own store get defaults.
  SYS_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  {
    echo "# Egress CA env captured by agentbox.sh from the provisioning shell,"
    echo "# path values redirected to the system bundle (egress CA + public roots)."
    env | grep -E '^(.*_CA_BUNDLE|.*CAINFO|.*CA_CERTS.*|.*CAFILE|.*CACERTS.*|.*_CERT|SSL_CERT_FILE|PIP_CERT|CONDA_SSL_VERIFY|DENO_TLS_CA_STORE|UV_NATIVE_TLS|.*_SSL_CA_FILE)=' \
      | sort | sed 's/^/export /; s/=\(.*\)$/="\1"/' \
      | sed -E "/^export NODE_EXTRA_CA_CERTS=/! s#=\"/[^\"]+\"#=\"$SYS_BUNDLE\"#"
    echo "# Defaults for runtimes with their own trust store"
    for v in SSL_CERT_FILE REQUESTS_CA_BUNDLE PIP_CERT NPM_CONFIG_CAFILE; do
      [[ -n "${!v:-}" ]] || echo "export $v=$SYS_BUNDLE"
    done
    [[ -n "${NODE_EXTRA_CA_CERTS:-}" ]] || echo "export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/sandbox-egress-ca.crt"
    [[ -n "${UV_NATIVE_TLS:-}" ]] || echo "export UV_NATIVE_TLS=1"
  } > /etc/profile.d/00-agentbox-egress-ca.sh
  # The rest of this script runs installers as $AGENT_USER through login shells,
  # which read profile.d. Load it here too so nothing in this run misses it.
  . /etc/profile.d/00-agentbox-egress-ca.sh
```

`agentbox.sh:686`

```bash
if [[ $WITH_TAILCAT -eq 1 ]]; then
  TC_ARCH=$(dpkg --print-architecture)            # amd64 | arm64 | armhf
  [[ $TC_ARCH == armhf ]] && TC_ARCH=armv7
  if [[ $TAILCAT_VERSION == latest ]]; then
    TAILCAT_VERSION=$(curl -fsSL https://api.github.com/repos/tailscale/tailcat/releases/latest 2>/dev/null \
                      | jq -r '.tag_name // empty' | sed 's/^v//')
    [[ -n $TAILCAT_VERSION ]] || { TAILCAT_VERSION=0.6.0; warn "GitHub API unreachable, pinning tailcat $TAILCAT_VERSION"; }
  fi
```

## Conventions and test contract

Keep the distributed installer self-contained; do not add sourced runtime files to this repository that break `bash -s < agentbox.sh`. Small functions, arrays for argv and quoted heredocs match existing code. The `have`/`warn`/`die` helpers in agentbox.sh:74-79 are the reporting pattern; `put_block` at line 83 is the managed Bash configuration pattern. Preserve Steel procfs healing, combined CA trust, the login banner/terminfo fix, user-local Node, all four agent integrations and current authentication policy.

The existing test example is tests/e2e.sh: Bash `set -euo pipefail`, explicit command statuses and owned-resource cleanup. Local unit tests are **new infrastructure specified by plan 001**, not a pre-existing suite. Use Python standard-library unittest files under tests/, import fixture utilities from tests/support.py, and derive executed shell from production source using unique stable anchors. Do not duplicate the implementation in a test or execute the complete provisioner on the host. Each fixture controls only child-process HOME/PATH/cwd and temporary directories. Use synthetic values only, never developer credentials.

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Existing shell syntax baseline | `bash -n agentbox.sh && bash -n tests/e2e.sh` | Exit 0; verified at planning time |
| Patch whitespace | `git diff --check` | Exit 0; verified at planning time |
| Focused regressions (create in this plan) | `python3 -m unittest discover -s tests -p 'test_bootstrap.py' -v` | All cases pass, at least one test discovered |
| Full local suite (introduced by plan 001) | `python3 -m unittest discover -s tests -p 'test_*.py' -v` | All cases pass, nonzero test count |
| Optional shell lint when installed | `shellcheck agentbox.sh tests/e2e.sh` | No new actionable diagnostics; baseline findings must be recorded |
| Existing live integration, reserved for plan 011 | `bash tests/e2e.sh` | Both install runs and acceptance exit 0; owned VM deleted |

No package install/build/typecheck exists for this Bash repository. Python 3 and Bash suffice for the local suite. ShellCheck was unavailable during planning. A local test pass is not a claim of a live Steel pass.

## Scope

**In scope:**

- agentbox.sh (CA persistence and tailcat version lookup only)
- tests/test_bootstrap.py (create)
- tests/support.py (only fixture support required here)
- plans/README.md (this plan's status row only)

**Out of scope:** Every other file; LICENSE; credential values/authentication flows; changes to sudo privileges; live deployment/release; unrelated installer stages. Source changes in shared agentbox.sh must remain within the sections described above. Tests may extend support.py only where explicitly listed.

## Git workflow

Use a branch such as `fix/bootstrap-error-handling`. You are not alone in the codebase: preserve others' edits, especially completed prerequisite plans. Because these plans share agentbox.sh, execute serially in index order. Match existing Conventional Commit style, e.g. `fix: agent-status reads agent versions as the agent user`. Do not stage unrelated changes, merge, push or publish a PR unless the operator requests that action.

## Steps

### Step 1: Preserve trust semantics while safely serializing variables

Replace line-oriented env parsing with enumeration of exported variable names and indirect value reads, retaining the current allowlist. Treat zero matches as normal. Emit POSIX-shell-compatible single-quoted values with embedded quote escaping; profile.d is read by shells other than Bash. Preserve NODE_EXTRA_CA_CERTS's additive treatment and combined-system-bundle replacement for absolute path-valued CA variables, plus the new default variables and UV_NATIVE_TLS behavior. Include certificate-file-only detection with no CA variables. Do not disable TLS verification, remove public roots, or revert the latest npm CA fix. Generate the file in a temporary sibling, validate it, then replace it rather than leave a partial profile on serialization failure.

**Verify:** `python3 -m unittest discover -s tests -p 'test_bootstrap.py' -v` → CA no-match/default/round-trip and sh -n cases pass; literal dollar signs and quotes remain data.

### Step 2: Check the optional release lookup before using its result

Place tailcat's API lookup in an explicit conditional that handles curl failure, invalid JSON, empty/missing/null tag_name and invalid version strings. On failure retain the existing fallback version 0.6.0 with one warning; do not invent a new fallback release. Validate successful tag formatting before building a URL. Keep checksum enforcement and --no-tailcat behavior. A release lookup failure must reach later helper generation; a skipped optional install remains a warning, not success.

**Verify:** `python3 -m unittest discover -s tests -p 'test_bootstrap.py' -v` → All lookup failures take the fallback; valid tags are used; --no-tailcat performs zero lookups.

### Step 3: Prove errors are handled under production shell options

Run the extracted control-flow fixtures with set -euo pipefail, recording a sentinel immediately after each section. Test HTTP failures, truncated JSON and the CA file-only case; sentinel must be reached where fallback is intended. Keep unrelated apt and mandatory trust-store errors visible rather than adding blanket || true handlers.

**Verify:** `bash -n agentbox.sh && bash -n tests/e2e.sh && python3 -m unittest discover -s tests -p 'test_bootstrap.py' -v && git diff --check` → Exit 0; all explicit fallback and unexpected-error cases have their specified statuses.

## Test plan

Create/extend `tests/test_bootstrap.py` using unittest and tests/support.py as described above. Cover:

- CA detected via file only with no exported CA variables; no CA detected at all.
- Absolute replacement variables use combined roots; additive Node CA retains intended path.
- Quoted values containing spaces, literal dollar signs, single quotes and newlines round-trip without execution.
- Tailcat curl error, invalid JSON, missing/null tag, malformed tag, valid tag, explicit version and disabled install.

Run the focused command after each change, then the full local suite once for this plan. Regression tests must fail against the old behavior for the defect they target; include meaningful negative controls. Test counts must be nonzero.

## Done criteria

- [ ] Every step's stated behavior and named regression cases are implemented and pass.
- [ ] `bash -n agentbox.sh && bash -n tests/e2e.sh` exits 0.
- [ ] `python3 -m unittest discover -s tests -p 'test_bootstrap.py' -v` exits 0 with a nonzero test count.
- [ ] `python3 -m unittest discover -s tests -p 'test_*.py' -v` exits 0 with all earlier regressions passing.
- [ ] `git diff --check` exits 0.
- [ ] `git diff --name-only` and `git ls-files --others --exclude-standard` show no unexpected files created by this executor outside scope; preserve pre-existing operator changes.
- [ ] Required live checks, if specified in this plan, have recorded outcomes; otherwise report them as deferred to plan 011.
- [ ] The matching plans/README.md row records DONE and verification evidence, or BLOCKED with the unmet requirement.

## STOP conditions

Stop and report if unexplained source drift invalidates an excerpt, two reasonable attempts cannot make a required check pass, or the implementation needs an out-of-scope change. Expected prerequisite changes are not a blocker. Also stop if:

- The proposed trust change loses the public-root plus egress-CA behavior added in c7539ac.
- A failure is being swallowed outside the specific optional/no-match cases in scope.

## Maintenance notes

Do not use printf %q in a system profile without considering non-Bash consumers. Node release handling is owned by plan 005, not this plan.
