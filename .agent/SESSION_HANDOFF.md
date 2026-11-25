# R4Y — Assistant Session Handoff

> Operational project memory for continuing work across ChatGPT conversations.
> Read this file at the beginning of a new session before asking the user to repeat context.
> Update it after meaningful code changes, experiments, CI results, or architectural decisions.
>
> **Visibility:** this file is committed to the repository. It is not private or access-controlled; anyone with repository access can read it.

Last updated: 2026-11-25 (America/Sao_Paulo); installer duplicate-tail fix committed to main and PR #16; CI #165 passed (hosted Wave64 step skipped)
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
- Original Wave64 implementation commit: `f82f97dc1fc8207fc2b2e40ca5a7128a8feddf88`
- RTX 3070 DPP test-oracle correction: `1455d18dc2c69c0c1c6acc3fca0bfe82fdb75728` (test-only)
- First MBCNT split-path attempt: `2f17b6f4986c815cedd96c0a27da5009551c1237` (incomplete: still matched by the whole-wave predicate)
- MBCNT classification correction: `e5e05a66dc06580998bfa341dd682da3e019ec4e` removes that contradictory whole-wave classification
- CI #139 for branch commit `9178e6e` completed successfully, including build, tests and the dedicated D3D12-test step; hosted-runner success does not establish a real Wave32 GPU dispatch
- Hardware fixture correction: `4cbc23f` changes the MBCNT result-copy instruction to read VGPR `v1`; `e92495c` applies the same correction to the translation-only fixture in `emit/mod.rs`
- PR title: **Add host-aware Wave64 split and console-flow translation**. Keep the PR open until the user's RTX 3070 dispatch test and GTA VI runtime comparison have been completed.

Implemented on the branch:
1. Host-aware target and cache:
   - `crates/r4y-gpu/src/host.rs` queries D3D12 OPTIONS1 for WaveOps and the supported lane range.
   - Production uses `Target::NONE` if capability discovery fails; it does not assume a shader can use Wave32/64.
   - `crates/r4y-shader/src/emit/mod.rs` adds `Target`, `translate_for`, and `emit_for`; the old APIs remain compatibility wrappers.
   - `crates/r4y-gpu/src/shader_cache.rs` fingerprints the host wave range so DXIL from one adapter cannot be reused on an incompatible adapter.
2. In-half split:
   - Wave64 DPP, `ds_swizzle`, and `v_mbcnt_lo/hi` with ordinary lane-local mask operands can be emitted as Wave32. These derive their result from the current lane's original console-wave index and do not require cross-half exchange.
   - Console flattened thread IDs and DPP row-mask indexing are preserved for the upper half.
   - This path is conservative: no native LDS, true cross-half reads, mask-as-data, whole-wave sections or unsupported lane instructions.
3. Console-flow split:
   - When the in-half path is insufficient, the lowerer may retry with `structure::structure_console` for exactly one console Wave64 group per thread group (at most 64 threads).
   - Every vector instruction retains its per-lane EXEC guard; scalar/wave operations and synchronization are reached by all physical lanes.
   - Branches on EXEC/VCC/SCC use a wave-wide any-lane decision, so the two host Wave32 halves follow the same branch and loop.
   - Cross-half reads and mask values are exchanged via two group-shared dwords with barriers before and after the read.
   - Lowering covers cross-half `v_readlane`, `v_readfirstlane`, `v_writelane`, MBCNT when its source is actual EXEC/VCC mask data, ballot/mask operations, and selected EXEC/VCC/SCC branch forms.
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
1. Pull the complete MBCNT classification correction (`e5e05a6`) into the user's checkout, confirm the exact HEAD, and rerun the D3D12 command on the RTX 3070. It must execute, not skip, and all MBCNT plus subsequent console-flow kernels must pass.
2. If the complete hardware test passes, build `cargo build --release --locked -p r4y`, run GTA VI with focused diagnostics, and compare previously refused hashes `13dfdd3b1136e407` and `88994c3496045f51`. Separate pipelines fixed by this work from patterns still refused by the deliberate limitations.
3. If another hardware assertion fails, preserve the exact kernel/assertion and diagnose its semantics before expanding support.
4. Then resume the slot-zero SRV Texture1D/Texture2D provenance investigation and issue #4 descriptor virtualization. Do not confuse the Wave64 work with either descriptor issue.

RTX 3070 hardware result (2026-11-25):
- On the user's latest pre-fixture-fix run, in-half DPP/swizzle lane-order dispatch passed for 64, 128 and 32 threads; DPP row masks passed for 64 and 128 threads.
- The MBCNT assertion at line 290 returned 64 zeros then 64 ones. This was traced to a **test fixture encoding error**, not yet to production MBCNT lowering:
  - `0xD765_0001 / 0x0001_00C1` correctly writes `v1` from `v_mbcnt_lo_u32_b32`.
  - The following `0x7E04_0201` decodes its source field as scalar `s1` (source code `0x001`), which is the dispatch group ID in this harness. It does **not** read VGPR `v1`.
  - Correct VOP1 source code for VGPR `v1` is `0x101`, so the instruction must be `0x7E04_0301`. This matches the observed output exactly: group 0 wrote zeros and group 1 wrote ones.
- Commits `4cbc23f` and `e92495c` fix both copies of this fixture in `emit/split_tests.rs` and `emit/mod.rs`. No production lowering change was made for this particular failure.
- Expected MBCNT semantics remain 0..31 then 32 for lanes 32..63 when S0=-1 and S1=0 (AMD RDNA2 ISA reference: https://www.amd.com/content/dam/amd/en/documents/radeon-tech-docs/instruction-set-architectures/rdna2-shader-instruction-set-architecture.pdf).
- CI #139 for `9178e6e` completed green. The corrected fixture commits are newer and need their own CI run. Actual RTX 3070 validation of MBCNT and the subsequent mask-ballot/cross-half/branch/loop assertions remains pending.

On the user's checkout, run:
```powershell
git pull --ff-only origin feature/wave64-host-target
git rev-parse --short HEAD
cargo test -p r4y-shader --locked wave64_split_matches_console_on_d3d12_hardware -- --show-output
```
Expected HEAD: `24d1f7e` or a newer descendant.
Latest RTX 3070 hardware validation (2026-11-25; user ran the full test on branch commit `071dce4`):
- Command: `cargo test -p r4y-shader --locked wave64_split_matches_console_on_d3d12_hardware -- --show-output`
- Result: `1 passed; 0 failed; 0 ignored; 0 measured; 216 filtered out`, finished in 0.66s.
- The test explicitly reported `split wave64: true` for 64-, 128-, and 32-thread lane-order cases, confirming the RTX 3070 exercised the Wave64-to-Wave32 path.
- Because the function completed successfully on a Wave32-only adapter, all later assertions inside its `if !target.runs(64)` block also passed (they are silent on success):
  - DPP row-mask handling for 64/128 threads.
  - VCC ballot/count for 64/48/32 threads.
  - Ordinary `v_mbcnt_lo` lane indexing.
  - Cross-half `v_readlane_b32` and `v_writelane_b32`.
  - Console-flow branch with one half inactive.
  - Cross-half `v_readfirstlane_b32`.
  - SAVEEXEC/SCC behavior.
  - Cross-half readlane inside a divergent loop with per-lane iteration counts.
- This is the first real RTX 3070 dispatch validation of the cross-half write path; the previous failure was a test-only VOP1 source encoding error fixed by commit `8d2fe8b` (`0x7E04_0305` reads VGPR `v5`, while `0x7E04_0205` read SGPR `s5`).
- CI #147 on PR head `071dce4` passed Clippy, diagnostics build, release build and workspace tests (212 passed, 0 failed, 2 ignored). As expected, its hosted D3D12 step explicitly skipped because that runner exposes neither 32- nor 64-lane waves; the user's RTX run is the hardware evidence.
- CI #146 for the matching main handoff also passed.

Next step:
1. Build the feature branch release binary with `cargo build --release --locked -p r4y`.
2. Run the user's normal R4Y launch flow with the affected title and inspect the newest `%LOCALAPPDATA%\\R4Y\\logs\\r4y-run.log`.
3. Specifically compare the previously refused compute hashes `13dfdd3b1136e407` and `88994c3496045f51`: determine whether each now translates/creates a host pipeline and dispatches, or is still refused for a specific unsupported Wave64 pattern. Do not infer runtime success merely from the unit/integration suite.
4. If the title run is stable and those pipeline paths are validated, then decide merge readiness. Keep PR #16 open until this real-title regression check is complete.

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

## 4.6 Public README, repository discovery and PortWatch VI

Updated on 2026-11-25:
- `README.md` was rewritten on main (commit `13a32e759dcdc746dc9f80e8b926fa748af27341`) to describe the actual R4Y product: experimental Windows Xbox Series X|S / Scarlett GDK compatibility layer, native x64 title execution, KernelX/XGameRuntime HLE, D3D12_XS-to-host-D3D12 backend, GFX10/RDNA2 shader translation to DXIL, formats, CLI, build, tests, diagnostics and known limitations.
- Removed unsubstantiated, configuration-specific old performance claims (~5 FPS gameplay / ~30 FPS menu).
- Removed direct GTA VI / Grand Theft Auto wording from the public README and architecture doc; the public docs now describe a general Xbox Series compatibility runtime.
- `docs/architecture.md` was corrected in commit `c8e7175bda6f06e60bf41a26e6121f3d36139fe0`: it no longer calls the format crate's implemented BCPack support planned and no longer labels the `r4y-game` crate GTA-specific.
- No root files were deleted: the current scripts, workflows, legal notices, security/contributing docs, installer entry points and `.agent/SESSION_HANDOFF.md` all remain functional/relevant. The handoff is intentionally retained for cross-chat continuity.
- The README is deliberately distinct from VIctory's source README. PortWatch compares README text against tracked projects to flag copied/re-uploaded projects, so do not paste upstream wording back into it.

PortWatch VI findings:
- Website: https://portwatch-vi.xyz/#watchlist
- Scout code: https://github.com/4lwayz/portwatch-vi/blob/main/scripts/scout.mjs
- Discovery configuration: https://github.com/4lwayz/portwatch-vi/blob/main/data/tracker.json
- Relevance/substance/similarity rules: https://github.com/4lwayz/portwatch-vi/blob/main/scripts/lib/core.mjs and `scripts/lib/pipeline.mjs`.
- The site says the scout searches every three hours and lists repos with real code as unreviewed candidates; copies are filtered out. The implementation searches GitHub for phrases including `scarlett xbox`, `xbox series`, `gdk compatibility layer`, `d3d12_xs`, `xgameruntime` and `rdna2 shader recompiler`.
- Relevance checks metadata plus README. It accepts strong game-specific terms, or sufficient Xbox Series/GDK platform signals (e.g. Scarlett, Xbox Series, GDK, D3D12_XS, XGameRuntime, KernelX). It also requires a substantive README and filters repos whose README is too similar to known projects.
- Current rewritten README includes the technical terms and code/test detail to satisfy those filters without naming GTA VI. A rough local application of PortWatch's scoring ingredients predicts a strong substance score (about 83 before recent-commit points); that is an estimate, not an actual scout result.

Repository GitHub "About" metadata:
- At the time inspected, the actual repository description was still only `Recomp4You`, and no topics were set.
- The current GitHub connector exposes repository metadata reads and repository-file writes, but not the repository-settings PATCH action. Do not claim this metadata was changed.
- Proposed description (202 characters):
  `Experimental Xbox Series X|S (Scarlett) GDK compatibility layer for Windows: native x64 title execution, XGameRuntime/KernelX HLE, D3D12.X-to-D3D12 backend, and an RDNA2/GFX10-to-DXIL shader recompiler.`
- Suggested topics: `xbox-series`, `scarlett`, `gdk`, `compatibility-layer`, `windows`, `d3d12`, `rdna2`, `dxil`, `shader-recompiler`, `rust`.
- Ready-to-run command for an authenticated GitHub CLI:
  ```powershell
  gh repo edit cmyk-ux/r4y --description "Experimental Xbox Series X|S (Scarlett) GDK compatibility layer for Windows: native x64 title execution, XGameRuntime/KernelX HLE, D3D12.X-to-D3D12 backend, and an RDNA2/GFX10-to-DXIL shader recompiler." --add-topic xbox-series --add-topic scarlett --add-topic gdk --add-topic compatibility-layer --add-topic windows --add-topic d3d12 --add-topic rdna2 --add-topic dxil --add-topic shader-recompiler --add-topic rust
  ```
- This is still pending until run and re-read through GitHub repo metadata.

CI after documentation changes:
- Main commit `c8e7175bda6f06e60bf41a26e6121f3d36139fe0`, run #131: https://github.com/cmyk-ux/r4y/actions/runs/45571236280
- Last observed status during this handoff update: Clippy normal and all-features passed; Release build was in progress. Re-check run #131 (and any newer main run) before reporting final status.
- PR #16 feature head `444e2570f1af854a4d16e09308607fa5482c68f2`, run #129 passed: https://github.com/cmyk-ux/r4y/actions/runs/45569300257. Its D3D12 body had been skipped on hosted runner without Wave32/64; the user's RTX 3070 dispatch remains the next runtime validation.

## 4.7 GPU-progress watchdog investigation and external reference audit (2026-11-25)

A durable upstream watchlist and audit log now lives in [`.agent/REFERENCE_REPOS.md`](REFERENCE_REPOS.md). **Always read it with this handoff.** The monitored priority order is Zettrox/ztrx, Marvisak/VIctory, fxceless/victory-fork, xcl-dev/xcl. Review relevant commits, issues and PRs with their report dates, comments, patches, reversions and validation; compare the actual code before porting. Do not blindly cherry-pick.

### Crash correlation

- The crash index from `%LOCALAPPDATA%\\R4Y\\data\\7952987A\\crashes.log` contains several distinct classes. PID 34964 (2026-11-24 22:32:28 local) is a D3D12 invalid call: the debug layer rejected `ALLOW_UNORDERED_ACCESS` on `B5G5R5A1_UNORM`, followed by `0x887A0001`. This matches [VIctory #2258](https://github.com/Marvisak/VIctory/issues/2258) / [PR #2286](https://github.com/Marvisak/VIctory/pull/2286).
- Earlier PIDs 18192, 31396, 20644, 1956 and 8608 report device removal/hangs, including `0x887A0006` after 28–33 command lists. These are not the same as the invalid-format query.
- PID 20352 (2026-11-25 06:37:38 local) reports `0xc0000005` writing to `0x0` at `r4y-image-...dll+0x23cf683`. [XCL #505](https://github.com/xcl-dev/xcl/issues/505) and [XCL #675](https://github.com/xcl-dev/xcl/issues/675) explain the same game-image offset as the title's intentional GPU-progress watchdog failure path (the `GPU Loc Sig` check followed by a deliberate null write). Treat this as a watchdog symptom: the title did not observe progress. Do not treat the write-to-null as the underlying emulator bug without new evidence.
- The RTX 3070 Ti investigation in XCL #675 is particularly relevant to the user's RTX 3070. One run implicated `CS_DepthProcessingHBO` with a 64-thread group and many ballot/exchange sites. Disabling that one shader stopped one limited A/B hang, but later comments identified another split-Wave64 dispatch as a hang source. Disabling every split-Wave64 shader avoided hangs in some runs but removed required compute features. The shader hash/path is **not** directly portable to R4Y because its translator/emitted DXIL differs.
- The current `r4y-run.log` had no explicit `R4Y: host GPU failure` or `0x887A0006` hit in the latest run. It did have `slow host submission ms=5572 lists=9` at 06:37:22 local, 16 seconds before PID 20352.
- In `r4y-gpu/src/host.rs::Host::execute`, this value is elapsed wall time from the post-preparation timestamp through `ExecuteCommandLists`, queue `Signal`, `SetEventOnCompletion` and `WaitForSingleObject(INFINITE)`. It means the fence for that nine-list submission completed after roughly 5.572 seconds. It is not just CPU preparation time and is not, by itself, proof of device removal or one guilty shader. In the ordinary path the lists are one submission group; per-list attribution requires the diagnostic timing path.

### R4Y source changes made after the user supplied the new logs

Branch: `feature/wave64-host-target`.

- `crates/r4y-gpu/src/resource.rs`: `shared_texture()` now calls `GetResourceAllocationInfo` with the live host resource's `t.texture.GetDesc()`, rather than bit-casting the guest/title `ResourceDesc`. The latter can carry format/usage combinations the actual host resource does not have.
  - Commit: `65ba0b315265dd5b7cf002b7a8ea53cefe8fe2d7`.
- `crates/r4y-gpu/src/pipeline/make.rs`: pipeline workers reserve a 64 MiB stack (`64 << 20`) to avoid the NVIDIA driver compiler overflowing Rust's default 2 MiB stack, based on [VIctory #966](https://github.com/Marvisak/VIctory/issues/966) and commit [d09c31b](https://github.com/Marvisak/VIctory/commit/d09c31b4c14481155e7d0b33b0aea30d9333f152). This is independent driver robustness, not a fix for the title watchdog.
  - Commit: `706179e62f78cd63fe925ba4d13a36284726d8da`.
- `crates/r4y-shader/src/emit/mod.rs`: added `R4Y_WAVE64_CONSOLE_FLOW=0` as a diagnostic-only bypass of the `console_cf` cross-half Wave64-to-Wave32 fallback. It refuses shaders that need the retry; ordinary in-half DPP/swizzle/MBCNT split remains enabled. Default is enabled.
  - Commit: `173e409fa938ed0485021da5d4a0b0c72d18572c`; later import cleanup: `b194221a932443984d05b24752aba195bb7b7570`.
- `crates/r4y-gpu/src/shader_cache.rs`: the switch is included in the shader-cache fingerprint, and disabled mode is logged at startup. Enabled/disabled translations cannot collide in the same cache identity.
  - Commit: `ae94e8127c5e1b28f12104a1321debf9683ff386`.
- The parser, controlled refusal path and cache-fingerprint distinction have unit tests in source. They have **not yet been confirmed by CI or a local compile** at the time of this handoff.

### Important distinction: `R4Y_GROUP_SYNC` is not this switch

The `console_cf` fallback emits two group-shared exchange slots and two group barriers to exchange values between the two host waves. `R4Y_GROUP_SYNC` controls translated guest `s_barrier` instructions, not those built-in exchange barriers. Flipping `R4Y_GROUP_SYNC` is therefore not a valid A/B for this specific hypothesis.

PowerShell A/B (set the environment variable before starting R4Y; the setting is read once per process):

```powershell
# Baseline: default cross-half console-flow path enabled
Remove-Item Env:R4Y_WAVE64_CONSOLE_FLOW -ErrorAction SilentlyContinue
.\\r4y-run.cmd

# Diagnostic: refuse only shaders requiring the cross-half fallback
$env:R4Y_WAVE64_CONSOLE_FLOW = "0"
.\\r4y-run.cmd

# Restore default for later runs
Remove-Item Env:R4Y_WAVE64_CONSOLE_FLOW -ErrorAction SilentlyContinue
```

The disabled run may lose rendering/features because those shaders are intentionally refused. It is an isolation experiment, not a permanent setting. Record each run's timestamp, crash PID/type, whether a GPU-removal event appeared, and the hashes/reasons of newly refused pipelines. Keep the logs from the two runs separate.

### CI status at this handoff

- Latest source-code commit in this audit: `b194221a932443984d05b24752aba195bb7b7570`; the handoff and reference-watchlist documentation were committed afterward on the same feature branch. Re-read the actual branch head at the start of the next session.
- No Actions run was associated with the audited documentation updates when rechecked; the latest green run remains #165 on the older code head `a24552a`.
- PR [#16](https://github.com/cmyk-ux/r4y/pull/16) remains open.
- The latest green CI run observed was #165 on the previous code head `a24552a29ed8b8f5c3cb2865dd6faffc62ec30aa`, not the code changes above. No successful CI result for `b194221` was confirmed. Do not say these commits are tested until the exact current head has green CI and the runtime A/B is complete.

### Next technical steps

1. Pull the current `feature/wave64-host-target` head, inspect the diff and run rustfmt, targeted shader tests, workspace tests, Clippy, release and diagnostics builds. Verify CI for the exact head.
2. On the RTX 3070, compare default mode with `R4Y_WAVE64_CONSOLE_FLOW=0`. Check whether the GPU-progress watchdog/device removal persists and which cross-half shader pipelines are refused.
3. If the bypass removes the hang, instrument and fix the cross-half exchange/control-flow lowering; add a regression for divergent loops/ballot/exchange. Do not leave the feature disabled as the final solution.
4. If the hang persists, isolate ordinary in-half split-Wave64 compute separately and add per-shader refusal/snapshot diagnostics before rewriting shader logic.
5. Revisit memory/streaming (commit pressure, DirectStorage, XMem mapping, card buffers) only with corroborating measurements. The VIctory APU-allocation telemetry PR #1720 is a useful later improvement, but no APU allocation refusal was shown in the supplied latest logs.
6. Resume the existing slot-zero view mismatch and large logical descriptor-heap virtualization backlog after the immediate GPU progress path is isolated.

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


## 7. Installer CI triage (2026-11-25)

The user resumed from the "Corrigir teste DPP" session and asked to continue with installer CI failures #162/#163.

### Confirmed root cause

- The valid installer body in `scripts/install.ps1` ended at its first `exit $exitCode` (about line 580).
- A stale, malformed 186-line tail had been appended after that exit. It began with the orphaned fragment `-and [int]$choice -ge 1 ...`, then repeated the remainder of `Select-Game`, duplicated `ConvertTo-TomlString`, `Write-Config`, `Build-R4Y`, `Invoke-Setup`, `Write-Launcher`, and appended a second main `try/catch`/exit block.
- The generic executable selection change itself is valid in the retained body: it auto-selects exactly one top-level `.exe`, prompts for a numeric choice when there are multiple candidates, falls back to the file picker/manual path, and validates extension and containment within the selected folder.
- CI #163 (run 45581923697) checked out merge commit `9bdd0cfc950da9674364f7d368c1d4895f60c8d7`; the first installer validation step failed during PowerShell parsing with unexpected `)` and `}` tokens. Dry-run, MSVC, native stderr, Rust setup, Clippy, build, tests and the D3D12 hardware step were all skipped.
- CI #161 (run 45581816240, parent installer revision) failed at the same first step with a larger set of parser errors, including the prompt string and CMD launcher text being parsed as malformed PowerShell. This predates #163.
- The GitHub Actions connector used here returns commit-associated runs filtered to pull-request events. It surfaced #161 and #163, but did not expose the user's referenced #162 push run; do not invent its run ID or conclusion. Check the Actions UI if its exact record is needed.

### Fix applied

- Commit `128e3d135799304390676a8667247088e900675d` on `main`: `fix(installer): remove stale duplicated script tail`.
- Commit `a24552a29ed8b8f5c3cb2865dd6faffc62ec30aa` on `feature/wave64-host-target` (PR #16): same fix.
- Both branches now have the same `scripts/install.ps1` blob SHA `8bcb58005d94fd4c91ae9d454ae827037c409f9e`; file is 580 lines, with one `Select-Game`, one set of helper definitions, and one terminal `exit $exitCode`.
- 186 stale lines removed; no valid installer logic was intentionally changed.

### Verification after fix

- PR CI #165, run `45583509798`, for PR head `a24552a29ed8b8f5c3cb2865dd6faffc62ec30aa`: **completed successfully**. Installer PowerShell parse + read-only dry-run, MSVC initialization, Windows PowerShell 5.1 stderr probe, Rust toolchain/cache, normal and all-features Clippy, release build, and workspace tests all passed. Workspace tests: **212 passed, 0 failed, 2 ignored, 3 filtered out**.
- The dedicated D3D12 Wave64 step also completed successfully, but its output explicitly said `adapter supports neither 32- nor 64-lane waves; skipped`. This is a successful hosted-runner skip, not a hardware dispatch. The earlier RTX 3070 local dispatch validation remains the hardware evidence.
- Run link: https://github.com/cmyk-ux/r4y/actions/runs/45583509798
- Main fix commit link: https://github.com/cmyk-ux/r4y/commit/128e3d135799304390676a8667247088e900675d
- PR branch fix commit link: https://github.com/cmyk-ux/r4y/commit/a24552a29ed8b8f5c3cb2865dd6faffc62ec30aa

### Next actions

1. Re-check CI #165 to its terminal conclusion. If Clippy/build/tests fail, inspect the exact failing step and fix it; do not mistake a successful parser step for full CI success.
2. Check the main push CI for commit `128e3d1` if the available Actions listing exposes it; the current connector's `fetch_commit_workflow_runs` wrapper is PR-filtered.
3. Keep PR #16 open until the already documented RTX 3070 Wave64 test and affected-title runtime regression check are accounted for. The earlier user RTX 3070 DPP/Wave64 dispatch suite passed; installer CI parser errors were independent and prevented the hosted run from reaching its D3D12 step.


## 8. Runtime log collection protocol

The user cannot upload the full runtime log into chat and expects the assistant to request **specific, narrow PowerShell extractions**. Do not ask them to paste a clipboard dump, the full log, or hundreds of generic keyword matches.

### Required approach

- First identify the exact subsystem and unresolved question from the current investigation (for example, Wave64 pipeline translation, descriptor slot-zero SRV dimensions, descriptor heap bounds, D3D12 device removal/DRED).
- Give a ready-to-run PowerShell snippet that reads the path held in the variable $path, initialized as shown below.
- Use Select-String -LiteralPath $path -Pattern with specific phrases or regexes, constrain results with Select-Object -First N or -Last N, and print each match with its line number in the form L{LineNumber}: {Line}.
- Group a few closely related questions under clear Write-Host headings. Include exact hashes, error strings, or subsystem phrases already observed in the code/logs. Avoid broad generic patterns such as error|warn|shader|pipeline|d3d12 that match most of the file.
- If context is required, request a small surrounding window around matching line numbers (for example, Get-Content with calculated start/end indices) rather than dumping all matches. Keep output to a manageable number of lines.
- Prefer raw matching lines first. Only request expanded context or a second extraction after seeing the returned evidence.
- Do not tell the user to press Ctrl+V after copying a report unless the actual report content has been included in their message; clipboard contents are not automatically visible to the assistant.
- Do not make the user choose the log patterns. The assistant owns selecting the evidence needed for the next diagnostic decision.

### Example: current Wave64 runtime follow-up

When checking the affected title after the Wave64 implementation, a focused first pass can request:

\`\`\`powershell
$path = "$env:LOCALAPPDATA\\R4Y\\logs\\r4y-run.log"

Write-Host "\`n===== TARGET HASHES ====="
Select-String -LiteralPath $path -Pattern '13dfdd3b1136e407|88994c3496045f51' |
    Select-Object -Last 30 |
    ForEach-Object { "L$($_.LineNumber): $($_.Line)" }

Write-Host "\`n===== WAVE64 REFUSALS / HOST PIPELINE REJECTIONS ====="
Select-String -LiteralPath $path -Pattern 'wave lane count of 64|host pipeline refused|wave64|split wave64' |
    Select-Object -Last 40 |
    ForEach-Object { "L$($_.LineNumber): $($_.Line)" }

Write-Host "\`n===== D3D12 DEVICE REMOVAL / DRED ====="
Select-String -LiteralPath $path -Pattern 'DXGI_ERROR_DEVICE|DEVICE_HUNG|DEVICE_REMOVED|DRED|breadcrumb|device removed|device hung|page.?fault VA' |
    Select-Object -Last 25 |
    ForEach-Object { "L$($_.LineNumber): $($_.Line)" }
\`\`\`

This example is a starting point, not a fixed template: change the patterns to match the actual open question. The previous broad 900-line extraction was excessive and should not be repeated.


## 9. Post-installer runtime test — Wave64 executable/profile mismatch investigation (2026-11-25)

The user ran the affected title after the installer fix. Their checkout reported branch \`feature/wave64-host-target\`, HEAD \`a24552a\`.

### New log facts

From \`%LOCALAPPDATA%\\R4Y\\logs\\r4y-run.log\`:

- Both target compute shaders translate from disk cache (\`cached=true\`) but their host pipeline creation is rejected with \`0x80070057\`:
  - \`13dfdd3b1136e407\`
  - \`88994c3496045f51\`
- Both are later bound and their dispatches are dropped for lack of a host pipeline. Observed per-frame drop reports: 0.5/frame and 0.1/frame, later 5.0/frame for the first hash.
- 168 D3D12 debug messages say a shader requires WaveSize 64 while the device max is 32.
- There are 136 \`host pipeline refused\` records. An attempted PowerShell parser returned zero hashes even though raw lines visibly contain \`shaders=[compute <16-hex-hash>]\`; treat this as an extraction-script failure, not evidence of absent hashes. Retry with a simpler parser and first print a few raw refusal lines.
- The searched startup markers \`host wave sizes\` and \`the host has no 64-lane waves\` are absent from this log.
- Four GPU-Based Validation warnings again report Texture2D expected vs Texture1D in descriptor heap slot 0, with pixel shaders \`c0a7fe77b1862e10\`, \`0d1575a396dfe513\`, and \`280967ad158cee0b\`.
- No matching device-removal / device-hung / DRED lines were returned by the focused search. This means no such diagnostic was observed in the excerpted log, not proof that none occurred outside the captured file.
- GPU-Based Validation is enabled; the 0.6 FPS / ~1.7 s frame observed in the same interval is not representative performance.

### Critical discrepancy: selected profile may be stale

The checked-out source on PR #16 contains an unconditional \`tracing::info!(..., "host wave sizes")\` immediately after D3D12 OPTIONS1 is queried in \`crates/r4y-gpu/src/host.rs\`. It also warns if the host cannot run 64-lane waves. The runtime log contains D3D12 host activity and debug-layer messages but neither startup marker, while still showing fixed-Wave64 shader creation failures.

The launch path in \`r4y-run.cmd\` invokes \`scripts/install.ps1 --launch\`. \`Invoke-Launch\` reads \`%LOCALAPPDATA%\\R4Y\\install-state.json\`; if \`profile=diag\`, it launches \`target\\diag\\r4y.exe\`, otherwise \`target\\release\\r4y.exe\`. The installer's \`Build-R4Y\` uses:
- diagnostics: \`cargo build --profile diag --locked -p r4y --features diagnostics\`
- release: \`cargo build --release --locked -p r4y\`

Therefore, a previous recommendation to build only \`--release\` does **not** refresh the executable actually launched when the persisted installer profile is \`diag\`. The current log explicitly reports \`GPU-based validation on\`, which strongly suggests a diagnostics binary/profile. It is not yet proven which binary's timestamp/profile was used; inspect \`install-state.json\` and both target binary timestamps, then rebuild the selected profile before drawing conclusions about the Wave64 implementation.

### Next actions

1. Have the user inspect \`install-state.json\` (\`profile\`) and \`target\\diag\\r4y.exe\` / \`target\\release\\r4y.exe\` timestamps.
2. Rebuild the profile actually selected by the installer; for \`diag\`, use \`cargo build --profile diag --locked -p r4y --features diagnostics\`. Then relaunch through \`r4y-run.cmd\`.
3. First verify that the new log contains \`host wave sizes lanes_min=32 lanes_max=32\` (or the actual reported values) and the expected no-64-lane warning. Only then assess remaining Wave64 shader failures.
4. Re-check the two target hashes and all refusal hashes using a corrected extraction script. Do not treat shader-cache hits as proof that the currently checked-in translator generated those cache entries until the selected binary/cache fingerprint is verified.
5. Keep slot-zero SRV mismatch and descriptor virtualization as independent investigations; do not conflate them with Wave64 or the stale-binary/profile concern.


## 10. Correct Diagnostics runtime — target Wave64 pipelines now created; title still crashes (2026-11-25)

The user rebuilt and launched the profile selected by install-state.json (Diagnostics). This corrected the prior stale-profile ambiguity.

### Confirmed on the correct runtime

From the new LOCALAPPDATA R4Y run log:

- Device initialization explicitly logs host wave sizes lanes_min=32 lanes_max=32, followed by the warning that the host has no 64-lane waves. This confirms the current Diagnostics binary contains host-wave-aware initialization on the RTX 3070.
- Both previously problematic compute shaders were translated freshly (not from the previous cache):
  - 88994c3496045f51: cached=false, 8 ms; host pipeline created at 09:34:58.785.
  - 13dfdd3b1136e407: cached=false, 10 ms; host pipeline created at 09:34:58.802.
- Both subsequently reached first bind:
  - 13dfdd3b1136e407 at 09:35:44.620, frame 1168.
  - 88994c3496045f51 at 09:36:07.518, frame 1186.
- The focused extraction returned no host pipeline refused rows and no D3D12 debug-layer Shader wants wave lane count of 64 messages for this run. The previous run had 136 PSO refusal rows and 168 such Wave64 warnings. This is strong evidence that the targeted Wave64 split now makes those two actual title pipelines successfully on the Wave32 RTX 3070. The previous failures are no longer valid for this freshly built runtime.
- Do not claim the entire game's Wave64 workload is supported. The first 25 shader does not translate rows include deliberate/known unsupported cases, e.g. a select on an untracked mask, descriptors not loaded or built, direct lane-mask data reads, LDS sharing without barriers on a Wave32 host, and general console Wave64 lanes. These are separate shader-lowering limitations and need triage by relevance to crash.
- User reports loading took substantially longer, then the screen went black and the game crashed as before. This timing is not yet causally attributed. First-time target-specific shader translations (cached=false), PSO/library behavior, diagnostics instrumentation and GPU-based validation are potential overheads; do not assume Wave64 implementation itself caused the longer load.

### Crash-report facts

The end of the log includes a title Breakpad report at 09:37:38:
- Game Version: 930.048.020 / build 930.048.020-vb_sub_story.
- device.model: Xbox Series X; platform: scarlett.
- memory.load_percent=92.
- system.memory.free=2604432; units are not explicitly labelled in this log excerpt. Treat this as a pressure signal only, not a definitive available-memory measurement.
- Breakpad added crashcontext.log from path T:/r4y-20261125-063738-20352.crash.log.
- It added upload_file_minidump from T:/00000000-0000-0000-0000-000000000000.dmp (~37,456,412 bytes).
- Upload destination was submit.backtrace.io:443, but R4Y's network HLE logged HTTP connection blocked destination=submit.backtrace.io:443.
- This is a title-side crash report, not yet proof of a D3D12 device removal. The prior focused search returned no DXGI_ERROR_DEVICE, DEVICE_HUNG, DEVICE_REMOVED or DRED markers. Keep title/Breakpad exception and GPU device removal distinct.

### Next action — inspect crashcontext file and R4Y tail

Ask the user to run focused PowerShell against the exact crashcontext path:
1. Check whether T:/r4y-20261125-063738-20352.crash.log still exists.
2. If it exists, print its first 100 and last 180 lines, with line numbers; additionally print lines matching exception/crash/assert/fatal/callstack/stack/unknown-symbol/failed and surrounding lines.
3. If it does not exist, inspect the R4Y run log for crash report heading, exception code, faulting module/address, call stack, crash thread and title log lines immediately before 09:37:38.
4. Also capture the run's frame timing / drop summaries between 09:35 and crash, and check whether device-removed reason was logged.
5. Do not ask for the 37 MB minidump or the entire R4Y log. Ask for line-oriented, targeted PowerShell output only.

After receiving crashcontext evidence, correlate the crashing subsystem/thread with the last GPU submits, dropped dispatches, descriptor warnings and memory pressure. Keep the already-fixed target shader pipeline creation as a regression success; do not roll it back while investigating this separate title crash.

### Current project state

- Local test checkout: feature/wave64-host-target, HEAD a24552a.
- PR #16 remains open. Its intended runtime regression check now has materially improved evidence: the two named pipelines create and bind on the RTX 3070. Do not merge until the new crash is understood or the user explicitly elects to merge with the remaining limitation documented.
- Slot-zero SRV Texture2D-vs-Texture1D mismatch persisted in the earlier diagnostics log and remains a separate issue; the newest pasted extraction did not include the GBV pattern, so its status on this exact run is unknown.


### Crash artifact path correction and captured exception details (2026-11-25)

Correction to the previous next-step note: the game's T: drive is a virtual title filesystem mount, not the user's host T: drive. apps/r4y/src/run.rs establishes:
- temp = cfg.data_subdir("7952987A/temp") for TitleID 7952987A.
- r4y_hle::modules::files::mount_at('T', &temp) maps title T: to that host directory.
- r4y_loader::log_crashes_to(temp.with_file_name("crashes.log")) saves R4Y exception reports to a sibling file, <data_dir>/7952987A/crashes.log.
- Default data root is %LOCALAPPDATA%\R4Y\data (unless R4Y_DATA_DIR or [paths].data_dir overrides it; config resolution is in crates/r4y-core/src/config.rs).

Thus the expected host paths with the generated default config are:
- Crash context: %LOCALAPPDATA%\R4Y\data\7952987A\temp\r4y-20261125-063738-20352.crash.log
- R4Y exception stack log: %LOCALAPPDATA%\R4Y\data\7952987A\crashes.log

The previous request to inspect literal host path T:\r4y-... was incorrect because it treated the guest mount as a host volume. Correct future log collection accordingly.

### Captured fatal exception details

The user's latest extraction already contains:
- First-chance and unhandled exception: 0xc0000005, access violation, write to 0x0, reported by R4Y as nothing mapped there.
- Faulting PC: r4y-image-b99f876b74d4a77f.dll+0x23cf683.
- crates/r4y-loader/src/crash.rs::report() logs the full general-purpose registers and up to 40 unwound frames immediately after the exception line. The user's pattern-only extraction omitted these adjacent lines; the R4Y run log already has them. Next extraction must request a small line window around both R4Y: first-chance exception and R4Y: unhandled exception, not just matching lines.
- memory_at(0) calls VirtualQuery and reports nothing mapped there for MEM_FREE; it is not an OOM classification. Treat this as a null/unmapped write access violation. The offset is within the prepared title image (r4y-image-...), but do not infer its function/cause until the registers and stack frames are read.
- The title Breakpad context is expected in the mapped title temp directory, and R4Y's own exception report is expected in sibling crashes.log.

Working-set evidence preceding the crash:
- copystat reports working set rising from ~6,852 MB at 09:35:04 to ~17,292 MB at 09:37:01, with several snapshots around 16-17 GB.
- Breakpad reports memory.load_percent=92, system.memory.free=2604432, system.memory.total=33475460; units are not explicitly documented in the crash excerpt. This suggests significant system memory pressure, but does not prove the null write was caused by memory exhaustion. Do not conflate the AV with OOM.

Next user-facing extraction:
1. Read the configured data root (generated default %LOCALAPPDATA%\R4Y\data; account for R4Y_DATA_DIR or [paths].data_dir if customized).
2. Check existence and metadata of the exact host paths above.
3. Print the head/tail and exception/stack-related lines of the title crashcontext if present, plus the last ~120 lines of crashes.log.
4. From r4y-run.log, emit roughly 12 lines before and 45 after the first-chance/unhandled exception lines, preserving line numbers. This should expose all register values and unwind frames already emitted by R4Y.
5. Do not use a PowerShell if block followed by else pasted separately into an interactive prompt. Use a single complete script block or independent if without a detached else.


## 11. PR #16 branch-local validation history

The following records are retained from the feature branch because they contain the exact test/Clippy failures, their repairs, the CI ownership boundary and the structured-buffer prototype caveats. The newer runtime evidence in sections 9–10 above supersedes older status notes where they differ.

## 7. Follow-up: test/Clippy compile failure and repair (2026-11-25)

The user ran the validation commands before the RTX 3070 A/B and reported:

- `cargo build --release --locked -p r4y`: **passed** (17.04 s).
- `cargo test -p r4y-gpu --locked`: **passed**, 93 passed, 0 failed, 1 ignored benchmark.
- `cargo test -p r4y-shader --locked`: did not compile the test target. In `emit::host_wave_target_tests`, the test referenced private parent module `lower` as an unqualified name (`lower::CONSOLE_FLOW`); child test modules must use the parent path (`super::lower::CONSOLE_FLOW`) or import it.
- `cargo test --workspace --locked`: failed on the same `E0433`.
- `cargo clippy --workspace --all-targets --locked -- -D warnings`: exposed the same unresolved module and `clippy::too_many_arguments` on the private `emit_for_with_console_flow` helper (8 parameters).
- Because the test target failed, the successful release build must not be treated as proof that the Wave64 diagnostic tests compile.

The root cause of the unresolved module was an earlier cleanup commit `b194221a932443984d05b24752aba195bb7b7570` that removed the `emit_for` import but left the module-path reference in the nested test module.

### Repair published

- `f8855c4190006040f36651d618af3a5ca5833675` — introduced a private `EmitOptions { target, allow_console_flow }` value, reducing `emit_for_with_console_flow` from 8 parameters to 7 without suppressing Clippy.
- `f02181adf76067bb7262eadd18543f5a98289254` — qualified the test's module reference as `super::lower::CONSOLE_FLOW` and formatted the long match arm.
- Subsequent handoff-only commits advance the branch without changing source. The source repair commit is `f02181adf76067bb7262eadd18543f5a98289254`; verify it is an ancestor of the local HEAD rather than relying on a documentation commit hash embedded here.
- PR #16 remains open. At the time this note was written, the latest visible green branch CI was still on the older code head `a24552a29ed8b8f5c3cb2865dd6faffc62ec30aa`; the repair commits themselves have not yet been confirmed green.
- The GitHub compare still reports the feature branch as divergent from current `main` (102 ahead / 27 behind at the prior snapshot). Do not merge just to make CI run; keep validation on the PR branch and inspect any CI result tied to the exact head.

### Next validation steps (must precede the game A/B)

```powershell
git fetch origin
git switch feature/wave64-host-target
git pull --ff-only origin feature/wave64-host-target
git status --short --branch
git rev-parse HEAD
```

The repair code must be present in local history. Verify with `git merge-base --is-ancestor f02181adf76067bb7262eadd18543f5a98289254 HEAD` (exit code 0 means present). Documentation-only commits may move HEAD beyond the source repair. If this check fails, stop and inspect branch/status before testing.

Then rerun:

```powershell
cargo fmt --all -- --check
cargo test -p r4y-shader --locked
cargo test -p r4y-gpu --locked
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build --release --locked -p r4y
```

Also verify the CI run for the exact PR head, not merely the prior green run. Only after these pass should the RTX 3070 `R4Y_WAVE64_CONSOLE_FLOW` A/B be attempted.

## 8. Follow-up: structured-buffer regression, Clippy and CI ownership (2026-11-25)

### User-reported local failures

The user stopped validation after seeing failures and supplied these results from the local RTX 3070 machine:

- `cargo test -p r4y-shader --lib`: 214 passed, 2 failed, 2 ignored.
- `emit::stride_tests::a_heap_buffer_read_by_element_takes_the_views_stride` failed at `stride_tests.rs:295`: actual output began `[101, 104, 107, ...]`, expected `[200, 201, 202, ...]`.
- `emit::synthetic_tests::gathers_at_a_level_match_the_hardware` failed at `synthetic_tests.rs:263`, comparing the translated manual gather result (`got(0)`) against the CPU reference. It failed before the later native-gather comparison.
- `cargo clippy --workspace --all-targets --locked -- -D warnings` separately found:
  - missing safety comment on the `GetResourceAllocationInfo` unsafe block in `crates/r4y-gpu/src/resource.rs`;
  - `key_for_target` with 8 arguments in `crates/r4y-gpu/src/shader_cache.rs`.
- The user did not wait for or report the final result of `cargo build --release --locked -p r4y`.

### DXIL lowering diagnosis and published prototype

The two shader failures both exercise structured-buffer access but through different paths:

1. The dynamic resource-heap test uses a structured buffer with a 12-byte descriptor stride. The shader has no static `UsedResource` entry for the descriptor, so the translator reads the host `VIEW_STRIDES` table at runtime. It was computing `element * stride + byte_offset` and emitting a RawBufferLoad with the byte address as coordinate 0 and undef coordinate 1, despite the underlying descriptor being structured.
2. The synthetic gather test reads a known structured SRV with stride 16. Its `buffer_load_dwordx4` is offset-only (`idxen=false`), but the translator emitted the RawBufferLoad raw-buffer coordinate form. In DXIL, StructuredBuffer RawBufferLoad uses coordinate 0 = element index and coordinate 1 = byte offset within that element; the raw form instead uses coordinate 0 = byte offset and requires coordinate 1 to be undef. DXC validator source checks this distinction in `DxilValidation.cpp`.

A prototype lowering change was committed:

- `004cfac5d87904ba1fc63d0b0fe4f02ea5643a14` — `Fix structured buffer byte-offset lowering`.
- It retains dynamic `VIEW_STRIDES` values, calculates element/within-element coordinates with unsigned divide/remainder, and emits the structured handle form for the affected load/store/atomic paths. For statically known structured offset-only accesses, it derives the stride from the used-resource entry.
- **This is a hypothesis-driven implementation, not yet a verified fix.** No local compile, DXIL validation, D3D12 execution, or green CI was confirmed after this commit. In particular:
  - dynamic resource-heap descriptor handle properties currently use a structured resource kind with a runtime descriptor stride and property stride 0; DXIL validation and actual driver behavior must be confirmed;
  - dynamic raw-buffer heap entries may require an explicit descriptor-kind tag in the host metadata and a safe kind-matched null fallback. Do not assume every heap-indexed buffer descriptor is structured;
  - the byte/half subword load/store paths still take the raw-view route and have not been generalized by this prototype;
  - the zero-stride descriptor path in `buffer_guard` still redirects to the existing raw null SRV/UAV. If CI exposes a structured-null mismatch, add a structured null descriptor and update the heap layout/test coverage rather than skipping the test.

### Clippy repairs published

- `29ad56f9c04bddfe99e6f65f0439a10aed016da8` — added the missing safety contract immediately before `GetResourceAllocationInfo`. The device is owned by the live host and the descriptor comes from the live texture.
- `228ff8981247eedbdb632a682fb3d63ac0d54937` — grouped cache-key inputs in a private `KeySettings` value, preserving the prior hash serialization order while reducing `key_for_target`'s parameter count.
- These source changes also await CI verification.

### CI workflow changes published

- `1c7cc18f45e4f8b02433b4df92ff271fbbd0bbf` — added `workflow_dispatch` to `.github/workflows/ci.yml` and removed `gathers_at_a_level_match_the_hardware` from the workspace test skip list.
- The gather test's CPU-reference path is architecture-independent and runs on the D3D12/WARP devices the test can create. The later comparison against native gather is already conditional on `!warp`. Keep the Wave32/Wave64 architecture-reference tests skipped on GitHub-hosted runners without a guaranteed matching adapter.
- The existing `pull_request` trigger already starts a fresh run when commits are pushed to this PR branch. The explicit `workflow_dispatch` trigger is retained for future manual runs.

### Mandatory CI ownership / validation policy

**CI validation belongs to the assistant maintaining this repository, not to the user.** For every source-code batch intended for user testing:

1. Push the finished source changes to the active PR branch, allowing the `pull_request` workflow to run. Use `workflow_dispatch` only when a manual run is actually needed and an authorized dispatch mechanism is available.
2. Query Actions for the new run and confirm that it is associated with the current PR head. GitHub's pull-request workflow may expose a synthetic merge SHA as `head_sha`; compare its PR metadata and parents with the current branch tip rather than mistaking an old green commit or synthetic merge commit for a different source revision.
3. Inspect all workflow jobs and steps, then fetch logs for failures. Fix source/workflow errors and repeat until the exact PR head has a completed green run, or clearly state the remaining external limitation (for example, a hosted runner cannot provide the required physical GPU).
4. Never make the user act as the CI runner when the GitHub workflow can validate the change. Never imply a prior green run validates commits that were pushed after it. Do not describe missing CI as a user-side problem.
5. A green hosted CI run proves only the tests and hardware/software environment actually exercised. Record architecture-specific or physical-GPU tests not covered by hosted runners separately; do not represent them as green by implication.
6. Do not ask the user to rerun a long local build/test suite merely to compensate for not checking Actions. Ask for local hardware evidence only when the required RTX 3070 runtime experiment genuinely cannot run on GitHub-hosted hardware.

### State at the time of this handoff update

The most recent source/CI configuration commit is `1c7cc18f45e4f8b02433b4df92ff271fbbd0bbf`. The PR head must be queried again after this edit because this handoff update itself creates another commit and triggers another PR workflow. **No green CI result for the structured-buffer prototype is claimed here.** The next assistant session must check the latest branch head and its associated Actions run before asking the user to test or continuing to the game A/B.


#### CI trigger attempt and integration limitation (same session)

- After the commits above, the feature branch tip was `d7c2f5bfe25e4874336f0853e7db40a889b6b31c`. The PR #16 head matched it.
- GitHub returned `total_count: 0` for `/commits/d7c2f5b.../check-runs` and `/actions/runs?head_sha=d7c2f5b...`; combined status was pending with no statuses. The most recent Actions runs remained on old commits (the newest was a `main` push, not this feature revision).
- A temporary validation PR #17 was created from exactly this same commit, marked ready, closed and reopened to generate PR activity. It still did not create an Actions run and was then closed. It must never be merged. Temporary branch: `ci/validate-wave64-head-20261125`.
- The GitHub connection available in this session exposes GET-only workflow-run inspection and rerun actions for jobs that already exist; it exposes no new-run/workflow-dispatch action. Writes to the repository and the PR mutations above did not produce an Actions run in this environment. The workflow now declares `workflow_dispatch`, but this connection cannot send the required dispatch request.
- **Therefore the exact feature head is not CI-validated.** Do not label the prototype green. The blocker is the inability of the connected GitHub action surface to dispatch a new run (not a user-side build failure). Once an authorized workflow-dispatch capability is available, run the updated CI on the current branch head and inspect every job/log. If a real run appears automatically, use that instead.
- This does not relax the CI ownership rule above: the assistant must use a dispatch-capable integration when available, or report the concrete capability blocker; never ask the user to substitute for CI when the workflow can be run remotely.


#### Correction: where `workflow_dispatch` must exist (2026-11-25)

- Rechecked the actual default branch `main`: `.github/workflows/ci.yml` there still has only `pull_request` and `push: branches: [main]`; it does **not** contain `workflow_dispatch`.
- The feature branch contains `workflow_dispatch` after commit `1c7cc18f45e4f8b02433b4df92ff271fbbd0bbf`, but that alone does not make manual dispatch available. GitHub documents that `workflow_dispatch` only triggers when the workflow file exists on the default branch: [GitHub Actions event documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch).
- Thus do not describe the feature-only `workflow_dispatch` addition as an available manual trigger. To enable it, the trigger must also land on `main` (preferably through a small CI-infrastructure change), after which the dispatch must target `ref=feature/wave64-host-target`.
- Also note that plain `pull_request:` uses GitHub's default activity types; it does not include `edited`. The default branch workflow would need `pull_request: types: [opened, synchronize, reopened, edited]` to allow a PR-body edit to start a run.
- Verified again on the current branch tip `d78db848e13734c4458102ff9b32a821cd597af7`: `check-runs` total is 0, the Actions run query by this exact `head_sha` is empty, and combined commit status is `pending` with no statuses. No successful CI result exists for this tip.
- The current GitHub connector exposes no action to send the workflow-dispatch POST. It can inspect existing runs and rerun jobs only. Do not ask the user to build locally as a substitute for this missing dispatch capability, and do not mark the branch green.


#### GitHub Actions event/token caveat

- GitHub's documented default activity types for plain `pull_request:` are only `opened`, `synchronize` and `reopened`; `edited` is not included. Source: [pull_request event activity types](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request).
- GitHub also documents that PR events caused by a workflow using `GITHUB_TOKEN` do not normally start further runs: `opened`/`synchronize`/`reopened` may be created in an approval-required state, while other activity types (including `edited`) do not create a run. Source: [GITHUB_TOKEN event behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request).
- The connected GitHub tool's token type is not exposed to this session, so do not state that this is the proven cause. It is a plausible explanation for why API-driven PR mutations did not yield a visible Actions run. The observed fact remains: no run/check is associated with the exact feature head.
- Consequently, merely adding `edited` to the `pull_request` activity types would not reliably solve an automated-token trigger. The durable route is a dispatch-capable integration with Actions write permission, after the workflow-dispatch trigger is present on `main`, dispatching the feature ref and checking the exact SHA.

## 12. Current branch implementation: indirect argument clamp

### Indirect argument clamp: non-destructive scratch output (2026-11-25)

### Implementation now present on the branch

Latest feature head before the main-merge integration: `b7f39f590c0c5bb8d9640b13b0ec52a7be7a8ce6` (PR #16, still open).

Files changed:
- `crates/r4y-gpu/src/indirect.rs`
- `crates/r4y-gpu/src/draw.rs`
- `crates/r4y-gpu/src/host.rs`
- `crates/r4y-gpu/src/capture.rs`

The old R4Y clamp wrote directly into the title's argument shadow and processed up to `max` even when an `ExecuteIndirect` count buffer specified fewer active records. The current implementation changes that contract:

1. The clamp reads the original arguments and optional count as `ByteAddressBuffer` SRVs.
2. It exits for `id.x >= min(max, count)` (or `max` without a count), so inactive tail records are neither read nor copied.
3. It writes complete active records into a reusable device-local UAV scratch buffer; `ExecuteIndirect` consumes that scratch resource at offset zero. The original argument shadow is left unchanged.
4. The per-list work budget uses a bounded compare-exchange loop and saturating accounting rather than an unbounded / wrapping atomic add.
5. The count buffer state is tracked as a compatible union of shader-resource and indirect-argument read states. Diagnostic capture now transitions from and back to that exact tracked state.
6. The budget and scratch UAVs are explicitly transitioned to COMMON at list close; scratch resources (including resized/retired buffers) are tracked through their actual states. This is necessary because explicitly transitioned buffers do not decay automatically to COMMON, and a closed list may be submitted again before it is reset.

### Tests added

- `argument_clamp_hlsl_compiles_without_a_gpu`: always exercises D3DCompile for the embedded HLSL/root-signature source on Windows, even if the runner has no D3D12 adapter.
- `argument_clamp_builds_on_host`: additionally checks that the available host device accepts the root signature and compute PSO; it returns early if no host adapter is available.
- `count_limits_clamp_writes_on_host`: runs the actual clamp dispatch on the configured host when available. It sets count=1 with three source records, pre-fills output tail records with `0xDEAD_BEEF`, and checks that only the first active record changes, the original source is unchanged, and the count stays 1. It also submits the same closed command list twice to exercise scratch/budget state replay.
- `indirect_count_keeps_compatible_shader_read_state`: checks that shader-resource and indirect read states are combined, rather than treating the count buffer as indirect-only.
- Additional pure layout tests cover record minimum stride, dword alignment and scratch byte-size calculation.

### Validation and outstanding cautions

- **No CI run or check status exists for the exact head `b7f39f590c0c5bb8d9640b13b0ec52a7be7a8ce6`.** The GitHub Actions query by that SHA returned no runs and no commit statuses. The current GitHub connector still exposes no workflow-dispatch/new-run action. Do not call the change compiled, tested or green until an actual CI run validates the exact head.
- The HLSL compile test can run without a GPU, but the host PSO and dispatch tests return early when `crate::host::host()` is unavailable. Their execution must be confirmed from CI logs or a supported local D3D12 run.
- The structured-buffer lowering prototype from commit `004cfac5d87904ba1fc63d0b0fe4f02ea5643a14` remains a separate unvalidated risk; this indirect-clamp work does not validate it.
- PR #16 is still `mergeable=false`, with the feature branch 139 commits ahead and 27 behind `main` at the time checked. No rebase or merge was attempted. Inspect and reconcile the divergence separately; do not rewrite the branch blindly.
- Do not begin clamp hoisting/performance batching yet. First validate this non-destructive scratch path, count behavior, list replay, Clippy (including all-features), diagnostics and release builds. Only then measure the real title workload and decide whether hoisting is worthwhile.

### Immediate next actions

1. Trigger CI on the exact current feature SHA once a dispatch-capable route is available; inspect HLSL compilation, GPU tests, Clippy, diagnostics/release builds and workspace tests.
2. If CI fails, fix the exact failures before adding a new subsystem.
3. If hosted CI has no usable D3D12 adapter, retain the HLSL compiler test as hosted coverage and run the dispatch test on a D3D12 host/WARP-capable environment; do not represent a skipped GPU test as executed.
4. After the clamp has passed, continue to the next runtime blocker from the existing Wave64 handoff. Keep the AMD helper-lane investigation separate until the affected title/runtime or focused shader fixtures justify it.


## 13. Latest successful CI and dynamic heap-stride correction (2026-11-25)

This section supersedes older CI/branch status snapshots above.

### Exact validation

- Code commit validated by CI: `4117c0c3695560f94e57a455d907d38e1bee78ca`.
- Actions run #186: https://github.com/cmyk-ux/r4y/actions/runs/45616192308
- Run conclusion: **success** on that exact head SHA.
- PR #16 remained open and mergeable; branch was 166 commits ahead and 0 behind `main` at the last compare before the comment-only follow-up.
- Clippy `cargo clippy --workspace --all-targets --locked -- -D warnings`: passed.
- All-features diagnostics Clippy `cargo clippy --workspace --all-targets --all-features --locked -- -D warnings`: passed.
- Release build `cargo build --release --locked -p r4y`: passed.
- Workspace tests: **214 passed, 0 failed, 2 ignored**, with 2 architecture-specific tests filtered from the general workspace invocation.
- In particular, these passed in the WARP-only hosted path (`R4Y_D3D12_WARP=1`):
  - `emit::stride_tests::a_heap_buffer_read_by_element_takes_the_views_stride`
  - `emit::synthetic_tests::gathers_at_a_level_match_the_hardware`
- The previously failing dynamic structured-heap stride test was the only failure in run #185; it now passes on WARP.

### D3D12 Wave64 limitation in the hosted runner

The separate step `Verify wave64 split and console flow on D3D12 hardware` completed with process/test success, but the test output explicitly said:

```text
adapter supports neither 32- nor 64-lane waves; skipped
```

Therefore this run does **not** validate the lane-by-lane Wave64 D3D12 test on a capable adapter. Do not represent the skipped test as a Wave64 hardware pass. The code path remains covered by the unit/translation tests; a capable device test is still needed on the RTX 3070 or another D3D12 adapter that reports 32/64 wave capabilities.

### Why the dynamic heap stride fix works

- Before the latest fix, resource-heap buffer loads with no static `UsedResource` entry loaded the runtime per-slot `VIEW_STRIDES` value, calculated `index * stride + offset`, but then emitted a StructuredBuffer handle with `StructStrideInBytes=0`. WARP returned the same fixed element for every lane (`200, 200, ...`) instead of `200..231`.
- Commit `4117c0c3695560f94e57a455d907d38e1bee78ca` now leaves `structured_stride` unset for this dynamic case. The byte offset already includes the runtime stride, so the operation uses RawBuffer byte-offset coordinates. Static structured resources with a compile-time `UsedResource.stride` keep their StructuredBuffer path.
- This resolved the WARP regression without changing the host descriptor mirror or adding a second descriptor heap.
- The source comment was clarified in comment-only commit `859ffc5b87144e9b0baf338966c56b4b8d2f9e21`; it now describes dynamic stride conversion to byte offsets and RawBuffer coordinates.

### Next steps

1. Re-check current branch head and Actions after this handoff/comment-only update. The full #186 result applies to code head `4117c0c...`; later changes are documentation/comment-only until proven otherwise.
2. Continue runtime blocker triage using the already-recorded crash-context findings in section 10: title-side access violation is a write to null/unmapped address at `r4y-image-...+0x23cf683`; memory pressure was high but is not proven causal. Obtain or inspect the adjacent register/unwind frames from the exact `crashes.log` report before assigning a subsystem.
3. Do not return to clamp hoisting yet. Scratch/count correctness, WARP, Clippy, diagnostics and release builds have passed; real title GPU timing and RTX 3070 A/B are still needed before performance changes.
4. Keep the AMD helper-lane/quad semantics audit as a separate item. Do not implement a broad helper-lane change solely on the AMD report; create focused tests and establish a failing NVIDIA/title case first.


## 14. Crash diagnostics, pipeline wave-size logging and next GPU timing run (2026-11-25)

This section supersedes the older branch/CI snapshots above.

### CI validation

- Crash reporter instrumentation commit: `240e0c14b22e7c5e3209c53042c7a7dc212580c7`.
- CI run #187: https://github.com/cmyk-ux/r4y/actions/runs/45617709149 — **success** on that exact SHA. Clippy, diagnostics Clippy, build, workspace tests and the hardware-test step all completed successfully.
- New pipeline WaveSize logging commit: `6983067d76c8ad81a910ca379420d5dcefd9d228`.
- CI run #188: https://github.com/cmyk-ux/r4y/actions/runs/45618595560 — **success** on that exact SHA.
- Latest verified PR head at this addendum: `6983067d76c8ad81a910ca379420d5dcefd9d228`, PR #16 open, mergeable, 170 commits ahead and zero behind `main`.

Run #187/#188 results:
- Normal Clippy: passed.
- Diagnostics/all-features Clippy: passed.
- Main/release build: passed.
- Workspace: `214 passed; 0 failed; 2 ignored; 2 filtered out`.
- The dynamic heap stride WARP regression, gather regression and new crash reporter tests pass.
- The separate D3D12 Wave64 test executable reports success but explicitly skips because the hosted adapter reports neither 32- nor 64-lane waves. This is **not** an RTX 3070 hardware pass.

### Crash reporter enhancement

File: `crates/r4y-loader/src/crash.rs`, commit `240e0c14...`.

- Access-violation reports now preserve up to 15 bytes at the faulting instruction address when it belongs to a loaded image.
- Each unwind frame now attempts `RtlLookupFunctionEntry` and logs the runtime-function RVA interval, offset within the function, and unwind-info RVA.
- Added a test proving a function pointer into the test binary resolves to a valid x64 runtime-function range.
- This should make the next Diagnostics run's title-side null-write report more actionable even without a PDB. No title executable, game asset or minidump is needed.

### Per-shader DXIL wave-size telemetry

File: `crates/r4y-gpu/src/pipeline.rs`, commit `6983067d...`.

Each successful `shader translated` event now logs:
- `dxil_wave_size`: fixed WaveSize parsed from the emitted DXIL PSV0, or `None` if no fixed size is declared.
- `host_wave_target`: the actual D3D12 adapter wave-size range that the translator used.

This is observation only: it does not change emitted DXIL, pipeline compatibility or the translator's Wave64 fallback decisions. Use the next log to check whether any shader still emits a fixed Wave64 declaration on the RTX 3070's Wave32 target.

### Important distinction between two available log sources

- The Library file `r4y-run.log` (`turn769file0`) begins at `2026-11-25T01:56:24Z` and crashes at `01:58:44Z` (22:56–22:58 local time on 2026-11-24). Its startup has no `host wave sizes` line. It is an older run and must **not** be used as evidence that the later target-aware Diagnostics build still emitted Wave64 PSOs.
- The newer correct Diagnostics run described in section 10 is the one that logged `lanes_min=32 lanes_max=32`, freshly translated and created the two compute pipelines `88994c3496045f51` and `13dfdd3b1136e407`, then bound both on frames 1168 and 1186 before the title-side crash at 09:37:38.
- No separate full log or crashcontext file for that newer run is currently available in the Library. The handoff's section 10 contains the user-provided evidence. Do not conflate it with `turn769file0`.

### Correct next diagnostic run

The existing timing mode already isolates per-command-list GPU time; no second timing subsystem is needed:
- `R4Y_GPU_TIMING=1` makes `Host::execute` submit and fence each list separately.
- Lists taking more than 50 ms log `slow host list`.
- **Per-command GPU timestamp rows additionally require `R4Y_D3D12_DRED=1`.** `HostList::note()` records the command marker and the timestamp immediately before it only when `dred_on()` is true; that condition is controlled by `R4Y_D3D12_DRED`. Without it, list-level timing still runs, but `notes` is empty and `slow list command` has no command samples to report.
- With DRED on, R4Y also enables D3D12 auto-breadcrumb and page-fault reporting and labels host objects. This is independent of GPU-Based Validation; it does not turn GBV on.
- Without `R4Y_GPU_TIMING`, all lists are submitted as one group; the observed `slow host submission ms=5572 lists=9` cannot identify which list or command caused the delay.

The previous correct Diagnostics runtime explicitly reported `GPU-based validation on`. That is controlled independently by `R4Y_D3D12_GBV`; remove it for this run. Enable DRED specifically so the per-command timestamps and breadcrumbs are recorded, while retaining the normal default console-flow mode. Do **not** combine this first run with `R4Y_WAVE64_CONSOLE_FLOW=0`, because that would change which shaders are accepted and confound the timing comparison.

PowerShell for the next single run:

```powershell
Remove-Item Env:R4Y_D3D12_GBV -ErrorAction SilentlyContinue
Remove-Item Env:R4Y_WAVE64_CONSOLE_FLOW -ErrorAction SilentlyContinue
$env:R4Y_GPU_TIMING = "1"
$env:R4Y_D3D12_DRED = "1"
.\r4y-run.cmd
```

Keep the user's existing Diagnostics profile selection. Do not rebuild release if the installer selects diagnostics; use the installed profile's build path from sections 7–10.

After that run, collect only:
1. All `host wave sizes` and `shader translated` lines containing `dxil_wave_size` and `host_wave_target`.
2. Each `slow host list` and its following `slow list command` rows.
3. The `slow host submission`, `host pipeline refused`, `device removed`/DRED lines if any.
4. The first-chance/unhandled crash block, including the new `instruction bytes` and `function RVA` annotations.

Interpretation:
- A list consistently taking multiple seconds points to a specific GPU pass; use its pipeline and command markers to isolate the offending shader or resource path.
- If each list is short but the total frame stalls, investigate CPU submission/preparation/fence scheduling rather than one long GPU dispatch.
- If the title still crashes with GBV off and no device removal, keep the title watchdog/AV distinct from D3D12 device loss.
- After command attribution, only then perform a separate A/B with `R4Y_WAVE64_CONSOLE_FLOW=0` if the slow/failing work actually contains console-flow-dependent Wave64 compute shaders.

### No new production behavior change

The last code change only adds the two diagnostic fields to shader translation logs. The scratch indirect clamp and dynamic heap stride fixes remain unchanged and validated by CI. Do not start clamp hoisting or broad helper-lane changes before the next title run identifies the actual GPU bottleneck.


## 15. Follow-up CI and per-command timing requirement (2026-11-25)

### Exact current-head CI

- PR head: `b351848d2026ab9ecd6290faf08512829eb8c254`.
- CI run #189: https://github.com/cmyk-ux/r4y/actions/runs/45619202994 — **success on the exact PR head**.
- All steps passed: installer preflight, MSVC initialization, PowerShell native stderr test, normal Clippy, all-features/diagnostics Clippy, release build, workspace tests, and the dedicated D3D12 test process.
- Workspace: `214 passed; 0 failed; 2 ignored; 2 filtered out`.
- The dedicated D3D12 step explicitly printed `adapter supports neither 32- nor 64-lane waves; skipped`. It is not physical RTX 3070 validation.
- PR #16 is open and mergeable; branch compare is 171 commits ahead of `main`, 0 behind.

### Correction to the next Diagnostics command

The prior section's command omitted `R4Y_D3D12_DRED=1`. Source inspection of `crates/r4y-gpu/src/host.rs` showed that `HostList::note()` records per-command `EndQuery(TIMESTAMP)` and marker text only inside `if dred_on()`; `dred_on()` requires `R4Y_D3D12_DRED` in a Diagnostics build. Therefore `R4Y_GPU_TIMING=1` alone isolates and times whole command lists but cannot populate the individual `slow list command` durations.

The corrected single-run command is:

```powershell
Remove-Item Env:R4Y_D3D12_GBV -ErrorAction SilentlyContinue
Remove-Item Env:R4Y_WAVE64_CONSOLE_FLOW -ErrorAction SilentlyContinue
$env:R4Y_GPU_TIMING = "1"
$env:R4Y_D3D12_DRED = "1"
.\r4y-run.cmd
```

DRED enables auto-breadcrumb/page-fault reporting and command markers; it is independent of GBV. Keep console-flow at its default for this first attribution run.


## 16. RTX 3070 DRED run and prelude/pipeline-sync follow-up (2026-11-25)

### New user-provided Diagnostics runtime evidence

Source log: `%LOCALAPPDATA%\\R4Y\\logs\\r4y-run.log`, lines 5438–5563 (provided in chat). Title debug context: `data\\7952987A\\temp\\r4y-20261125-063738-20352.crash.log`. The user-provided `crashes.log` tail contains both title AV reports and D3D12 device-removal reports; do not conflate them.

- RTX 3070 host telemetry reports `host_wave_target=Some(Target { lanes_min: 32, lanes_max: 32 })`. Successfully translated compute shaders in this sample generally declare `dxil_wave_size=Some(32)`; vertex/pixel stages commonly have `None`. This confirms the new translation telemetry is operating on the Wave32 host.
- Some console Wave64 compute shaders remain explicitly refused (for example hashes `2cc4c197ee29e291` and `7168dd781ca7efb9`, error `console wave64 lanes on a host without 64-lane waves is not supported`). Treat these refusals as known unsupported shader coverage, not as proof of the D3D12 hang cause.
- One command was individually measured at **3089.8 ms**: `dispatch 128x64x1 [compute 42683eebec081520]`, in a list of 88 commands at 13:25:55.118 UTC. It proves at least one extremely long compute dispatch exists in this run. It has not yet been tied causally to the subsequent device removal.
- A later list reported `slow host list ms=8155 commands=26` at 13:26:03.361 UTC. Most displayed per-command values for this list were 0.0 ms; do not interpret that as proof those commands took no GPU time. The submission then reported 8.199 s across 33 lists and a D3D12 removal.
- D3D12 debug layer identified `DXGI_ERROR_DEVICE_HUNG` / `0x887A0006`, explicitly describing a TDR after the device took an unreasonable time to execute commands.
- Breadcrumb output included `59/62` with op 6 (`DISPATCH`) and an unmapped list owner (`None` in the old reporter output), plus another in-flight region associated with a 26-command list. The unmapped 62-command node has not been proven to be a prelude yet; new instrumentation must establish its owner before assigning the cause.
- The title's debug snapshot reported TileHeap 2562/6236 MiB and near-full title physical memory/pool counters. This makes memory/streaming pressure a secondary possibility, but it does not prove OOM and does not replace the D3D12 TDR evidence.
- The same `crashes.log` tail repeats the title watchdog null-write at `r4y-image-...+0x23cf683` (write to unmapped address 0). Keep this title-side watchdog exit separate from a D3D12 device-removal failure.

### Code changes committed to the existing PR branch

All changes are on `feature/wave64-host-target`, which updates PR #16. The PR remains open.

1. `6493f7dbbaf9efc6396618b34a8c381594833a16` — `crates/r4y-gpu/src/list.rs`: pipeline sync is no longer a no-op. It records a global UAV barrier on the current host command list. Added a unit test for the null-resource global barrier payload. This ports the underlying idea from the experimental VIctory branch `Dufftwt/VIctory:test/world-stack-sync`; that experiment is not itself proof of an in-game fix.
2. `fefb86e1c27a18da93d86049cd6c5c5ddc90dcbe` — `crates/r4y-gpu/src/twin.rs`: depth-twin conversion now emits a diagnostic marker immediately before each internal converter dispatch, including direction, subresource, dimensions, format and pitches.
3. `e841f47dc74ce3351fb913894d7dd12002945d59` — `crates/r4y-gpu/src/host.rs`: DRED breadcrumb ownership now checks both each HostList's main list and its prelude list. Prelude markers are tracked separately from main-list notes and paired with the matching breadcrumb history. This should turn a former owner `None` into `prelude=Some(index)` if the stopped list is one of R4Y's auxiliary preludes, and show the exact converter dispatch marker if that is where it stopped.

### Validation state and cautions

- GitHub Actions CI run #195 for exact head `e841f47dc74ce3351fb913894d7dd12002945d59` was observed in progress at the time of this handoff update: https://github.com/cmyk-ux/r4y/actions/runs/45630873449
- The latest file snapshots confirm all three edits are present. CI outcome is not yet known; do not claim the code compiles until run #195 completes successfully.
- No post-change RTX 3070 game run has been performed. The pipeline-sync barrier is a correctness-oriented change that may alter ordering/performance; real title A/B remains mandatory.
- The 3089.8 ms compute dispatch hash `42683eebec081520` remains a separate candidate to inspect. Do not assume it is the command that triggered the later TDR.
- Keep PR #16 open. Do not merge or mark the runtime issue resolved on CI success alone.

### Next steps

1. Check CI #195 to completion and inspect exact failure logs if any.
2. On success, have the user update/build the Diagnostics profile at this branch head and repeat the same title path with `R4Y_GPU_TIMING=1` and `R4Y_D3D12_DRED=1`, with `R4Y_D3D12_GBV` and `R4Y_WAVE64_CONSOLE_FLOW` unset as in section 15.
3. Keep the next extraction narrow: the DRED `host GPU failure` line and its associated `breadcrumbs`, `a list stopped at`, `commands ... between its barriers`, and converter marker lines; plus only the `slow host list` block if a new one occurs.
4. Compare whether pipeline sync barriers change the TDR behavior. If the device still stops in a prelude converter dispatch, investigate the conversion's resource states, source/destination footprints, and the exact stopped route before changing its shader.
5. Inspect the `42683eebec081520` dispatch independently if it remains a multi-second outlier; it is not yet causally linked to the later removal.


### First CI failure and compile-fix follow-up (2026-11-25)

- CI #195 on `e841f47` was **cancelled after Clippy failed**. The actual compile diagnostics were:
  1. `host.rs` referenced `prelude_notes` from a code path compiled without the `diagnostics` feature; the field itself is diagnostics-gated.
  2. `twin::route()` was a second production callsite of `Twin::copy` and also needed the new marker callback.
  3. The destination footprint is `D3D12_PLACED_SUBRESOURCE_FOOTPRINT`; its nested layout is `.Footprint.Format` and `.Footprint.RowPitch`, not direct `.Format` / `.RowPitch`.
- Corrections:
  - `9a5c387033b87c52e9815b7820b2ac2202da6cf6`: updated the second `Twin::copy` call in `twin::route()` to attach the per-dispatch marker to the main list too, and corrected the nested destination footprint fields.
  - `6b4c0b93d2c8322220e96c936721a4f495196c7e`: kept the no-completed-command fallback for prelude metadata inside the diagnostics feature gate.
- Latest exact code commit at this note: `6b4c0b93d2c8322220e96c936721a4f495196c7e`.
- CI run #198 for that exact code commit was queued when this note was written: https://github.com/cmyk-ux/r4y/actions/runs/45631278366. Do not claim success until completed.
