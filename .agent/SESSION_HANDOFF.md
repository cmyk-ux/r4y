# R4Y — Assistant Session Handoff

> Operational project memory for continuing work across ChatGPT conversations.
> Read this file at the beginning of a new session before asking the user to repeat context.
> Update it after meaningful code changes, experiments, CI results, or architectural decisions.
>
> **Visibility:** this file is committed to the repository. It is not private or access-controlled; anyone with repository access can read it.

Last updated: 2026-11-25 (America/Sao_Paulo); PR #16 Wave64 work in progress
Repository: https://github.com/cmyk-ux/r4y
Primary checkout used by the user: `C:\Users\dysu\Downloads\r4y\r4y`
Current investigation: GTA VI runtime on NVIDIA GeForce RTX 3070 / D3D12.

---

## 1. Working agreement with the user

- The user is technically engaged and strong at system-level reasoning, but does not identify as a programmer. Prefer implementing/auditing directly through repository tools when possible; when local execution is required, provide a complete PowerShell command rather than asking the user to hand-edit code.
- Do not ask questions that the conversation or repository already answers. The user has explicitly authorized broad repository changes and prefers progress over repeated basic checks.
- Be rigorous: separate observed facts, likely causes, and hypotheses. Do not declare a bug fixed merely because CI passes or a warning disappears.
- Avoid excessive verification loops and unnecessary requests for more logs. Gather the smallest missing evidence and act.
- The user wants deep technical analysis but benefits from a compact final section with current status and the next concrete action.
- The current GitHub repo is the consolidated R4Y codebase. Do not reintroduce a second runtime or an installer that clones VIctory/XCL as a parallel implementation.

## 2. Project identity and architecture

R4Y is a consolidated Windows D3D12 runtime derived from VIctory. The repository was created to hold the runtime, HLE, shader translation, GPU backend, installer, tests and CI in one workspace.

Useful architectural landmarks:
- `crates/r4y-gpu/src/descriptor.rs`: title-side descriptor bookkeeping and the `View` model.
- `crates/r4y-gpu/src/descriptor/host.rs`: host D3D12 descriptor heaps, mirroring, null views, transient descriptor allocation and capped-heap fallback.
- `crates/r4y-gpu/src/host.rs`: D3D12 device creation, feature initialization, diagnostics/debug layer and deferred GPU work.
- `crates/r4y-gpu/src/draw.rs`: command-list state, translated pipeline binding, descriptor heaps/root signatures and draw preparation.
- `crates/r4y-shader/src/emit/lower.rs`: console shader lowering to host DXIL, including wave-sensitive operations.
- `crates/r4y-shader/src/emit/host.rs`: host-side D3D12 shader capability probes.
- `docs/SOURCE_MAP.md`: provenance and integration map, if present in the current checkout.
- `apps/r4y` and `scripts/install.ps1`: public CLI and installer.

The user builds/runs locally on Windows from the checkout above. Runtime logs are under:
`$env:LOCALAPPDATA\R4Y\logs\r4y-run.log`

## 3. Recent repository work already present on main

The following changes were inspected as merged into `cmyk-ux/r4y` main during this investigation. Do not redo them without new evidence:

- PR #5: rate-limit repetitive high-water warnings for descriptors beyond the mirrored prefix. This reduces log spam, not the functional mapping limitation.
- PR #6: fix contiguous dynamic descriptor allocation across the search cursor; includes exhaustive small-heap regression tests.
- PR #8: safe fallback for NVIDIA-capped view heaps; disjoint title/dynamic/pair/null regions and shader-side safe handling. This is **not complete descriptor virtualization**.
- PR #13: restore/rebind descriptor heaps and the appropriate root signature after internal depth-twin operations. Its description explicitly says it does not solve the Texture2D-vs-Texture1D report.
- PR #14: rebind descriptor heaps before switching translated root signatures.
- PR #15: diagnostics for concrete descriptor heap pointers and root-signature bindings.
- PR #12 adds opt-in divergent group-barrier protection; inspect its current main status and behavior before relying on it.

Relevant repository records:
- Issue #4 — https://github.com/cmyk-ux/r4y/issues/4
- PR #8 — https://github.com/cmyk-ux/r4y/pull/8
- PR #13 — https://github.com/cmyk-ux/r4y/pull/13
- PR #14 — https://github.com/cmyk-ux/r4y/pull/14
- PR #15 — https://github.com/cmyk-ux/r4y/pull/15

## 4. Active runtime findings (2026-11-25)

The user ran a diagnostics build with D3D12 GPU-Based Validation. Relevant log:
`%LOCALAPPDATA%\R4Y\logs\r4y-run.log`

### 4.1 NVIDIA view heap is capped; current fallback loses title descriptors

Observed:
- Title requests 1,245,184 view descriptors.
- Host accepts 1,000,000 shader-visible view descriptors (the D3D12 device/debug-layer cap shown in the log).
- R4Y selected this layout:
  - mirrored title prefix: 721,469
  - dynamic transient slots: 262,144
  - persistent copy pairs: 16,384
  - final null/sentinel slots: 3
  - total: 1,000,000
- Runtime warning at log line 256:
  `requested_title_slots=1245184 mirrored_title_slots=721469 dynamic_slots=262144`.
- High-water warnings start at index 721,469 and then advance in 4,096-slot intervals. The final displayed index is 1,241,088 (the logical title heap requested is 1,245,184).
- These warnings all have `for_draw=false`.

Interpretation:
- The game iterates/writes or otherwise touches descriptor records across the high logical range; the log is not evidence that every high descriptor is actually consumed by a draw.
- The `HostHeap::mirror()` implementation returns early when `index >= self.count`; it does not preserve/remap these title descriptors.
- The existing capped fallback is a bounds/aliasing safety fallback, not full virtualization. The issue description also identifies raw descriptor copies and direct heap-index translation as requirements for a correct solution.
- Do not fix this by simply increasing `count`: that would overlap reserved dynamic/persistent ranges or exceed the physical hardware heap limit.
- Do not suppress warnings as a substitute for solving the descriptor semantics.

Issue #4 tracks the full problem and has remained open in the inspected state:
https://github.com/cmyk-ux/r4y/issues/4

Next engineering task:
Design and implement real logical-title-index to physical-host-slot virtualization (or prove a smaller safe range is sufficient from runtime usage). Preserve high descriptors, avoid aliasing dynamic and persistent allocations, cover raw descriptor copies, and make generated shader indexing use the same mapping. Add pure mapping/allocator tests plus runtime tests on NVIDIA. Do not claim the whole heap is fixed until direct heap reads and copied descriptor writes are covered.

### 4.2 Slot-zero SRV dimension mismatch

Four GPU-Based Validation warnings at log lines 4441, 4576, 4605 and 4609:
- Shader expects `D3D12_SRV_DIMENSION_TEXTURE2D`.
- The descriptor at view-heap index 0 is `D3D12_SRV_DIMENSION_TEXTURE1D`.
- Stage is PIXEL.
- PSO hashes:
  - mesh `d4111a6e6ea49d91`, pixel `c0a7fe77b1862e10`
  - vertex `089d6271be6650ef`, pixel `fa455c8a3c32577b`
  - vertex `089d6271be6650ef`, pixel `280967ad158cee0b`
  - the final report repeats the latter PSO.

The diagnostic mirror records include two distinct slot-zero observations:
- A sampler-heap slot zero: `ConsoleSampler([...])` at line 255.
- A view-heap slot zero: `Shader(0, Some([42, 2, 5768, 0, 0, 0, 0, 0, 0, 0]))` at line 485, with `made=false`.

Important source path in current main:
1. `descriptor.rs::create_srv()` records `View::Shader(resource, desc)`.
2. `descriptor/host.rs::HostHeap::mirror()` tries `make(&view, ...)`.
3. For the logged view, the resource handle is 0 and creation returns `None`.
4. `null_for()` preserves the source descriptor's dimension through `null_like()`.
5. Dimension word `2` is translated to a null Texture1D view.
6. GPU-Based Validation sees that host heap index zero as Texture1D while the pixel shader expects Texture2D.

This makes the fallback path a confirmed part of the reproduction, but it does **not** yet establish the original logical cause. The host fallback appears to preserve the title descriptor's declared dimension; the mismatch may arise earlier from the title descriptor contents, stale/wrong descriptor slot, a mismatch between translated heap index and title slot, or shader expectations. Do not blindly change all null descriptors to Texture2D.

Next investigation:
- Establish whether shader heap index 0 is intended to be referenced by these pixel shaders and how their direct/bindless index is produced.
- Correlate the original descriptor write/copy history for title view slot 0 with the four PSOs and the traced draw.
- Compare the original descriptor's dimension and resource identity against the pixel shader's expected SRV type/register.
- Preserve typed null descriptors when type information is genuinely known; fix the source/index mapping if it is wrong.
- PR #13 explicitly did not claim to fix this report.

### 4.3 Wave64 compute pipelines rejected on a wave32 host

Observed in this run:
- `Shader wants wave lane count of 64 but maximum wave lane count for device is 32`: 161 debug-layer messages.
- `host pipeline refused`: 136 messages.
- `host pipeline refused` entries show HRESULT `0x80070057` (invalid parameter) alongside the wave-size debug-layer refusal.
- The current PowerShell regex attempt extracted zero hashes even though refusals exist; see the corrected extraction below.
- Summary lines explicitly show dropped compute pipelines:
  - `13dfdd3b1136e407`
  - `88994c3496045f51`
- Frame summary examples:
  - line 3837: 0.1 FPS, 8,500.2 ms/frame, 6 draws, 2 dropped without a host pipeline.
  - lines 3857–3858 identify one refused compute pipeline: `13dfdd3b1136e407`.
  - line 4462 identifies `88994c3496045f51` as refused.
  - lines 4460 and 4595 again mention `13dfdd3b1136e407`.
- The same run also has intermittent black-frame warnings; do not automatically attribute them all to wave64.

Current R4Y lowering inspected:
`crates/r4y-shader/src/emit/lower.rs` chooses `wave = 64` for native wave64 programs and assigns that size when console-lane semantics or one-wave LDS require it. The current translation path must be audited to ensure host wave capabilities are actually supplied to lowering and cache fingerprints before these pipelines are emitted.

Upstream research:
- VIctory PR #233 — https://github.com/Marvisak/VIctory/pull/233
- This proposes running suitable console wave64 compute programs as two host wave32 waves, with separate in-half and console-flow lowering, group-shared exchange, ballot/mask semantics, and host-specific shader cache keys.
- The inspected PR was open and marked non-mergeable/draft state was false at the time. It is not a drop-in patch: it has explicit limitations (e.g. some >64-thread cross-lane groups, LDS cases, whole-wave sections and cross-half permute operations) and has undergone continuing changes.
- R4Y diverged from upstream and has renamed crates/files. Rebase/port semantically, not mechanically.

Current implementation is in PR #16:
https://github.com/cmyk-ux/r4y/pull/16

Branch: `feature/wave64-host-target`
Latest commit at this handoff update: `b27b7354e9efe395040f9659a210411558d6d024`

Implemented on that branch:
- `crates/r4y-gpu/src/host.rs` queries D3D12 OPTIONS1 once at device initialization and stores the adapter's `WaveLaneCountMin/Max` in `Host::wave_target`.
- `crates/r4y-shader/src/emit/mod.rs` adds `Target`, `translate_for` and `emit_for`. Existing `translate`/`emit` APIs remain wrappers using `Target::ANY`.
- `crates/r4y-gpu/src/shader_cache.rs` includes the host wave range in the BLAKE3 cache fingerprint and translates using that same target.
- `crates/r4y-shader/src/emit/lower.rs` explicitly refuses a declared wave size unsupported by the host. It also has a conservative in-half wave64-to-wave32 split for compute shaders using DPP and/or `ds_swizzle`, where no LDS, whole-wave operation, mask-as-data, `v_readfirstlane`, or whole-wave section is present. It remaps DPP row-mask lookup for the upper 32 lanes and reconstructs console flattened thread IDs.
- `crates/r4y-shader/src/emit/mod.rs` adds GPU-independent tests for host wave range handling, refusal of cross-lane wave64 reads on a 32-lane host, native wave64 behavior on 32..64 targets, and DXIL WaveSize=32 for in-half splits.
- `crates/r4y-shader/src/emit/split_tests.rs` adds a D3D12 dispatch test. It compares every result against console lane order for 32/64/128 threads per group, plus a partial DPP row mask that distinguishes console rows 0/1 from rows 2/3. It skips only when no SM 6.6 D3D12 adapter or no usable wave32/wave64 range is available. The raw UAV test descriptor must be paired with `View::Pair` so the helper allocates both adjacent descriptors.

Deliberate current limitations:
- This is only the in-half subset. It does not implement upstream PR #233's broader console-flow path with group-shared cross-half exchange, ballots, and execution-mask emulation.
- Cross-half read/write-lane, permute, lane-mask-as-data, readfirstlane and LDS-sharing cases are not split; where they require wave64 they are refused on 32-lane hosts.
- The D3D12 lane-by-lane test has been added but has not yet been confirmed on the user's RTX 3070. Passing CI is not proof that the user's adapter executed it; inspect test output/skip reason.
- Last observed GitHub Actions run for this branch was run 85 on commit `b27b735`, still in progress at the time this handoff text was drafted. Check the latest run for the PR head rather than relying on this stale status.

Next engineering task:
1. Get a completed CI run on the current PR head; fix compile, Clippy or test failures before expanding scope.
2. Confirm the D3D12 lane-by-lane test actually runs on a wave32 adapter. On the user's RTX 3070, compare its output for IN_HALF and partial DPP row masks; do not treat a skipped test as validation.
3. Once the conservative split is correct, extend the implementation toward the upstream console-flow path only with explicit tests for cross-half lane reads, ballot/mask values, divergent branches and loop behavior. Preserve refusal for unsupported patterns.
4. Re-run the GTA VI diagnostics and compare the previously observed refused compute pipeline hashes. Distinguish fixed shader translations from unrelated failures.
5. Then resume the slot-zero SRV dimension investigation and issue #4 descriptor virtualization.

### 4.4 The failed hash extraction

The user used:
`shaders=\[compute\s+([0-9a-f]+)\]`
against the 136 lines and got zero results. Do not assume there were no compute hashes. First inspect raw matched lines and use a permissive parser. Suggested PowerShell:

```powershell
$hits = @(Select-String -LiteralPath $path -Pattern 'host pipeline refused')
$hits | Select-Object -First 12 | ForEach-Object { $_.Line }

$rows = @(
    foreach ($hit in $hits) {
        if ($hit.Line -match '(?i)shaders=.*?\[compute\s+([0-9a-f]{16})') {
            [PSCustomObject]@{ Hash = $Matches[1].ToLowerInvariant(); Line = $hit.LineNumber }
        }
    }
)
"refusals=$($hits.Count) extracted=$($rows.Count) unique=$(($rows.Hash | Sort-Object -Unique).Count)"
$rows | Group-Object Hash | Sort-Object Count -Descending |
    ForEach-Object { "$($_.Name) | $($_.Count)" }
```

If that still returns zero, print the first 12 raw lines and parse the exact current format rather than changing the evidence.

### 4.5 Additional validation/log facts

- The first D3D12 debug-layer warning says a sampler heap must be bound before setting a root signature with directly indexed samplers (line 149). PRs #13–#15 addressed heap rebinding paths and added pointer tracing; confirm whether this warning persists on a new run rather than reopening a fixed issue from an old log.
- GPU-Based Validation was enabled and warned that it substantially slows creation/rendering; do not treat the very low FPS in this diagnostics run as representative performance.
- The log shows 3,840x2,160 presentation.
- The log's four dimension warnings and wave64 refusals are separate issues and should be triaged separately.

## 5. Immediate priority order

1. Fix host-wave awareness and wave64 compute handling; it directly explains rejected pipelines and dropped dispatches.
2. Investigate slot-zero Texture1D/Texture2D mismatch with source-to-host descriptor provenance.
3. Design actual descriptor virtualization for the 1,245,184 logical title slots on a 1,000,000 physical NVIDIA heap; do not confuse warning-rate limiting/safe null clamping with preservation.
4. Re-run without GPU-Based Validation for representative performance, then perform focused GBV/DRED checks for correctness.
5. Keep issue/PR state and test evidence updated in this file.

## 6. How to resume in a new chat

User can say: **"Confira o arquivo .agent/SESSION_HANDOFF.md no repo cmyk-ux/r4y e continue."**

At session start:
1. Read this file from the current default branch.
2. Inspect the latest commits, open PRs/issues and current working branch before editing.
3. Check whether the findings above have been resolved or superseded by newer code.
4. Continue implementation; do not ask the user to re-explain the project.
5. Update this file when technical state changes, including commit/PR IDs, exact tests, limitations and next steps.

Do not put game assets, proprietary title data, shader dumps, keys, credentials, or machine-specific sensitive information in Git. The log hashes above are diagnostic shader identifiers supplied for this investigation; do not add shader binaries, disassembly, or title-derived material.
