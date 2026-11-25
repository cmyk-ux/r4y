# R4Y — Assistant Session Handoff

> Operational project memory for continuing work across ChatGPT conversations.
> Read this file at the beginning of a new session before asking the user to repeat context.
> Update it after meaningful code changes, experiments, CI results, or architectural decisions.
>
> **Visibility:** this file is committed to the repository. It is not private or access-controlled; anyone with repository access can read it.

Last updated: 2026-11-25 (America/Sao_Paulo); PR #16 console-flow implementation and CI #123 recorded
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

Observed in the user's 2026-11-25 diagnostics run:
- `Shader wants wave lane count of 64 but maximum wave lane count for device is 32`: 161 debug-layer messages.
- `host pipeline refused`: 136 messages, with HRESULT `0x80070057`.
- Dropped/refused compute shader hashes:
  - `13dfdd3b1136e407`
  - `88994c3496045f51`
- The log also contained intermittent black-frame warnings; do not automatically attribute all of them to Wave64.

Active implementation:
- PR #16: https://github.com/cmyk-ux/r4y/pull/16
- Branch: `feature/wave64-host-target`
- Latest code/test commit at this handoff update: `f82f97dc1fc8207fc2b2e40ca5a7128a8feddf88`
- Latest successful CI: run #123 — https://github.com/cmyk-ux/r4y/actions/runs/45568252909
- PR title: **Add host-aware Wave64 split and console-flow translation**. Keep the PR open until the user's RTX 3070 dispatch test and GTA VI runtime comparison have been completed.

Implemented on the branch:
1. Host-aware target and cache:
   - `crates/r4y-gpu/src/host.rs` queries D3D12 OPTIONS1 for WaveOps and the supported lane range.
   - Production uses `Target::NONE` if capability discovery fails; it does not assume a shader can use Wave32/64.
   - `crates/r4y-shader/src/emit/mod.rs` adds `Target`, `translate_for`, and `emit_for`; the old APIs remain compatibility wrappers.
   - `crates/r4y-gpu/src/shader_cache.rs` fingerprints the host wave range so DXIL from one adapter cannot be reused on an incompatible adapter.
2. In-half split:
   - Wave64 DPP and `ds_swizzle` programs whose lane references stay within each 32-lane half can be emitted as Wave32.
   - Console flattened thread IDs and DPP row-mask indexing are preserved for the upper half.
   - This path is conservative: no native LDS, cross-half operations, mask-as-data, whole-wave sections or unsupported lane instructions.
3. Console-flow split:
   - When the in-half path is insufficient, the lowerer may retry with `structure::structure_console` for exactly one console Wave64 group per thread group (at most 64 threads).
   - Every vector instruction retains its per-lane EXEC guard; scalar/wave operations and synchronization are reached by all physical lanes.
   - Branches on EXEC/VCC/SCC use a wave-wide any-lane decision, so the two host Wave32 halves follow the same branch and loop.
   - Cross-half reads and mask values are exchanged via two group-shared dwords with barriers before and after the read.
   - Lowering covers cross-half `v_readlane`, `v_readfirstlane`, `v_writelane`, `v_mbcnt`, ballot/mask operations, and selected EXEC/VCC/SCC branch forms.
   - A `v_readfirstlane` used only to restore a descriptor in the existing waterfall path remains a per-lane restoration; it does not trigger a real whole-wave read.
   - Path-dependent per-lane descriptor `LanePhi` values are explicitly refused in console flow.
4. Tests:
   - GPU-independent translation tests cover the target-specific PSV WaveSize, cross-half readlane, standalone readfirstlane, multi-wave refusal, mask count, mbcnt, divergent branch and divergent-loop translation.
   - `crates/r4y-shader/src/emit/split_tests.rs` contains a D3D12 lane-by-lane dispatch test named `wave64_split_matches_console_on_d3d12_hardware`.
   - On a Wave32 adapter it checks in-half DPP/swizzle for 32/64/128 threads, partial DPP row masks, mask ballot/count, `v_mbcnt_lo`, cross-half readlane, branch where only one half has active lanes, readfirstlane, saveexec/SCC, and a loop with per-lane iteration counts that reads lane 40.
   - CI workflow runs this test separately and prints the reason if the hosted adapter cannot execute it.

Deliberate limitations:
- Console flow is only for one console Wave64 per group (at most 64 threads).
- No native LDS accesses, `ds_bpermute`/other permute operations, whole-wave reduction sections, multi-console-wave groups, or general LDS behavior.
- Only the modeled SCC/VCC/EXEC zero/nonzero branch forms are supported. Unsupported forms remain refused; they must not be silently emitted.
- The hosted GitHub runner does not expose a usable Wave32 or Wave64 capability, so a successful test process is not evidence of a D3D12 dispatch.

Validation, CI run #123 on commit `f82f97d`:
- PowerShell/MSVC checks: pass.
- Clippy, normal and all-features: pass.
- Release build: pass.
- Workspace tests: **212 passed, 0 failed, 2 ignored, 3 filtered out**.
- Dedicated D3D12 test command: test process passed, but its body explicitly skipped with `adapter supports neither 32- nor 64-lane waves; skipped`.
- Therefore the code and translation regressions are CI-validated; the Wave32 GPU dispatch and runtime behavior are **not yet hardware-validated**.

Next actions:
1. On the user's RTX 3070 checkout, run:
   ```powershell
   cd C:\Users\dysu\Downloads\r4y\r4y
   git fetch origin feature/wave64-host-target
   git switch feature/wave64-host-target
   cargo test -p r4y-shader --locked wave64_split_matches_console_on_d3d12_hardware -- --show-output
   ```
   If the checkout path differs, use the actual local R4Y root. Expected startup capability is `lanes_min=32 lanes_max=32`; the test must execute (not skip) and match the expected per-lane output for every in-half and console-flow kernel.
2. If that test passes, build `cargo build --release --locked -p r4y`, run GTA VI with focused diagnostics, and compare previously refused hashes `13dfdd3b1136e407` and `88994c3496045f51`. Separate pipelines fixed by this work from patterns still refused by the deliberate limitations.
3. If the RTX dispatch test fails, preserve the failing kernel/assertion and fix that exact semantic issue before expanding support.
4. Then resume the slot-zero SRV Texture1D/Texture2D provenance investigation and issue #4 descriptor virtualization. Do not confuse the Wave64 work with either descriptor issue.

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
