# R4Y — Recompile4You

A compatibility layer that runs **Grand Theft Auto VI (Xbox Series X|S)** natively on Windows, using files **from your own copy of the game**, already readable on disk.

R4Y brings together four open-source workstreams (see [docs/INTEGRACAO.md](docs/INTEGRACAO.md) for details):

| Source | What it brings to R4Y |
|---|---|
| [Marvisak/VIctory](https://github.com/Marvisak/VIctory) | Core: loader, runtime services, D3D12 backend, and shader recompiler (RDNA2 → DXIL). **This is what `r4y.cmd` builds.** |
| [cmyk-ux/Leonida](https://github.com/cmyk-ux/Leonida) | The one-click installer model and hardware pre-check. rip. |

> [!IMPORTANT]
> This repository **does not contain the game, keys, executables, or assets**, nor does it explain how to obtain them. You need your own copy, with its files already readable on disk. Nothing here decrypts or bypasses any protection. Grand Theft Auto and related names are trademarks of their respective owners; this project is not affiliated with Rockstar Games or Take-Two.

## Status

**Not yet playable.** Progress depends on the selected core, according to the source repositories' READMEs as of 2026-11-24:

- `upstream` (VIctory): Boot, menus at 30 FPS, and world loading work; world rendering still fails or is extremely slow.
- `fork` (victory-gta6): The opening and first playable section render at 2–4 FPS; shadowed areas appear black (ray tracing is not yet working).

R4Y itself does not improve these performance figures.

## Requirements

- Windows 10/11 x64, CPU with AVX2 support.
- Direct3D 12 GPU with Shader Model 6.6 (and mesh shaders for the world).
- Several GiB of free commit available at startup (Task Manager → Performance → Memory → **Committed**). If `crashes.log` mentions error 1455, close other programs or increase the paging file.
- `r4y.cmd` installs any missing dependencies, with your confirmation, through `winget`: Git, Rustup, and Visual Studio 2022 Build Tools (C++ and Windows SDK).
- Recommended: DXC 1.8 or newer (DXC 1.7 generates significantly larger DXIL and may take a very long time to compile pipelines on NVIDIA GPUs).

## Easy Build (One Click)

1. `git clone https://github.com/cmyk-ux/r4y` (use `git clone`: `.gitattributes` converts the `.cmd` file to CRLF; downloading the ZIP may result in incorrect line endings).
2. Double-click **`r4y.cmd`**.

The script performs the following steps, in order:

1. Checks Windows, AVX2, GPU, and commit memory.
2. Lists missing dependencies and installs them with your consent.
3. Downloads/updates the core into `src\r4y-core` and applies the patches from `patches\`.
4. **Asks for the game folder and executable** you want to run (you can type the path or use the file picker; your last selection is remembered).
5. Saves the configuration outside the core repository (`config\r4y.toml`) and builds in release mode.
6. Copies the binary to `bin\r4y.exe` and validates the configuration and selected executable.
7. Creates `r4y-run.cmd` and asks whether you want to launch the game immediately.

Running it again updates the core and performs an incremental rebuild.

### Options

```text
r4y.cmd [--dry-run] [--no-build] [--no-run] [--yes] [--test] [--channel upstream|fork]

  --dry-run   only shows what's missing; makes no changes
  --no-build  prepares everything and saves the configuration, but does not build
  --no-run    builds and validates, but does not ask whether to launch
  --yes       skips installation confirmation prompts
  --test      also runs cargo test --workspace (does not use game data)
  --channel   upstream (default) or fork
```

When switching channels, `src\r4y-core` is reset to the new repository. Do not store your own changes there.

## Manual Build

```powershell
git clone --depth 1 https://github.com/Marvisak/VIctory src\r4y-core
mkdir config
copy src\r4y-core\victory.example.toml config\r4y.toml    # edit game_dir (outside src\)
$env:VICTORY_CONFIG = "$PWD\config\r4y.toml"
cd src\r4y-core
cargo build --release -p victory
target\release\victory.exe config
target\release\victory.exe run "D:\YourGame\executable.exe" --execute
```

## After Installation

Use `r4y-run.cmd`. To select another game/executable, run `r4y.cmd` again. The game folder is never modified; save files and `crashes.log` are stored in `%LOCALAPPDATA%\victory\data`.

Environment variables translated by `r4y-run.cmd`:

`R4Y_LOG`, `R4Y_D3D12_DEBUG`, `R4Y_D3D12_WARP` → `VICTORY_LOG`, `VICTORY_D3D12_DEBUG`, `VICTORY_D3D12_WARP`.

Safe mode that avoids GPU driver resets:

```cmd
set R4Y_D3D12_WARP=1
```

This renders through the software adapter and is therefore slow.

> **Warning.** Entering the game world on a physical GPU may cause the GPU to hang, forcing Windows to restart the graphics driver (your monitors will briefly go black).

## Project Structure

```text
r4y.cmd             one-click installer/updater/builder
patches/            patches applied to the core (*.patch, in order)
docs/INTEGRACAO.md  how the source projects are integrated and what was reused
NOTICE.md           credits and licenses
```

`src\`, `bin\`, `build\`, `config\`, and logs are generated locally and are excluded from git.

## Current Version Limitations

- The R4Y name is used throughout the installer, binary (`r4y.exe`), launchers, and documentation. Internal identifiers in the core code (`victory_*` crates, `VICTORY_*` variables) remain unchanged because the code is downloaded from upstream during the build.
- `r4y.cmd` was written without being executed on Windows. Please test it and report any issues.
- The Leonida asset pipeline (Python/Vulkan, approximately 400 GB) is not integrated into the installer.

## License

GPL-3.0-or-later. See `LICENSE` and [NOTICE.md](NOTICE.md).
