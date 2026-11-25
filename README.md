<img width="1122" height="634" alt="R4Y BOOTSTRAP" src="https://github.com/user-attachments/assets/411698af-0b0a-40cd-b0a9-b13911317a3d" />
# R4Y — Recomp4You

R4Y is an experimental Windows compatibility engine for running Xbox Series X|S title builds from game files that users already own and can read on disk.

R4Y is maintained as a single, self-contained Rust workspace. The loader, console API layer, D3D12 backend, shader translator, format handling, command-line tools, tests and Windows installer are developed together. Installation does not download or select a separate runtime.

## Project approach

R4Y has its own workspace structure, runtime integration and implementation decisions. Development is guided by reproducible bug reports, public technical discussions, targeted experiments and regression tests. Relevant findings are evaluated for the R4Y architecture, adapted locally and tested where a reproducible test is available; external workarounds are not assumed to apply automatically.

Keyboard input is handled through R4Y's integrated input path. Its current behavior follows a familiar console-compatibility model while remaining part of the R4Y runtime.

> **Status: experimental.** Boot, menus and portions of the rendering path are under active development. Compatibility, stability and performance vary by title build, hardware and driver. The figures below are early observations from the current local test configuration, not universal benchmarks or performance guarantees.

## Current performance observations

| Runtime area | Observed average |
|---|---:|
| Gameplay | approximately **5 FPS** |
| In-game menu | approximately **30 FPS** |

These results are configuration-specific and should be treated as an early baseline. Actual performance depends on hardware, graphics drivers, title build, scene complexity and runtime configuration.

R4Y does not distribute game files, keys, executables, shaders, saves or other copyrighted game assets. It does not decrypt files or bypass platform protection. Users must provide their own legally obtained files, already readable on disk.

## Repository layout

| Area | Location | Purpose |
|---|---|---|
| User-facing executable | `apps/r4y` | R4Y CLI: inspect, census, shader tools, configuration and run |
| PE loader | `crates/r4y-loader`, `crates/r4y-pe` | Map and bind the title executable and title DLLs |
| Console runtime | `crates/r4y-hle` | Xbox API/HLE implementations and host pass-through |
| D3D12 backend | `crates/r4y-gpu` | Resource copies, descriptors, command lists and host GPU execution |
| Shader translator | `crates/r4y-shader` | RDNA2 decoding and DXIL emission |
| Formats and title data | `crates/r4y-formats`, `crates/r4y-game` | Texture/audio/archive formats and title-specific pipeline metadata |
| Cache and configuration | `crates/r4y-pipeline`, `crates/r4y-core` | Content-addressed cache, logs, paths and runtime policy |
| Repository tools | `xtask`, `tests` | Asset policy, hooks and tests |

The public application, internal crates, configuration, launchers and user-data directories use the **R4Y** identity.

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

3. The installer checks Windows, Rust and MSVC prerequisites, lets you select your game folder and executable, writes local configuration under `%LOCALAPPDATA%\R4Y`, builds `r4y.exe` and validates the selected executable.

4. Start the configured title with `r4y-run.cmd`. The game directory is not modified.

The first Rust build downloads dependencies and compiles the workspace. Later builds reuse Cargo's target directory and the runtime's shader and pipeline caches.

## Installer options

```text
r4y.cmd [--dry-run] [--no-build] [--no-run] [--yes] [--test] [--diagnostics] [--help]

  --dry-run      Check prerequisites without installing or writing setup files
  --no-build     Save local game/config selection but skip compilation
  --no-run       Build and validate without offering to launch the game
  --yes          Accept the installer's prerequisite-installation prompts
  --test         Run cargo test --workspace --locked before building
  --diagnostics  Build the diagnostics profile instead of the normal release profile
  --check-msvc   Validate the Visual C++ build environment without installing
  --help         Show the available options
```

These options control the single R4Y workspace. No additional runtime is downloaded or selected.

## Manual build

Requirements: Windows 10/11 x64, a CPU with AVX2, the Rust toolchain pinned by `rust-toolchain.toml`, Visual Studio C++ Build Tools and a Windows SDK. A D3D12 adapter with Shader Model 6.6 and the required mesh/wave features is needed for the relevant rendering paths. DXC 1.8+ is recommended for offline shader translation and validation.

```powershell
rustup toolchain install
cargo xtask policy
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
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

The installer creates `%LOCALAPPDATA%\R4Y\r4y.toml` automatically. For a manual setup, create that file with a minimal configuration such as:

```toml
[paths]
game_dir = 'D:\R4Y-data\game'
# cache_dir = 'D:\R4Y-data\cache'
# data_dir = 'D:\R4Y-data\data'
```

`R4Y_CONFIG` selects an alternate configuration file.

## Diagnostics

The public environment variables use the `R4Y_` prefix.

```cmd
set R4Y_LOG=info
set R4Y_D3D12_DEBUG=1
set R4Y_D3D12_DRED=1
set R4Y_PIPELINE_WAIT_MS=24
r4y-run.cmd
```

`R4Y_PIPELINE_WAIT_MS` optionally sets the total time all render threads may wait
for unfinished host pipelines during one title frame (default: `500` ms). A
smaller value reduces render-thread stalls but can omit draws until their
pipelines are ready; `0` disables waiting. This is a tuning/diagnostic control,
not a guaranteed performance improvement.

A diagnostics build is required for the D3D12 debug layer, DRED and debug-only switches. The installer does not enable these in a normal release build. Diagnostic output and runtime data are stored outside the repository under `%LOCALAPPDATA%\R4Y`.

## Development documentation

- [Architecture and runtime flow](docs/architecture.md)
- [Asset and test-data policy](docs/asset-policy.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License and notices

R4Y is distributed under GPL-3.0-or-later. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for license information and required source attributions.
