# R4Y integration and testing

R4Y is built and installed as one Rust workspace and one Windows runtime. All executable components, runtime services, translation layers, tests and installer entry points are maintained in this repository.

## Runtime flow

1. The installer checks Windows, CPU, Rust, MSVC and Windows SDK prerequisites.
2. The user selects a game directory and executable from files they own and can already read on disk.
3. R4Y writes local configuration to `%LOCALAPPDATA%\R4Y\r4y.toml`.
4. The workspace builds the `r4y` executable.
5. The loader inspects and maps the selected executable, HLE services resolve console imports, and the GPU and shader layers translate and submit work to the host D3D12 device.

The installer does not download a second runtime, select a backend or modify the game directory. Configuration, generated data, caches, logs and saves stay outside the source tree.

## Subsystem boundaries

- **Configuration and policy:** `crates/r4y-core`
- **PE parsing and loading:** `crates/r4y-pe` and `crates/r4y-loader`
- **Console APIs:** `crates/r4y-hle`
- **D3D12 resources and command lists:** `crates/r4y-gpu`
- **Shader decoding and translation:** `crates/r4y-shader`
- **Formats and title metadata:** `crates/r4y-formats` and `crates/r4y-game`
- **Conversion and caches:** `crates/r4y-pipeline`
- **User-facing commands:** `apps/r4y`

Changes should be implemented at the layer that owns the behavior. Keep the installer focused on setup and launch orchestration rather than runtime functionality.

## Validation sequence

Run these checks from the repository root:

```powershell
cargo xtask policy
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo build --release --locked -p r4y
```

For D3D12 or shader changes, also record the adapter, driver, Windows build and title build. Use the debug layer and DRED where applicable. The hosted CI runner cannot prove behavior that requires a specific physical GPU.

## Configuration contract

- `R4Y_CONFIG` selects an alternate TOML configuration file.
- `R4Y_GAME_DIR` selects the user's game directory.
- `R4Y_CACHE_DIR` and `R4Y_DATA_DIR` select derived-data and persistent-data directories.
- `R4Y_TEST_TITLES` provides additional title paths.
- `R4Y_FIDELITYFX_DIR` selects an optional FidelityFX directory.

Environment variables take precedence over file values. File values take precedence over defaults. All generated data must remain outside the repository.
