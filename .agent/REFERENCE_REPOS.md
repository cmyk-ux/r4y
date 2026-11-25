# R4Y external reference watchlist

Last reviewed: 2026-11-25
Active R4Y branch during this audit: `feature/wave64-host-target`
Priority order requested by the project owner:

1. [Zettrox/ztrx](https://github.com/Zettrox/ztrx)
2. [Marvisak/VIctory](https://github.com/Marvisak/VIctory)
3. [fxceless/victory-fork](https://github.com/fxceless/victory-fork)
4. [xcl-dev/xcl](https://github.com/xcl-dev/xcl)

This is a standing research task, not a one-time comparison. Revisit these repositories during R4Y investigations and whenever upstream issues/PRs/commits change in an area that overlaps R4Y. Keep the priority order above even when a lower-priority repository happens to contain the closest reproduction of the current bug.

## Review method

For each audit:

- Inspect recent commits, recently updated issues and PRs; search targeted terms for the current failure class. Follow the full chain where relevant: initial issue/report, comments and test environment, proposed PR, commit date/diff, validation result, merge/revert status.
- Compare the actual code against the current R4Y branch before porting. A similar title, API name, hash or error code is not proof that the same underlying mechanism is present.
- Prefer a small R4Y-native implementation with regression tests over cherry-picking. Keep hardware, driver, OS, title build, cache state, branch/commit and reproducibility attached to each claim.
- Record both useful ideas and negative results. Do not keep a workaround after its upstream report has been reverted or disproved without re-evaluating it.
- Recheck what changed since the previous audit; do not repeat a full historical scan every session unless the bug warrants it.

### Scope of this 2026-11-25 audit

Sampled up to 25 recent commits and up to 100 recently updated issues and PRs per repository, then followed the relevant issues, comments, patches and commits below. Targeted searches covered GPU device removal/hangs, Wave64, D3D12 resource descriptions, pipeline compilation, memory/streaming and synchronization. This is a focused high-relevance audit, not a claim that every historical issue and every page of every repository has been exhaustively read.

## 1. Zettrox/ztrx

Repository: https://github.com/Zettrox/ztrx

Relevant findings:

- [Issue #38](https://github.com/Zettrox/ztrx/issues/38) reports high RAM/commit and VRAM/shared-GPU-memory use with the same title shader-build identity family, plus long host submissions. It did not reproduce the same crash. Keep memory pressure/streaming as a secondary hypothesis, not the explanation for the title's GPU-progress watchdog.
- [Issue #71](https://github.com/Zettrox/ztrx/issues/71) tested larger card buffers without a measurable win. [Issue #78](https://github.com/Zettrox/ztrx/issues/78) reported a better frame-time result with a low minimum card-buffer setting, but memory use and streaming failures remained. These are workload-specific experiments, not defaults to copy.
- [Issue #73](https://github.com/Zettrox/ztrx/issues/73) and commit [d279e69](https://github.com/Zettrox/ztrx/commit/d279e69ae999aedfd3d463b0c45c8fd125c1ad7b) add a configurable pipeline wait and prewarm/request persistence path. R4Y already has a per-frame pipeline wait budget; compare details when that subsystem changes, but do not duplicate the setting blindly.
- Commit [e9765a7](https://github.com/Zettrox/ztrx/commit/e9765a73a68a75536b1c10ad5ef746d7f6ec0bcc) changes Wave64/group-barrier behavior after device-loss reports and adds a user control. It is a warning that Wave64 plus synchronization can be hardware-sensitive, not proof that globally disabling Wave64 is the correct R4Y default.
- Lane-mask pair work in [90228a7](https://github.com/Zettrox/ztrx/commit/90228a7dc66010281fdcfad10ac00c3a252be2f3) was later backed out by [2119b0e](https://github.com/Zettrox/ztrx/commit/2119b0e44c53aa9648307b0c5c73590290305b1f). Do not transplant an intermediate IR optimization without understanding the revert and its regression evidence.

R4Y decision: retain the current pipeline wait budget; do not increase card-buffer defaults based on these reports; keep Wave64 synchronization under active investigation.

## 2. Marvisak/VIctory

Repository: https://github.com/Marvisak/VIctory

Relevant findings:

- [Issue #2258](https://github.com/Marvisak/VIctory/issues/2258) and [PR #2286](https://github.com/Marvisak/VIctory/pull/2286) document a direct D3D12 device-removal cause: a shared texture's allocation size was queried from the guest/title description instead of the live host texture description. The debug layer rejected `ALLOW_UNORDERED_ACCESS` on `B5G5R5A1_UNORM` (`0x887A0001`). The PR uses `t.texture.GetDesc()` for `GetResourceAllocationInfo`. The PR was still open when inspected; R4Y ported the underlying correction rather than depending on a merge.
- [Issue #966](https://github.com/Marvisak/VIctory/issues/966) reproduces NVIDIA's pipeline compiler overflowing Rust's default 2 MiB worker stack, then reporting `E_OUTOFMEMORY`. Commit [d09c31b](https://github.com/Marvisak/VIctory/commit/d09c31b4c14481155e7d0b33b0aea30d9333f152) gives pipeline workers a 64 MiB stack. The issue reports an A/B on RTX 5080: stack overflow and refused PSO with 2 MiB, no overflow and successful PSO with 64 MiB. This is an independent NVIDIA-driver robustness mitigation.
- [PR #1720](https://github.com/Marvisak/VIctory/pull/1720) adds APU allocation refusal telemetry, including requested bytes and system commit state. It is useful if logs show `ApuAlloc`/host allocator refusal. It is not evidence for the current `+0x23cf683` crash, which matches the title's GPU-progress watchdog (see XCL below); do not conflate these failure paths.

R4Y changes made in this audit:

- `crates/r4y-gpu/src/resource.rs`: query allocation information from the actual live `t.texture.GetDesc()`.
- `crates/r4y-gpu/src/pipeline/make.rs`: give the pipeline worker threads `64 << 20` bytes of stack.

## 3. fxceless/victory-fork

Repository: https://github.com/fxceless/victory-fork

Relevant findings:

- [Issue #833](https://github.com/fxceless/victory-fork/issues/833) is a recent RTX 4070 12 GB report: several Wave64 compute pipelines are refused on a Wave32-only adapter, and the remaining scene is dominated by title-buffer traffic/copy-back. It reports no device removal in that run. It reinforces the need to keep “unsupported wave size”, “slow memory/copy path” and “GPU hang” as separate diagnoses.
- [PR #824](https://github.com/fxceless/victory-fork/pull/824) combines view-memory interval tracking, lock contention fixes, texture-wait policy, XMem alias coalescing and copy-back batching; it reports a large workload-specific CPU-side improvement on RTX 3080 under GE-Proton. This is a broad multi-subsystem patch. Do not port it as a bundle; identify the R4Y equivalent and test each optimization independently.
- [PR #807](https://github.com/fxceless/victory-fork/pull/807) improves invalidation of copied host-heap descriptor state after API writes; [PR #804](https://github.com/fxceless/victory-fork/pull/804) addresses a view lookup/mapping edge case. Keep these in the descriptor correctness backlog.
- [Issue #821](https://github.com/fxceless/victory-fork/issues/821) reports a DirectStorage/texture upload race. [Issue #776](https://github.com/fxceless/victory-fork/issues/776) reports device removal after enabling on-demand levels in intermittent runs. Both are relevant to streaming triage but do not match the exact current watchdog location.

R4Y decision: no wholesale port. Revisit the descriptor-state and sparse-view ideas when the current descriptor virtualization work resumes. Do not treat the RTX 4070 report as proof of the RTX 3070 hang.

## 4. xcl-dev/xcl

Repository: https://github.com/xcl-dev/xcl

This repository currently contains the closest match to the user's title crash:

- [Issue #505](https://github.com/xcl-dev/xcl/issues/505) records `0xc0000005` writing to address zero at game image offset `+0x23cf683`. The issue analysis identifies the code as the title's intentional GPU-progress watchdog path (the embedded `GPU Loc Sig` check followed by a deliberate null write). This is not, by itself, a random null dereference in the emulator.
- [Issue #675](https://github.com/xcl-dev/xcl/issues/675) reports the same offset on an RTX 3070 Ti and correlates watchdog exits with D3D12 GPU hangs. Later comments show more than one split-Wave64 compute shader can be involved: disabling one shader stopped one observed hang in a limited A/B, but another run hung in another compute program. Disabling all split-Wave64 work avoided those hangs in some tests but also removed important compute functionality. Treat per-shader refusal as a diagnostic, not a fix.
- The RTX 3070 Ti report narrows one observed dispatch to `CS_DepthProcessingHBO` with a 64-thread group, two loops and many ballot/exchange sites. That shader is a useful comparison target, but R4Y has a different translator and must not copy the shader hash or assume the same emitted DXIL.
- [PR #1189](https://github.com/xcl-dev/xcl/pull/1189) adds opt-in, non-blocking stall snapshots of submission/fence/pipeline state. It is a useful diagnostic design: observe stalled work without adding new GPU signals or waits.
- [PR #2203](https://github.com/xcl-dev/xcl/pull/2203) improves split-Wave64 per-lane branch emission and SCC liveness. It is a candidate for a later algorithmic comparison against R4Y's `console_cf` lowering, not a complete fix for device hangs.
- [PR #1850](https://github.com/xcl-dev/xcl/pull/1850) limits `globallycoherent` declarations to compute programs that need cross-workgroup coherence/cache invalidation/atomics. Revisit after confirming the actual attributes emitted by R4Y; a text search for the HLSL token alone is insufficient.
- [PR #2057](https://github.com/xcl-dev/xcl/pull/2057) is an integration/reference branch containing several unrelated changes. Inspect individual commits only; do not merge the integration branch.

R4Y decision: the first controlled experiment is to disable only the cross-half Wave64 console-flow fallback, not all Wave64 or all guest barriers. If that does not change the failure, investigate in-half split-Wave64 dispatches and other GPU queue progress paths next.

## Current R4Y diagnosis and code state (2026-11-25)

### Runtime evidence

From the user's crash index:

- Several earlier runs ended as `HOST_GPU_FAILURE`. PID 34964 (2026-11-24 22:32:28 local) contains a D3D12 debug-layer rejection of `ALLOW_UNORDERED_ACCESS` on `B5G5R5A1_UNORM`, followed by `0x887A0001` (`DXGI_ERROR_INVALID_CALL`). This matches VIctory #2258 / PR #2286.
- Other older GPU-removal reports include `0x887A0006` (`DXGI_ERROR_DEVICE_HUNG`) after submissions of 28–33 command lists. These are distinct from the invalid format/flag query.
- PID 20352 (2026-11-25 06:37:38 local) reports `0xc0000005` writing to `0x0` at `r4y-image-...dll+0x23cf683`. The XCL reports explain the same title offset as the title's GPU-progress watchdog failure path. Treat it as evidence that the title did not observe GPU progress; do not label it the root memory fault without new disassembly/runtime evidence.
- The current `r4y-run.log` contained no explicit `R4Y: host GPU failure` or `0x887A0006` record in that run. It did contain `slow host submission ms=5572 lists=9` at 06:37:22 local, 16 seconds before the watchdog report.
- In `Host::execute`, this 5572 ms is wall time from the post-preparation timestamp through `ExecuteCommandLists`, queue `Signal`, fence `SetEventOnCompletion` and `WaitForSingleObject(INFINITE)`. Thus the nine-list submission's fence completed after roughly 5.572 seconds. It is not merely a CPU-side preparation number and is not, by itself, proof of device removal or of one specific shader being responsible. In the ordinary non-per-list-timing path, all lists are in one submission group.

### Wave64 path to isolate

R4Y's `lower.rs` `console_cf` fallback translates a single console Wave64 group on a Wave32-only host by following console control flow, tracking per-instruction EXEC, and exchanging two dwords through group-shared memory with two group barriers. This is distinct from `R4Y_GROUP_SYNC`, which affects translated guest `s_barrier` instructions; changing `R4Y_GROUP_SYNC` does not disable the built-in cross-half exchange barriers.

Added diagnostic setting:

- `R4Y_WAVE64_CONSOLE_FLOW=0`: disable only the cross-half console-flow retry. Shaders that require it are refused; in-half DPP/swizzle/MBCNT split-Wave64 paths remain enabled. Default is enabled.
- The setting is part of the shader cache fingerprint, so enabled and disabled runs do not reuse the same translated entries.
- The parser and refusal path have unit tests, but the new tests have not yet been run in CI or locally at the time of this handoff.

PowerShell A/B (set before process startup):

```powershell
# Baseline/default behavior
Remove-Item Env:R4Y_WAVE64_CONSOLE_FLOW -ErrorAction SilentlyContinue
.4y-run.cmd

# Separate diagnostic run: refuse only cross-half console-flow shaders
$env:R4Y_WAVE64_CONSOLE_FLOW = "0"
.4y-run.cmd
```

The disabled run may lose rendering/features because affected shaders are intentionally refused. It is an isolation experiment, not a user-facing recommended setting. Record each run's timestamp, crash PID/type, newest refusal hashes/reasons, and whether the GPU-progress watchdog still fires. Restore default with `Remove-Item Env:R4Y_WAVE64_CONSOLE_FLOW`.

### CI and test status

- Latest branch head at this handoff update: `b194221a932443984d05b24752aba195bb7b7570` (`feature/wave64-host-target`).
- Audit commits: `65ba0b3` (shared texture allocation query), `706179e` (pipeline worker stack), `173e409` (Wave64 console-flow diagnostic switch), `ae94e81` (cache fingerprint), `b194221` (test import cleanup).
- Existing RTX 3070 test from the earlier handoff proves a synthetic set of Wave64 lane/DPP/ballot/MBCNT/cross-half/branch/loop assertions passed on that adapter. It does not prove the title's real HBO or other long-running compute shaders are safe.
- The last observed green CI run before these audit commits was PR #16 run #165, on the earlier head `a24552a`. No green run for `b194221` was confirmed in this audit; the new changes remain unvalidated by CI and need `cargo test -p r4y-shader --locked`, workspace tests, Clippy, diagnostics/release builds and the real RTX 3070 run.
- PR [#16](https://github.com/cmyk-ux/r4y/pull/16) remains open. Do not merge until CI on the current head and the real-title regression run are checked.

## Next steps

1. Pull `feature/wave64-host-target`, inspect the resulting HEAD, run formatting, shader tests, full workspace tests, Clippy and release/diagnostics builds. Check GitHub Actions again for the exact current head.
2. Run the default title case and the `R4Y_WAVE64_CONSOLE_FLOW=0` A/B on the RTX 3070. Compare the exact pipeline refusals and whether the title watchdog/device-removal event remains.
3. If disabling console-flow removes the hang, instrument/refine the cross-half exchange/control-flow path and add a regression around divergent-loop ballot/exchange. Do not simply disable it permanently.
4. If the hang remains, isolate in-half split-Wave64 compute separately and add per-shader diagnostic refusal/reporting before attempting an algorithmic rewrite.
5. Only after the GPU progress path is understood, revisit memory/streaming hypotheses (commit pressure, card-buffer policies, DirectStorage, XMem aliases) and port APU allocation telemetry if there is evidence of allocator refusal.
6. Return to descriptor virtualization and high logical title descriptor slots after the immediate hang path is isolated.

## Session-start rule

At the start of future R4Y work, read both `.agent/SESSION_HANDOFF.md` and this file. Check the branch/head and CI, then review relevant upstream commits, issues and PRs using the priority order at the top. Do not ask the user to repeat the watchlist or to restate conclusions already recorded here. Update the audit date and findings whenever a reference changes the diagnosis, implementation or test plan.


## Supplemental reference — Belobug/VIctory-Belobug-AMD (2026-11-25)

This does **not** change the owner's standing priority order above. It is an additional reference because it contains recent AMD-specific shader semantics, indirect-execution redesign and diagnostics that overlap R4Y.

- Fork: https://github.com/Belobug/VIctory-Belobug-AMD
- Audited head: `4cbe9d76cf3c1fdca7f9a8d8364eacc33e7aa597`
- Its README reports world rendering on one RX 9070 XT at 3–5 FPS, but not playable; moving vehicles are broken, RT indirect lighting is replaced with a constant, and some compute programs are dropped. It has no reported NVIDIA/Intel test.
- The highest-value R4Y candidate is the change to indirect clamping: separate read-only source arguments from a scratch output, respect `min(max,count)`, use bounded/saturating budget accounting, and (after correctness is proven) hoist clamps for a run of draws with producer-write tracking. R4Y currently modifies the title argument shadow in-place and does not pass the optional count into its clamp helper. See .agent/VICTORY_AMD_FORK_AUDIT.md before changing this subsystem.
- The other focused candidate is helper-lane semantics in pixel shaders: all quad-local reads may need quad reads, while `v_readfirstlane_b32` may need to return a helper lane's own value in a waterfall. R4Y's current quad predicate is narrower (requires a discard); its readfirstlane lowering lacks the fork's helper special-case. AMD-originated behavior must be proven with DXIL/WARP and RTX 3070 fixtures before changing R4Y.
- Do not port the fork wholesale or copy its visual workarounds (constant ambient light, static no-wind tree shaders) as general fixes. Its timing claims are self-reported for one AMD workload.
- PortWatch methodology page: https://portwatch-vi.xyz/#method. Tracker snapshot last refreshed `2026-11-25T10:22:39.836Z` did not contain the repository name or owner; do not claim the fork is scored/listed there.

Detailed code comparison, upstream commit links, test plan and evidence limits: .agent/VICTORY_AMD_FORK_AUDIT.md.
