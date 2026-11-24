# R4Y integration architecture

R4Y is one Rust workspace and one runtime. The implementation is maintained in this repository; installation never clones another runtime into a nested source directory.

## Base and selected ports

The workspace starts from current [Marvisak/VIctory](https://github.com/Marvisak/VIctory) `main` at `70564ae` (2026-11-24), rather than the older `ffe310e` nested checkout in the original installer. The VIctory crate boundaries remain intact so fixes can be tested at the layer where they belong.

MineVIctory/fxceless changes are ported selectively. Each port must be rebased against the new base and have a test or benchmark appropriate to its behavior. A fork commit is not merged wholesale.

XCL is a reference for diagnostics, preflight, Wave64 and selected D3D12 scheduling ideas. Its independent PE loader, HLE runtime, D3D12 implementation and direct-DXIL compiler are not bundled as a second runtime. Leonida informs only the small Windows installer and prerequisite-check flow, not its separate asset pipeline.

## Runtime flow

1. The installer checks Windows, CPU, Rust, MSVC and Windows SDK prerequisites.
2. The user selects their already-readable game folder and executable.
3. R4Y writes a local `r4y.toml` and user-data/cache directories below `%LOCALAPPDATA%\R4Y`.
4. Cargo builds the single `r4y` package from this workspace.
5. R4Y inspects the selected executable and then launches it through the same runtime.

The game directory is read-only from the installer's point of view. Generated config, caches, pipeline libraries, logs, reports and saves stay outside the Git working tree.

## Configuration compatibility

New user-facing variables use `R4Y_*`. The core still accepts the older `VICTORY_*` names as compatibility aliases while the implementation is consolidated. The default local root is `%LOCALAPPDATA%\R4Y`; old VIctory data is not deleted or moved automatically.

## Known integration work

The highest-priority work is listed with issue/PR evidence and adoption status in [SOURCE_MAP.md](SOURCE_MAP.md). In particular:

- port the per-command-list shadow-buffer state tracking proposed by VIctory #479, which is not in the current main baseline;
- make the actual D3D12 adapter explicit and log it, rather than relying on DXGI's default adapter;
- rebase MineVIctory's unique shader optimizer and Wave64 safety changes against the current workspace;
- compare shader validator and descriptor/texture freshness proposals against current main before porting.

## Repository policy

The workspace retains the upstream asset policy and `cargo xtask policy`. Tests use synthetic data or paths supplied by the developer; game data, shader dumps, executables and other title-derived assets do not belong in issues or pull requests.
