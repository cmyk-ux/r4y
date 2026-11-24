# R4Y — Recompile4You

R4Y is a single, self-contained Windows runtime for running Xbox Series X|S title builds from files the user already owns and can read on disk.

**The runtime lives in this repository.** R4Y does not download VIctory, XCL, or another engine during installation, and there is no runtime backend selector. The Rust workspace contains the loader, HLE services, D3D12 backend, shader translator, format handling, tests and tools.

> **Status: experimental.** Boot, menus and portions of the rendering path are under active development. Full gameplay compatibility, stable world rendering and good performance are not guaranteed. See [the source map](docs/SOURCE_MAP.md) for current known limitations, issue history and integration priorities.

R4Y does not distribute game files, keys, executables, shaders, saves or other copyrighted game assets. It does not decrypt files or bypass platform protection. Users must provide their own legally obtained files, already readable on disk.

## What is in this repository

| Area | Location | Purpose |
|---|---|---|
| User-facing executable | `apps/victory` | R4Y CLI: inspect, census, shader tools, config and run |
| PE loader | `crates/victory-loader`, `crates/victory-pe` | Map and bind the title's executable and title DLLs |
| Console runtime | `crates/victory-hle` | Xbox API/HLE implementations and host pass-through |
| D3D12 backend | `crates/victory-gpu` | Resource copies, descriptors, command lists and host GPU execution |
| Shader translator | `crates/victory-shader` | RDNA2 decoding and DXIL emission |
| Formats and title data | `crates/victory-formats`, `crates/victory-game` | Texture/audio/archive formats and GTA VI pipeline metadata |
| Cache and configuration | `crates/victory-pipeline`, `crates/victory-core` | Content-addressed cache, logs, paths and runtime policy |
| Repository tools | `xtask`, `tests` | Asset policy, hooks and tests |

Internal crate names remain VIctory-derived to preserve the workspace boundaries and reduce mechanical churn. The product executable and CLI are named **R4Y**.

## Quick start

1. Clone the repository:

   ```powershell
   git clone https://github.com/cmyk-ux/r4y.git
   cd r4y
   ```

2. Run the installer:

   ```cmd
   r4y.cmd
   ```

3. The installer checks the Windows/Rust/MSVC prerequisites, lets you choose the folder and executable from your own game files, writes local configuration under `%LOCALAPPDATA%\R4Y`, builds `r4y.exe`, and validates the selected executable.

4. Start the configured title with `r4y-run.cmd`. The game directory is not modified.

The first Rust build downloads crates and compiles the workspace; later builds reuse Cargo's target directory and the runtime's shader/pipeline caches.

## Installer options

```text
r4y.cmd [--dry-run] [--no-build] [--no-run] [--yes] [--test] [--diagnostics] [--help]

  --dry-run      Check prerequisites without installing or writing setup files
  --no-build     Save local game/config selection but skip compilation
  --no-run       Build and validate without offering to launch the game
  --yes          Accept the installer's prerequisite-installation prompts
  --test         Run cargo test --workspace --locked before building
  --diagnostics  Build the diagnostics profile instead of the normal release profile
  --help         Show the available options
```

No backend is downloaded or selected. These options only control the one R4Y workspace.

## Manual build

Requirements: Windows 10/11 x64, a CPU with AVX2, Rust toolchain pinned by `rust-toolchain.toml`, Visual Studio C++ Build Tools and a Windows SDK. A D3D12 adapter with Shader Model 6.6 and the required mesh/wave features is needed for the relevant rendering paths. DXC 1.8+ is recommended for offline shader translation and validation.

```powershell
rustup toolchain install
cargo test --workspace --locked
cargo build --release --locked -p r4y
```

The executable is `target\release\r4y.exe`.

For a diagnostics build:

```powershell
cargo build --profile diag --locked -p r4y --features diagnostics
```

## CLI

```powershell
# Inspect a PE image
target\release\r4y.exe inspect .\path\to\game.exe

# Translate and validate shaders from user-supplied files
target\release\r4y.exe translate .\path\to\shader-data --validate --list

# Show resolved paths and configuration
target\release\r4y.exe config

# Start the title
target\release\r4y.exe run .\path\to\game.exe --execute
```

Copy [`r4y.example.toml`](r4y.example.toml) to `%LOCALAPPDATA%\R4Y\r4y.toml` or let the installer generate it. `R4Y_CONFIG` selects the file. `VICTORY_CONFIG` remains a legacy alias.

## Diagnostics

The public environment variables use the `R4Y_` prefix. The launcher maps the GPU/translator controls to their existing internal names for compatibility.

```cmd
set R4Y_LOG=info
set R4Y_D3D12_DEBUG=1
set R4Y_D3D12_DRED=1
r4y-run.cmd
```

A diagnostics build is required for the D3D12 debug layer, DRED and debug-only switches. The installer does not enable these in a normal release build. Diagnostic output and runtime data are stored outside the repository under `%LOCALAPPDATA%\R4Y`.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [source/integration map](docs/SOURCE_MAP.md) before changing runtime behavior. GPU fixes should include the hardware, driver, title build, run duration, debug-layer/DRED output and before/after result. Offline shader-validation counts are useful, but they are not a substitute for a runtime test.

Do not commit game files, dumps, generated shaders, caches, logs containing title data or personal absolute paths. Issues and pull requests are welcome.

## Credits

R4Y consolidates work from the VIctory project and selectively incorporates or adapts fixes documented in [NOTICE.md](NOTICE.md) and [docs/SOURCE_MAP.md](docs/SOURCE_MAP.md). XCL and Leonida inform specific algorithms and installer behavior; they are not separate engines bundled into R4Y.

## License

See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
