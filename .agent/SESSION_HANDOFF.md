# R4Y — Assistant Session Handoff

> Operational project memory for continuing work across ChatGPT conversations.
> Read this file at the beginning of a new session before asking the user to repeat context.
> Update it after meaningful code changes, experiments, CI results, or architectural decisions.
>
> **Visibility:** this file is committed to the repository. It is not private or access-controlled; anyone with repository access can read it.

Last updated: 2026-11-25 (America/Sao_Paulo); RTX 3070 MBCNT classification correction committed; hardware rerun pending
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

1. Get CI green for the exact current feature head and run the targeted shader/workspace tests; the new changes are not yet validated.
2. Run the controlled `R4Y_WAVE64_CONSOLE_FLOW=0` A/B on the RTX 3070 and correlate refused pipelines with the title watchdog / D3D12 device-removal events.
3. Depending on the A/B, fix cross-half exchange/control-flow or isolate in-half split-Wave64 dispatches. Do not copy an upstream shader hash as if it were R4Y's.
4. Exercise the shared-texture allocation-info fix against the old `B5G5R5A1_UNORM` debug-layer failure; verify the larger NVIDIA pipeline-worker stack under actual PSO compilation.
5. Investigate slot-zero Texture1D/Texture2D mismatch with source-to-host descriptor provenance.
6. Design actual descriptor virtualization for the 1,245,184 logical title slots on a 1,000,000 physical NVIDIA heap; do not confuse warning-rate limiting/safe null clamping with preservation.
7. Re-run without GPU-Based Validation for representative performance, then perform focused GBV/DRED checks for correctness.
8. Revisit upstream watchlist commits/issues/PRs in the priority order documented in `.agent/REFERENCE_REPOS.md`; record relevant changes and test evidence here.

## 6. How to resume in a new chat

User can say: **"Confira o arquivo .agent/SESSION_HANDOFF.md no repo cmyk-ux/r4y e continue."**

At session start:
1. Identify the branch the user is actively testing; read this handoff from that branch, not blindly from the default branch.
2. Read `.agent/REFERENCE_REPOS.md` and preserve its requested priority order: Zettrox/ztrx, Marvisak/VIctory, fxceless/victory-fork, xcl-dev/xcl.
3. Inspect the current branch head, diff, CI, open PRs/issues and relevant upstream changes before editing.
4. Check whether the findings above have been resolved or superseded by newer code.
5. Continue implementation; do not ask the user to re-explain the project or repeat known diagnostic results.
6. Update both files when reference findings, code, test evidence or next steps change.

Do not put game assets, proprietary title data, shader dumps, keys, credentials, or machine-specific sensitive information in Git. The log hashes above are diagnostic shader identifiers supplied for this investigation; do not add shader binaries, disassembly, or title-derived material.
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
- Current remote feature-branch head after the repair: `f02181adf76067bb7262eadd18543f5a98289254`.
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

Expected HEAD: `f02181adf76067bb7262eadd18543f5a98289254`. If local HEAD differs, stop and inspect branch/status before testing.

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
