# R4Y source map and integration decisions

**Research snapshot:** 2026-11-24  
**Target architecture:** one self-contained R4Y Rust workspace and one Windows installer. No runtime backend selector and no downloading another engine at install time.

This document records what to take, what to adapt, what to defer, and why. A repository or PR being listed here is not approval to copy it wholesale. Measurements are scoped to the machine, title build, driver and command recorded by the author.

## 1. The shape of the project

R4Y should be the product, not a wrapper around a downloaded product:

- The Rust workspace, runtime, shader translator, GPU backend, tests and command-line executable live in this repository.
- The installer is a small Windows entry point that checks prerequisites, configures local paths, builds R4Y and launches it.
- There is one runtime and one set of configuration, cache, diagnostics and user-data paths.
- Internal crate names can remain VIctory-derived initially. Renaming every crate before consolidating behavior creates churn without making the runtime better. The user-facing command and executable should become `r4y` / `r4y.exe`.
- Never replace the source checkout, reset a contributor's working tree, or store a machine-specific absolute path in a generated launcher.

The previous R4Y installer used the VIctory commit `ffe310eb` as a nested checkout. That snapshot is now **28 upstream commits behind** VIctory `main` (`70564ae`, 2026-11-24). R4Y must not be rebuilt around that old snapshot.

## 2. Repository map

| Source | Role in R4Y | Decision |
|---|---|---|
| [Marvisak/VIctory](https://github.com/Marvisak/VIctory) | Main implementation: PE loader, HLE/runtime services, D3D12.X host layer, RDNA2-to-DXIL shader translation, asset formats, pipeline/cache, command-line app and tests. | **Primary codebase.** Start from current `main` at `70564ae`, not the old R4Y nested checkout. Bring the workspace into this repository. |
| [cmyk-ux/minevictory](https://github.com/cmyk-ux/minevictory) | The user's VIctory-derived fork. Holds targeted render, shader, GPU-memory and performance experiments plus a shader clean-up optimizer. | **Selective port source.** Preserve useful independent changes, but rebase and test them individually against current VIctory. Its current head is the old `fxceless/victory-fork` head, not current upstream. |
| [fxceless/victory-fork](https://github.com/fxceless/victory-fork) | Origin of the current MineVIctory fork. Its issues/PRs contain concrete workarounds and measurements on NVIDIA hardware. | **Research history for MineVIctory.** Do not merge the 68-file fork commit as one unit. Split useful behavior into separately tested R4Y changes. |
| [xcl-dev/xcl](https://github.com/xcl-dev/xcl) and [cmyk-ux/minexcl](https://github.com/cmyk-ux/minexcl) | Independent Xbox Series compatibility implementation. Its strongest value here is comparative behavior, preflight/reporting, Wave64 research and isolated GPU algorithms. | **Reference and targeted algorithm source, not a second runtime.** Do not add a second engine, PE loader or parallel HLE stack to R4Y. |
| [cmyk-ux/Leonida](https://github.com/cmyk-ux/Leonida) | Existing one-click installer, prerequisite-check and build orchestration work. Its main asset pipeline is a separate, very large Vulkan/SPIR-V project. | **Installer pattern only.** Reuse the small CMD/PowerShell bootstrap and preflight ideas. Do not import the 400-GB asset pipeline, Python/.NET/Vulkan/LLVM dependency stack or Leonida runtime. |

### VIctory code to bring in as the base

The workspace is already divided along useful boundaries. Keep those boundaries in the initial R4Y import:

| Path | Responsibility |
|---|---|
| `apps/victory` | User-facing CLI, run/inspect/translate/prebuild commands; the R4Y executable identity belongs here. |
| `crates/victory-loader`, `victory-pe` | PE preparation, mapping, import binding, title DLLs, TLS and crash reporting. |
| `crates/victory-hle` | Console API/runtime shims and host pass-through policy. |
| `crates/victory-gpu` | D3D12.X objects, command lists, descriptor/view management, resource copies, synchronization and host GPU submission. |
| `crates/victory-shader` | RDNA2 decoding, control-flow/SSA analysis, shader lowering and DXIL emission. |
| `crates/victory-formats`, `victory-game` | Texture/audio/archive formats and title-specific data/pipeline descriptions. |
| `crates/victory-pipeline`, `victory-core` | Content-addressed caches, config, logging and asset-policy guards. |
| `xtask`, `tests`, `.githooks` | Repository policy, reusable fixtures, test harnesses and contributor checks. |

The current upstream tree has 174 tracked files. Its recent 28-commit movement touches 76 files, especially GPU descriptor/draw/host/memory/cache code, shader analysis/tests, game pipeline discovery and HLE FidelityFX/XMem. This is why the base is the current workspace rather than the 2026-11-24 R4Y nested checkout.

## 3. Known issues and changes that should guide the first integration

### P0 — RTX 3070 shadow-buffer state tracking

- [VIctory issue #445](https://github.com/Marvisak/VIctory/issues/445) records an RTX 3070 8 GB + Ryzen 7 5800X machine and a D3D12 device removal after a long command-list submission. The report includes a shader that could not translate, slow submission, and later device removal; it explicitly says the translation refusal is not proven to be the direct cause.
- [VIctory PR #479](https://github.com/Marvisak/VIctory/pull/479) proposes the concrete buffer-state fix: track each host-side shadow copy's state per command list; transition vertex, index, root/table SRV/UAV/CBV and indirect-argument uses into valid D3D12 states; settle read/write uses together; return copies to COMMON on list close.
- **Status:** PR #479 is closed without a merge. The `want_buffer`, `buffer_state` and `settle_buffers` implementation is absent from both current upstream `main` and `minevictory`.
- **R4Y action:** port this as a focused GPU change, retaining its per-list lifetime/state model and tests. Then validate on the RTX 3070 with the D3D12 debug layer and DRED. Do not label it the cause of every device removal until the debug layer identifies a matching invalid transition.

This is the first GPU correctness task because it has a directly relevant hardware report and a narrowly defined proposed fix.

### P0 — GPU adapter identity must be explicit

- [VIctory PR #1630](https://github.com/Marvisak/VIctory/pull/1630) documents a machine with an RTX 4090 and an AMD iGPU where `D3D12CreateDevice(None, ...)` selected the iGPU. The author corrected the adapter selection/logging and added a texture-description fallback ladder and presenter backoff.
- Current upstream `crates/victory-gpu/src/host.rs` still creates the normal device with `D3D12CreateDevice(None, ...)`; only its diagnostics WARP path explicitly selects an adapter.
- **R4Y action:** add explicit adapter enumeration/selection and log the actual D3D12 adapter name, vendor, device ID, driver and wave width. The installer must not infer the runtime GPU solely from WMI's display-controller list. Keep adapter selection consistent between preflight and runtime device creation.

### P1 — Compute shaders rejected only by the DXIL validator version

- [VIctory PR #1065](https://github.com/Marvisak/VIctory/pull/1065) uses validator 1.8 only for compute shaders that actually emit gradient operations. Older validator metadata rejects valid compute-stage derivatives.
- On the old `ffe310e` baseline, the PR's offline measurement moved 24 compute programs from rejected to valid, with no vertex/pixel or mesh regressions. The issue #1247 benchmark later measured current `70564ae` at 24,785 validated programs; current `70564ae` plus rebased #1065 measured 25,520 (+735 compute, zero lost).
- **Status:** open; the head and conflict state can change. These are offline translation/validation measurements, not a live gameplay result.
- **R4Y action:** rebase the minimal validator/PSV0 change onto the imported source, run the regression tests, and verify the Windows host runtime accepts validator 1.8 before enabling those containers.

### P1 — Keep MineVIctory's unique shader optimizer, but prove it again

- MineVIctory commit `6a2d9f9` adds a post-lowering optimizer in `crates/victory-shader/src/emit/bitcode/opt.rs`: dead-code elimination, integer constant folding/identities, safe value reuse, branch facts and block-local load reuse.
- The fork README claims about 43% fewer host instructions and about 20 ms less GPU time per frame on its RTX 4070 test machine. This is a single-machine result, not evidence for the RTX 3070.
- The optimizer deliberately avoids unsafe floating-point identities; its bit-mask/settings must be included in the shader-cache fingerprint.
- **R4Y action:** port behind an explicit setting, preserve/extend semantic tests, include every setting in the cache key, and benchmark both shader output and GPU time on the RTX 3070. Keep it off by default until equivalence and performance are demonstrated.

### P1 — MineVIctory's Wave64 safety fix is conditional, not a general Wave64 solution

- MineVIctory commit `e9765a7` found that a newer two-host-wave Wave64 form could place group barriers inside divergent branches/loops and hang the GPU. It made that form opt-in via `VICTORY_WAVE_WIDE=1` and added the wave switches to the shader-cache key.
- **R4Y action:** preserve this safety rule if the corresponding wave64 lowering is brought forward. Never enable the wide/barrier form by default on 32-lane hardware. The fix is specific to that fork's lowering; do not copy it as a generic switch without the matching code and tests.

### P1 — Descriptor/view freshness and texture write invalidation

- [VIctory PR #1544](https://github.com/Marvisak/VIctory/pull/1544) adds live-slot generations and forgotten-resource epochs so bindless ResourceDescriptorHeap views and shadow copies are refreshed before a draw/dispatch. Tested on an RTX 5060 Ti with GPU unit tests; no retail gameplay measurement is stated.
- [VIctory PR #1547](https://github.com/Marvisak/VIctory/pull/1547) invalidates host-copied textures when write-watch shows the title wrote their source memory later. It also has GPU unit tests, tested on an RTX 5060 Ti.
- **Status:** both open at research time.
- **R4Y action:** compare each patch with current `70564ae` file-by-file; take only missing logic, retaining the generation/epoch and write-watch tests. These address stale descriptor/texture contents, not every black frame or TDR.

### P1 — Mesh fallback is a compatibility feature, not the RTX 3070 fix

- [VIctory PR #961](https://github.com/Marvisak/VIctory/pull/961) translates a mesh shader to compute-written vertex/index/primitive buffers plus a generated vertex shader when the host lacks mesh shaders or a mesh output exceeds D3D12's 32 KiB limit. It includes synthetic image-equivalence, buffer-content and indirect tests on a GTX 1060 and WARP.
- [VIctory PR #1759](https://github.com/Marvisak/VIctory/pull/1759) is a narrower Wave32 numerical-mask materialization proposal for specific mesh masks, with native GPU fixture tests. It is not a complete Wave64-on-Wave32 implementation.
- **R4Y action:** retain as candidates for adapters without native mesh support and specific Wave32 mask cases. Do not treat either PR as a proven solution to the RTX 3070's full world-rendering problem; rebase and test on NVIDIA before enabling.

### P2 — Pipeline, resource and upload performance candidates

| Change | Evidence and decision |
|---|---|
| [VIctory #1382](https://github.com/Marvisak/VIctory/pull/1382) | Batches/coalesces barriers, reuses draw scratch arrays, range-locks descriptor copies and pools command-list uploads. It reports GPU/WARP tests and clippy, but no live-title frame-time result. Consider after P0 correctness work and profile CPU submission. |
| [VIctory #1653](https://github.com/Marvisak/VIctory/pull/1653) | Shards the >600 MB host pipeline library so saves write only dirty shards. The submitted synthetic benchmark shows benefit when few shards are dirty; its author explicitly notes no measured live-title save wall time. Defer until R4Y profiles real cache-save cost. |
| [VIctory #1680](https://github.com/Marvisak/VIctory/pull/1680) | Replaces one global pipeline-library mutex with 64 striped name locks and controlled save locking. RTX 4070 Ti report says early pipeline loads drained in ~30 s instead of ~3.5 min. Rebase and measure on the current source before adopting. |
| [VIctory #1687](https://github.com/Marvisak/VIctory/pull/1687) | Adds comparison gathers and immediate-offset sample lowering with DXIL/WARP tests. Useful only if current upstream still refuses those exact shader forms. |
| [MineVIctory PR #147](https://github.com/fxceless/victory-fork/pull/147) | Shader-source-based cache fingerprint and limiting early pipeline workers to avoid title CPU starvation. Check current upstream's cache fingerprint and prebuild first; do not duplicate existing behavior. |
| [MineVIctory PR #144](https://github.com/fxceless/victory-fork/pull/144) | Directly binds 256-byte-aligned table CBVs from shadow buffers. Candidate for reducing copies, subject to resource lifetime and per-list state tracking. |
| [XCL PR #1747](https://github.com/xcl-dev/xcl/pull/1747) | Tile-mapping pool/batching reported 14.3× faster GPU completion and 21.8× faster CPU submission on an RX 9070 XT. Strong algorithmic reference, but not yet validated on NVIDIA or proven equivalent in VIctory's allocation path. |
| [XCL PR #1791](https://github.com/xcl-dev/xcl/pull/1791) | Reports stale `ExecuteIndirect` arguments after a dispatch on an RTX 5090 and uses a private 256-byte indirect-argument transition workaround. One hardware/title report only; investigate only if R4Y reproduces the same ordering failure. |
| [XCL PR #455](https://github.com/xcl-dev/xcl/pull/455) | Async texture upload scheduling without a CPU wait on the submitting DIRECT queue. Port the scheduling idea only if R4Y profiling finds the same cross-queue CPU stall. |
| [XCL PR #1592](https://github.com/xcl-dev/xcl/pull/1592) | DRED markers identifying the pipeline at GPU fault. A diagnostics improvement if R4Y's DRED path does not already identify the failing operation sufficiently. |

## 4. What not to merge wholesale

### The old fork snapshot

The current MineVIctory head is still based on the `fxceless/victory-fork` commit derived from VIctory `ffe310e`. Its large initial change is a 68-file squash. It contains valuable features, but current upstream has moved in 76 files since that base. Merging the old fork tree wholesale would replace newer upstream work with stale code and conceal overlaps.

### The XCL runtime and direct-DXIL backend

XCL is an independent PE loader/HLE/D3D12 runtime, not a module collection inside VIctory. VIctory already has its own loader, HLE, GPU runtime and HLSL→DXIL translator. Bringing in XCL's entire runtime would create two implementations of the same layers in one R4Y process.

- [XCL PR #1426](https://github.com/xcl-dev/xcl/pull/1426) merged a direct RDNA2→DXIL backend, but the design document dated 2026-11-24 says live routing is opt-in and phases 4–6 remain partial: compute/mesh-compute and some graphics fall back to HLSL; corpus coverage and live-title runs were not yet measured.
- [XCL PR #1745](https://github.com/xcl-dev/xcl/pull/1745) adds a per-lane direct-DXIL form, but its measured compute result was about 0.98× versus the existing per-instruction form (no speed gain).
- The direct-DXIL work is technically interesting, but it is a separate compiler backend with its own SSA, resource ABI, tests and coverage gaps. Keep it as future research, not part of the first R4Y consolidation.

### Wave64 shortcuts that avoid the hang by dropping the picture

- [VIctory PR #578](https://github.com/Marvisak/VIctory/pull/578) refused Wave64 mesh/compute pipelines on 32-lane hosts to avoid a TDR. NVIDIA reports in [issue #778](https://github.com/Marvisak/VIctory/issues/778) show that this can drop most world draws and leave the world black. Treat it as a safety fallback only, never the intended RTX 3070 solution.
- XCL's split-Wave64 design is a useful reference for masks, lane exchange and barriers, but its current tests are not proof of full VIctory shader equivalence on the RTX 3070. VIctory's Wave64 mesh and VS/PS paths must be ported with hardware tests, not a permissive flag.

## 5. Installer: reuse the small part of Leonida

R4Y's installer should do only the work needed to build and launch this single workspace:

1. Detect Windows x64 and the CPU instruction set requirements; check available commit/page-file headroom.
2. Detect the actual D3D12 adapter, Shader Model 6.6, mesh-shader tier, wave width, and DXC/validator version. Explain a missing capability and what it affects; distinguish a warning from a hard blocker.
3. Check the Rust toolchain pinned by `rust-toolchain.toml`, MSVC C++ build tools and the Windows SDK.
4. Ask for the user's already-readable game folder and executable; keep the game directory read-only.
5. Write one local R4Y config and user-data/cache roots under `%LOCALAPPDATA%\R4Y\`; migrate any old `%LOCALAPPDATA%\victory\data` only after an explicit prompt, without deleting the original.
6. Run `cargo test --workspace` (optional on repeat installs), build one `r4y.exe`, validate the selected executable, and offer to launch.
7. Keep a transcript/log, return the true failure code, and never store absolute developer-machine paths in generated launcher scripts.

Reuse Leonida's one-click CMD/PowerShell handoff, consent-based prerequisite installation and resumable build mindset. Do not bring over its Python 3.12, .NET 8, Vulkan SDK, LLVM AMDGPU toolchain or multi-hundred-GB asset pipeline; those belong to Leonida's separate SPIR-V/asset workflow, not this D3D12 Rust runtime.

## 6. Integration order

1. Import VIctory `70564ae` as the one R4Y source workspace; rename the user-facing app/command to R4Y without renaming every internal crate.
2. Port and test buffer shadow-state tracking from #479, and add explicit real-adapter selection/logging from #1630.
3. Rebase the selected MineVIctory shader optimizer and Wave64 safety changes; add semantic and cache-key tests before enabling any new path.
4. Rebase missing shader compatibility work such as #1065, and compare descriptor freshness/texture invalidation PRs #1544/#1547 against the new base.
5. Profile and then select pipeline, tile-mapping and upload optimizations. Each should have a narrow benchmark and a reproducible test.
6. Add the one-click installer and contributor/CI workflow after the self-contained R4Y workspace builds and tests on Windows.

**Acceptance rule:** no change is called “fixed” because it compiles or increases offline translation counts. GPU/runtime fixes need a named hardware configuration, the title build, test duration, diagnostics/log evidence and before/after behavior. Offline shader coverage must state the corpus and validator version.
