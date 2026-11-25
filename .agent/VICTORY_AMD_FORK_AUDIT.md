# Supplemental audit: Belobug's AMD VIctory fork

Audit date: 2026-11-25 (America/Sao_Paulo)  
Repository: https://github.com/Belobug/VIctory-Belobug-AMD  
Audited branch: `main`  
Audited head: `4cbe9d76cf3c1fdca7f9a8d8364eacc33e7aa597`  
README says its upstream base is VIctory commit `8e79c80` (2026-11-24). The repository comparison reports 492 commits ahead of that base. This is a substantial derivative, not a small patch series to merge wholesale.

## Executive assessment

The fork is an unusually useful engineering reference because it publishes concrete symptoms, the hardware used, diagnostics and recent code changes. Its README reports that it renders the game world with lighting (apart from indirect ray-traced light), textures, people, vehicles, vegetation, water and sky on one Windows 11 / RX 9070 XT machine. It is still explicitly **not playable**: about 3–5 FPS, moving vehicles are visibly broken, distant trees are missing, ray-traced indirect light is replaced by a constant, some compute programs are dropped, and one driver timeout occurred. The README says it has not been tested on NVIDIA or Intel.

Treat it as a source of hypotheses, semantic fixes and instrumentation—not as evidence that the same behavior works on R4Y's NVIDIA RTX 3070. No code from this fork was copied into R4Y in this audit.

## PortWatch interpretation

PortWatch's current methodology is a milestone ladder to 50%: groundwork 10%, executable runs 10%, first frame 20%, main menu 30%, world loaded and rendered 40%, and actually controlling a character 50%. The four post-playability tracks (story, rendering, performance, stability) only count once a build is playable. A world that renders but is not controllable belongs at the world milestone, not at a high gameplay-quality score.

The current tracker data was refreshed at `2026-11-25T10:22:39.836Z`. Searches of that snapshot found neither `Belobug` nor `VIctory-Belobug-AMD`; do not describe this fork as already ranked or assigned an official PortWatch score. Its self-reported README status is compatible with the meaning of the "world" milestone, but the fork is not present in the captured tracker data.

Sources:
- PortWatch methodology: https://portwatch-vi.xyz/#method
- Tracker snapshot: https://portwatch-vi.xyz/data/tracker.json
- Fork status and machine: https://github.com/Belobug/VIctory-Belobug-AMD/blob/main/README.md

## Candidate A — indirect argument clamping: high-priority R4Y investigation

### What the fork changed

The fork's `crates/victory-gpu/src/indirect.rs` redesign separates source arguments from clamped arguments:

- `src_args` is read-only input; `dst_args` is a separate device-local scratch output.
- The optional count buffer is read by the clamp shader. It processes `min(records, count)`, not every record up to the API maximum.
- Clamped records are copied into scratch; D3D12 `ExecuteIndirect` consumes that scratch buffer. The original title argument buffer is not rewritten by the helper clamp.
- The per-list work budget is updated with a bounded compare-exchange loop (up to 256 attempts), and saturating logic avoids 32-bit wraparound. A record that cannot safely charge the budget is made empty.
- Scratch is chunked (256 KiB in the reviewed implementation), with explicit UAV/indirect state transitions and resource lifetime retention.

Relevant source: https://github.com/Belobug/VIctory-Belobug-AMD/blob/main/crates/victory-gpu/src/indirect.rs

### What R4Y does today

At the audited R4Y feature head, `crates/r4y-gpu/src/indirect.rs` still binds the original host shadow argument buffer as the clamp shader's UAV and performs `Store` operations into it. `crates/r4y-gpu/src/draw.rs::State::execute_indirect` then executes from the same `args.buffer` and offset.

R4Y passes the optional count buffer to D3D12 `ExecuteIndirect`, but the helper clamp is called with only `(kind, stride, max)`; its HLSL does not read the count buffer and can clamp records beyond the actual count. This is distinct from D3D12's later count limit: the helper's own work and mutations happen before ExecuteIndirect consumes the limited number of records.

This is a correctness concern as well as a performance concern: the helper mutates the title-visible shadow copy of the argument buffer. Even if a particular title does not observe that mutation, preserving the input and clamping only a private output is the safer contract.

### Clamp hoisting and ordering

The fork additionally moves clamps for a run of indirect draws into a separate command list that executes before the draw list, avoiding one helper dispatch and its barriers between each draw. Its commit message reports a workload with roughly 9,300 indirect draws per frame where helper clamps and barriers accounted for about 190 ms out of 225 ms GPU time. The early hoisting experiment reported 225→72 ms; the later README reports about 225→80 ms in a heavy scene. These are fork-reported, workload-specific measurements, not reproduced R4Y results and not one interchangeable benchmark.

The difficult part is preserving ordering. A pre-clamp is only valid while the source argument and count buffers have not been written since the clamp list was planned. The fork tracks a per-list write counter and records the counter when the hoisted run begins; if another dispatch/copy writes in between, it falls back to an inline clamp. It retains the prelude list with the consuming list, closes it at the run boundary, and transitions its scratch chunks from UAV to indirect-argument state.

The fork first tried modes that could run clamps in parallel / with weaker sequencing. It later made mode 7 the default: execute clamps one after another with a barrier between them. The commit says this was needed because whole mesh objects (leaves, chairs, clothes) flickered when output records were not stable frame-to-frame. Do not port the earlier aggressive mode as the default. The mode and the observed visual regression are a warning that allocator/budget races can look like missing geometry rather than a clear GPU error.

Relevant commits:
- Clamp scratch/count/budget and pre-list hoisting: https://github.com/Belobug/VIctory-Belobug-AMD/commit/ccab9730bcfe5d42be2cb85e338be80591b0e3ab
- Sequential mode 7 made default after flicker: https://github.com/Belobug/VIctory-Belobug-AMD/commit/76387c2dea079eb1d31f80402471cb4f55b34d2b

### Recommended R4Y sequence

1. First write D3D12/WARP-capable tests for clamp semantics: input buffer unchanged; output matches the original records except documented safety clamps; count values 0, 1, less than max and equal to max; source/count writes preceding the clamp are visible; output is correctly transitioned for indirect execution; budget arithmetic cannot wrap.
2. Refactor the clamp to accept separate source and destination resources and the optional count buffer. Ensure the destination has a clear lifetime through ExecuteIndirect and is returned to a reusable per-list scratch allocator only after the list has finished.
3. Verify draws, indexed draws, dispatch and mesh argument formats separately, including record strides larger than their minimum structures.
4. Only after scratch clamping is correct, consider grouping a run of draws. Model dependency invalidation explicitly: any GPU write that can affect an argument/count buffer must end the hoist window. Include a conservative sequential mode with explicit ordering barriers; do not assume that "same command list" means the source arguments are final.
5. Measure with per-command GPU timestamps on the RTX 3070. Separate helper-clamp time, title dispatches, resource copies, draw/dispatch work and queue/fence wait. Do not infer a frame-time win from CPU recording time alone.

PortWatch / fork performance numbers justify investigation, not a blind port. The R4Y submission and HostList state/lifetime model differs from the newer fork and must be reconciled in R4Y-native code.

## Candidate B — pixel helper-lane and quad semantics: targeted shader investigation

### Changes in the fork

Two commits identify distinct cases:

- `f520772` adds a helper-lane special case to `v_readfirstlane_b32`: in a pixel shader, a helper lane uses its own source value instead of the result of `WaveReadLaneFirst`. The commit describes a waterfall descriptor loop in which host wave operations leave helper lanes out; when only helpers remain, the wave read returns no useful matching lane, so those lanes may use an arbitrary descriptor and run until the loop limit. The helper lane's own value lets it match/leave on the first pass. Its computation can still matter to derivative-dependent texture coordinates, although stores from helpers are dropped.
- `03629f3` broadens quad-local cross-lane reads in pixel shaders to use quad reads even when no explicit discard exists. The fork reports that wave reads returned zero from helper pixels in its AMD driver, corrupting a manually calculated quad derivative at triangle edges and causing visible lines on car paint, glass and skin.

Relevant commits:
- https://github.com/Belobug/VIctory-Belobug-AMD/commit/f520772bd1675f7d4bc6397bdb84d5ddfb6b6d76
- https://github.com/Belobug/VIctory-Belobug-AMD/commit/03629f3f0d3f3329052e05084440aeee75ce3107

### R4Y comparison

R4Y already has `quad_pick` implemented with `quadReadLaneAt`. Its current `helpers_read(quad)` predicate is narrower: `quad && pixel && !discards.is_empty()`. Therefore quad-local operations use the helper-aware path only if the shader has at least one discard. The current `v_readfirstlane_b32` lowering has no `isHelperLane` override; the source contains no equivalent of the fork's `helper_reads_own` helper.

R4Y's `quad_gradients` has its own direct pixel-shader quad-read path, so the difference is not that all gradient code uses wave reads. Audit each call site rather than changing the predicate globally and assuming every quad read is affected.

### Recommended R4Y sequence

- Add minimal shader fixtures that distinguish a pixel shader with no discard from one with discard and test DPP/swizzle/quad reads at helper-lane boundaries.
- Add a focused `v_readfirstlane_b32` waterfall fixture where only helper lanes remain after real lanes exit; verify loop termination and the selected descriptor.
- Validate generated DXIL with the DXIL validator, WARP, then the actual RTX 3070. Check the relevant DXIL operation/intrinsic and the documented helper-lane behavior for the SM version in use before using `isHelperLane` in R4Y.
- Keep any change scoped to pixel/helper-lane semantics; do not perturb compute Wave64 split paths while testing this.

This looks like a shader semantic difference worth testing, but the motivating failure was observed on AMD. Do not assume the same exact failure or workaround is required by NVIDIA.

## Candidate C — diagnostics and iteration workflow

Useful ideas that are not AMD-only:

- Per-command GPU timestamp aggregation by operation kind and pipeline. The fork's diagnostics aggregate per-command timestamp deltas and divide by frames presented, rather than reporting only total list submission time.
- Target-memory peeking: the fork can read a selected address/range into a file, then use the texture-layout code to detile a captured texture with a small test. This is a useful pattern for data-driven debugging, but should be exposed only through explicit diagnostics settings and bounded reads.
- Shader patch/swap controls: the fork supports diagnostic machine-word patches and shader-container replacement from files. These are powerful isolation tools; any patch must be part of the shader cache identity and every output should record the exact container hash, offset and changed bits. Do not expose these as normal runtime behavior.

R4Y already has diagnostics timestamps and frame/command markers, so first compare and extend the current implementation rather than copying a second timing subsystem.

## Workarounds not to transplant as general fixes

- Constant ambient light replaces a ray-tracing resolve output while ray passes are unavailable. It improves the picture but is a deliberate visual approximation, not ray-tracing support or a portable rendering fix. Commit: https://github.com/Belobug/VIctory-Belobug-AMD/commit/4f45ab88f8619affdfc06b0e1d0d2280f14c2eb2
- Shader swap to use static distant-tree variants instead of wind variants makes those trees appear, but removes the intended wind behavior and bypasses unimplemented compute. Commit: https://github.com/Belobug/VIctory-Belobug-AMD/commit/cf62e1aeaa69b17eb5b40ac1117badec94f0286c
- Fork-specific driver robustness: isolating shader/PSO compiler failures and using host-side descriptor metadata to avoid a driver-crashing size query may be AMD-specific. Reproduce the exact failure on the RTX 3070 before importing it.
- Doubling dynamic descriptor slots is a capacity workaround, not descriptor virtualization. It does not prove that the high logical title heap indices are preserved on an NVIDIA adapter.

## Audit disposition

| Area | R4Y disposition |
|---|---|
| Indirect clamp writes original args and ignores count during pre-clamp | **Investigate first; correctness tests before optimization** |
| Scratch output for clamped arguments | Strong architectural candidate; adapt to R4Y HostList/resource lifetimes |
| Clamp hoisting | Defer until scratch clamp is correct; track producer writes and use conservative sequential barriers |
| Helper-lane quad reads | Add pixel-shader fixtures; compare no-discard vs discard cases |
| Helper-lane `v_readfirstlane` | Add waterfall test and verify DXIL helper-lane semantics before implementation |
| Per-command GPU timing | Compare/extend R4Y's existing timestamps |
| Ambient constant / tree shader swap | Diagnostics/workarounds only; never call these full fixes |
| Whole fork cherry-pick | **Do not do** |

## Evidence limits

- The README status is self-reported by the fork and tested on one RX 9070 XT system.
- The reported FPS and GPU timing values are not independently reproduced here.
- No claim is made about NVIDIA/Intel compatibility.
- This audit is a code/repository comparison, not a runtime test of the AMD fork.
- No production code change was made in R4Y as a result of this audit.
