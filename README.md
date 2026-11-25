<img width="1122" height="634" alt="R4Y BOOTSTRAP" src="https://github.com/user-attachments/assets/411698af-0b0a-40cd-b0a9-b13911317a3d" />

# R4Y — Recompile4You

**An experimental Xbox Series X|S (Scarlett/GDK) compatibility layer for Windows, written in Rust.**

R4Y runs user-provided x64 title executables on the Windows CPU and recreates selected console services and graphics interfaces on the host. It combines a PE32+ loader, a high-level emulation (HLE) layer for console APIs, a D3D12 backend, and an RDNA2/GFX10 shader translator that emits DXIL for Windows D3D12.

R4Y is a compatibility runtime, not a full hardware emulator. The goal is to execute native title code while implementing or adapting the platform interfaces it expects—not to simulate an entire console.

> **Status: experimental.** API coverage, file formats, graphics features and shader patterns are incomplete. Compatibility and performance vary by title build, scene, Windows version, GPU and driver. R4Y is an active research project, not a production-ready or turnkey gaming application.

## Runtime at a glance

| Component | What it does | Status |
|---|---|---|
| PE32+ loader | Maps x64 images, applies relocations, resolves IAT imports and sets up TLS | Experimental |
| Console API HLE | Implements selected KernelX, XGameRuntime, XMem, storage, media and DirectStorage interfaces | Partial |
| D3D12_XS backend | Adapts console graphics objects, resources, descriptors and command lists to host D3D12 | Experimental |
| Shader translation | Decodes GFX10/RDNA2 shader programs and emits DXIL for host pipelines | Partial |
| Formats | Handles selected texture tiling/swizzle layouts, BCPack data and XMA2 audio | Partial |

Unsupported imports and shader patterns are not silently assumed to work. Host pass-through is controlled by policy, and unimplemented imports can be configured to trap or use the runtime's explicit fallback behavior.

## Project layout

| Area | Location | Purpose |
|---|---|---|
| User-facing executable | `apps/r4y` | CLI for inspection, import census, shader tools, configuration and execution |
| PE loader | `crates/r4y-loader`, `crates/r4y-pe` | PE32+ image mapping, imports, relocations and TLS |
| Console runtime | `crates/r4y-hle` | KernelX, XGameRuntime and other HLE implementations |
| D3D12 backend | `crates/r4y-gpu` | D3D12_XS objects, GPU memory, descriptors, command lists and host D3D12 |
| Shader translator | `crates/r4y-shader` | GFX10/RDNA2 decoding, shader structure and DXIL emission |
| Formats and title metadata | `crates/r4y-formats`, `crates/r4y-game` | Texture/audio formats, title build identities and pipeline metadata |
| Cache and configuration | `crates/r4y-pipeline`, `crates/r4y-core` | Content-addressed caches, paths, logs and runtime policy |
| Repository tools | `xtask`, `tests` | Asset-policy enforcement, hooks and regression tests |

The project is maintained as one Rust workspace and one integrated runtime. Installation does not download, clone or select a separate backend.

## Requirements

For a local Windows build:

- Windows 10/11 x64 and a CPU with AVX2.
- Rustup using the toolchain pinned in `rust-toolchain.toml`.
- Visual Studio 2022 C++ Build Tools and a Windows SDK.
- A D3D12 adapter. Shader Model 6.6, mesh-shader and wave-operation support are required for the corresponding graphics paths; support varies by GPU and driver.
- DXC 1.8 or newer is recommended for offline shader validation and development.

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

3. Follow the prompts to select your game folder and executable. The installer checks prerequisites, writes local configuration under `%LOCALAPPDATA%\R4Y`, builds `r4y.exe` and validates the selected executable.

4. Start the configured title:

   ```cmd
   r4y-run.cmd
   ```

The game directory is not modified by the installer. The first Rust build downloads dependencies and compiles the workspace; later builds reuse Cargo's target directory and R4Y's shader and pipeline caches.

### Installer options

Run `r4y.cmd --help` for the current help text.

| Option | Behavior |
|---|---|
| `--dry-run` | Check prerequisites without installing or writing setup files |
| `--no-build` | Save local game/config selection but skip compilation |
| `--no-run` | Build and validate without offering to launch |
| `--yes` | Accept prerequisite-installation prompts |
| `--test` | Run `cargo test --workspace --locked` before building |
| `--diagnostics` | Build the diagnostics profile instead of the normal release profile |
| `--launch` | Launch the last configured title without running setup |
| `--check-msvc` | Validate the Visual C++ build environment and exit |
| `--test-native-output` | Maintainer check for native stderr handling in Windows PowerShell 5.1 |

## CLI

The executable is `target\release\r4y.exe`.

```powershell
# Inspect a PE image and its imports
target\release\r4y.exe inspect .\path\to\title.exe --imports

# Summarize imported APIs and runtime coverage
target\release\r4y.exe census --missing

# Translate shader containers and validate emitted DXIL
target\release\r4y.exe translate .\path\to\shader-data --validate --list

# Show resolved paths and configuration
target\release\r4y.exe config

# Prepare and bind a title; --execute starts it
target\release\r4y.exe run .\path\to\title.exe --execute
```

The installer creates `%LOCALAPPDATA%\R4Y\r4y.toml`. For a manual setup, create that file with a minimal configuration:

```toml
[paths]
game_dir = 'D:\R4Y-data\game'
# cache_dir = 'D:\R4Y-data\cache'
# data_dir = 'D:\R4Y-data\data'
```

Set `R4Y_CONFIG` to use an alternate configuration file.

## Build and test

```powershell
rustup toolchain install
cargo xtask policy
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo build --release --locked -p r4y
```

The executable is written to `target\release\r4y.exe`.

For the diagnostics profile:

```powershell
cargo build --profile diag --locked -p r4y --features diagnostics
```

## Diagnostics

The public environment variables use the `R4Y_` prefix. A diagnostics build is required for the D3D12 debug layer, GPU-based validation and DRED.

```powershell
$env:R4Y_LOG = 'info'
$env:R4Y_D3D12_DEBUG = '1'
$env:R4Y_D3D12_DRED = '1'
$env:R4Y_D3D12_GBV = '1'
r4y-run.cmd
```

Useful switches include `R4Y_GPU_TIMING=1` for GPU timings and `R4Y_D3D12_WARP=1` for the software adapter in diagnostics builds. Diagnostic output and runtime data are stored outside the repository under `%LOCALAPPDATA%\R4Y`.

## Known limitations

Some drivers reject the console-sized shader-visible descriptor heap. In that case R4Y uses a capped fallback with separate regions for mirrored title descriptors, transient allocations, persistent descriptor pairs and null sentinels. This avoids aliasing transient allocations, but **it is not complete descriptor virtualization**: title indices beyond the mirrored prefix are not preserved yet and may resolve to null. See [issue #4](https://github.com/cmyk-ux/r4y/issues/4).

Shader and API coverage is also partial. A successful build does not imply that a particular title, scene or GPU path is fully compatible.

## Development documentation

- [Architecture and runtime flow](docs/architecture.md)
- [Asset and test-data policy](docs/asset-policy.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License and notices

R4Y is distributed under GPL-3.0-or-later. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for license information and required source attributions.

R4Y does not distribute game files, keys, executables, generated shaders, saves or other copyrighted game assets. It does not decrypt files or bypass platform protection. Users must supply files they are legally entitled to use, already readable on disk.
