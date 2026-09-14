# Fix implementation plan

Prepared on 2026-09-12 against **338f977**, after reconciling both review passes with the latest merged changes. All eleven fixes are implemented and reviewed. The status table records reviewed commits and completed checks; the live results are recorded below.

This is one ordered program of fixes, split into independently executable handoffs. User request: “create plan for fixes”; all concrete findings from both review passes are covered. Related verifier defects and configured helper defects are grouped to avoid conflicting edits. Effort estimates are coarse; S means hours, M about a day, including tests.

## Execution order and status

| Plan | Outcome | Priority | Effort | Depends on | Status |
|---|---|---|---|---|---|
| [001](001-local-regression-harness.md) | Establish a local regression harness for generated shell code | P1 | M | — | DONE — e3b96f0; reviewer: 9 local tests + syntax passed |
| [002](002-safe-accurate-verifier.md) | Make acceptance checks safe and trustworthy | P1 | M | 001 | DONE — f6e16c5; reviewer: 19 local tests + syntax passed |
| [003](003-bootstrap-error-handling.md) | Handle empty CA environments and release lookup failures explicitly | P1 | M | 001 | DONE — a7fbf93; reviewer: 25 local tests + syntax passed |
| [004](004-honest-agent-installation.md) | Return failure when required agents are unavailable | P1 | M | 001, 003 | DONE — bfca126; reviewer: 32 local tests + syntax passed |
| [005](005-complete-node-runtime-fix.md) | Enforce the complete pi Node requirement and validate runtime installation | P1 | M | 001, 004 | DONE — 531e3e1; reviewer: 40 local tests + syntax passed |
| [006](006-configured-helper-behavior.md) | Honor custom user/workspace settings and make work attach or create | P2 | M | 001, 002 | DONE — cca1bce; reviewer: 46 local tests + syntax passed |
| [007](007-preserve-user-configuration.md) | Preserve user-owned configuration on reruns | P2 | M | 001, 002, 006 | DONE — 5845217; reviewer: 54 local tests + syntax passed |
| [008](008-safe-project-scaffolding.md) | Keep new-project from committing existing work | P2 | S | 001, 002, 006 | DONE — 3b5f517; reviewer: 60 local tests + syntax passed |
| [009](009-ephemeral-port-sharing.md) | Implement the documented ephemeral vm-share option | P2 | S | 001, 006 | DONE — 830a0b6; reviewer: 64 local tests + syntax passed |
| [010](010-live-status-reporting.md) | Query status at runtime in the correct user context | P2 | S | 001, 006 | DONE — 39549a2 + 1012453; reviewer: 69 local tests + syntax passed |
| [011](011-integration-matrix-and-docs.md) | Validate the combined fixes and reconcile documentation | P1 | M | 001, 002, 003, 004, 005, 006, 007, 008, 009, 010 | DONE — 16222c7 + 8901df2; reviewer: 74 local tests + syntax + all 3 Steel cases passed |

Status values: TODO, IN PROGRESS, DONE, BLOCKED (with reason), REJECTED (with reason). Add concise verification evidence when updating a status. Do not claim DONE solely because the implementation looks correct.

## Recommended sequence

1. **001–002:** Establish the offline test harness, then make the acceptance verifier safe and accurate before it is used on a real box.
2. **003–005:** Preserve the latest TLS/Node improvements while correcting bootstrap errors, required-agent outcomes and the exact Node minimum.
3. **006–010:** Fix configured helpers, preserve user files, protect project scaffolding, implement ephemeral sharing and refresh status at runtime.
4. **011:** Run the combined local suite and live matrix, and reconcile documentation with observed behavior.

Execute serially: almost every plan edits agentbox.sh. Even where logical dependencies permit parallel work, simultaneous edits to that file add avoidable integration risk. Each plan includes the necessary context and the test-harness contract; no executor needs the review conversation.

## Dependency notes

- 001 provides tests/support.py and standard-library unittest discovery. Later plan commands refer to tests that their executor must create; they are not present yet.
- 002 fixes destructive cleanup before live verification and passes scaffold parents explicitly, so later workspace/scaffold changes can remain safe.
- 004 builds on 003's trust/error behavior. 005 completes the new Node path using 004's required-install failure outcome.
- 006 establishes configured user/workspace propagation and safe root-to-agent argument handling. 007–010 retain that behavior.
- 007 updates verifier expectations for legitimate custom dotfiles; 002's fresh-default tests must remain as generation tests.
- 011 depends on all fixes. Missing live access is recorded explicitly; local checks alone do not satisfy its completion gate.

## Review finding coverage

| Review finding | Plan |
|---|---|
| First pass 1: verifier deletes existing work | 002 |
| First pass 2 / second pass 3: silent required-agent/OpenCode install failures | 004 |
| First pass 3: CA no-match and tailcat lookup aborts | 003 |
| First pass 4: non-root work fallback | 006 |
| First pass 5: custom user/workspace propagation | 006 |
| First pass 6: lean false failure and listener false pass | 002 |
| First pass 7: overwritten user configuration | 007 |
| First pass 8: new-project commits unrelated work | 008 |
| First pass 9: vm-share --ephemeral unsupported | 009 |
| First pass 10: baked-in tailcat status | 010 |
| Second pass 1: unsupported stock Node for pi | Partially fixed upstream; remaining exact-minimum/failure checks in 005 |
| Second pass 2: banner masks missing aliases | 002 |
| Local feedback loop and honest integration/docs claims | 001, 011 |

## Reconciliation with changes since the reviews

- **c7539ac already adds user-local Node LTS.** Do not reimplement the original “no compatible Node installed” finding. Current installer/verifier only check major >=22; plan 005 handles >=22.19.0 and lookup/download validation.
- **c7539ac fixes replacement CA bundles for npm/public endpoints.** Plan 003 preserves combined public+egress roots, NODE_EXTRA_CA_CERTS additive behavior and runtime defaults while handling empty variable lists and safe shell serialization.
- **5db381b runs agent version queries in the agent login environment.** Plan 010 preserves that fix while avoiding unnecessary su for the agent caller and making tailcat discovery happen at runtime.
- Login banner and TERM/terminfo changes remain. Plan 002 fixes tests polluted by banner output; plan 006 fixes the independent tmux exec fallback.

## Findings considered and rejected or deferred

- Passwordless sudo, copied OAuth files, bypass aliases and address-based SSH are explicit disposable-VM design choices. Do not redesign them during these fixes.
- Native installer delivery is an intentional dependency mechanism; failure detection is the concrete defect. General package pinning/upgrade policy remains a separate future decision.
- A full source-module rewrite, plugin architecture, dashboards, provider sign-in automation and release automation are outside this repair scope.
- Exact static Git/AGENTS.md defaults should be tested at generation time; rejecting a valid user customization in the acceptance verifier conflicts with the preservation fix.
- The status reporter's same-user su edge is included as a targeted compatibility check in 010; do not undo the recent root-side runtime correction.

## Verification baseline and execution environment

Verified during planning: `bash -n agentbox.sh && bash -n tests/e2e.sh` and `git diff --check` exit 0. At planning time the repository had no local tests beyond the Steel E2E runner, no build/typecheck command, and no committed CI workflow. ShellCheck was not available on the planning host.

After 001: `python3 -m unittest discover -s tests -p 'test_*.py' -v` is the local gate. Test code must use isolated temporary directories and must never run the complete root installer on the developer machine.

Existing live command: `bash tests/e2e.sh` requires a configured Steel CLI and STEEL_API_KEY. Plan 011 defines default, lean and custom/preservation cases. Live tests create temporary computers and must retain the runner's owned-resource cleanup contract. No live tests were run to write these plans.

## Primary references used in the review

- [Published pi metadata](https://registry.npmjs.org/@earendil-works/pi-coding-agent/latest): observed engines.node >=22.19.0; recheck before changing its runtime policy.
- [Node official distribution index](https://nodejs.org/dist/index.json): existing user-local installer source.
- [Tailcat key management](https://github.com/tailscale/tailcat#key-management): --key=new is the ephemeral interface.
- [OpenCode installer](https://opencode.ai/install): existing native binary path/installer behavior.

The original plans describe intended behavior. The execution record below supplies the verification evidence for the completed fixes.

## Execution evidence

Implemented in `fix/agentbox-plans` from `5a69124`. The final source/test commit `16222c7` passed the reviewer's full **74-test local suite**, both Bash syntax checks, and whitespace checks on 2026-09-14. ShellCheck was unavailable on the local host. Published pi 0.85.1 still requires Node >=22.19.0 (official registry rechecked the same day).

The reviewer ran all three required fresh-computer cases with Steel CLI `0.5.0-preview.5` on 2026-09-14:

| Case | Command | Acceptance result | Outcome |
|---|---|---|---|
| Default | `bash tests/e2e.sh` | 69 passed, 0 failed, 0 skipped | PASS; owned computer deleted |
| Lean | `AGENTBOX_ARGS="--lean --no-tailcat" bash tests/e2e.sh` | 56 passed, 0 failed, 12 expected skips | PASS; owned computer deleted |
| Custom/preservation | `AGENTBOX_AGENT_USER=dev AGENTBOX_WORKSPACE=/src AGENTBOX_TEST_PRESERVATION=1 bash tests/e2e.sh` | 69 passed, 0 failed, 0 skipped | PASS; owned computer deleted |

All three ran Debian GNU/Linux 13 (trixie), x86_64, with 2 vCPU and 1995 MB RAM. Root retained distro Node **v20.19.2** at `/usr/bin/node`; the configured agent used **v24.21.0** under its own `~/.local/bin`. Observed versions were Claude Code **2.1.270**, Codex CLI **0.154.0**, OpenCode **1.18.30**, pi **0.85.1**, and Tailcat **v0.6.0** in the default/custom cases. Lean deliberately omitted the eleven optional CLI tools and Tailcat, accounting for its twelve skips.

Each case completed two installs, actual agent version commands, trusted curl/npm HTTPS, and bounded PTY tests that created separate sessions from root and the configured user and then attached repeatedly without changing the pane or workspace. The custom case also preserved root/agent Git identity and pager settings, dotfile checksums, agent instructions, and unmanaged Bash additions across the second install. Verifier responses were not truncated or timed out and all returned exit 0. A separate harmless remote `exit 19` probe confirmed that this Steel CLI propagates command failures.

Final quota returned to the baseline of one pre-existing paused computer and zero running computers (limit 10). All three owned test computers were absent from the final list, and the pre-existing computer remained paused. No provider sign-in or Tailcat serving was exercised. Debian 12, Ubuntu, arm64, other VM sizes, and `--with-dev` were not run in this matrix.
