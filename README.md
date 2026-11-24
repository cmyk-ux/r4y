# R4Y — Recompile4You

R4Y is a Windows launcher, backend manager, and contributor-friendly integration layer for running Xbox Series X|S game builds from files the user already owns and can read on disk.

R4Y does not distribute game files, keys, executables, shaders, or other copyrighted game assets. It does not decrypt files or bypass platform protection. Users must provide their own legally obtained game files.

> **Project status:** experimental. Compatibility, stability, and performance depend on the selected backend and the user's hardware. A successful build does not mean a game is fully playable.

## Backends

R4Y can build and launch three independent engines. The registry lives in [`backends.json`](backends.json), so source URLs, branches, Cargo package names, and executable names are not duplicated throughout the installer.

| Backend | Source | Role |
|---|---|---|
| `minevictory` (default) | [cmyk-ux/minevictory](https://github.com/cmyk-ux/minevictory) | R4Y's working VIctory-derived runtime. |
| `upstream` | [Marvisak/VIctory](https://github.com/Marvisak/VIctory) | Upstream baseline and compatibility reference. |
| `xcl` | [cmyk-ux/minexcl](https://github.com/cmyk-ux/minexcl) | Independent XCL-derived runtime and diagnostic/tooling path. |

Each backend is cloned, patched, built, configured, and launched in its own directory. R4Y does not combine backend source trees into a single Cargo workspace. This keeps engine-specific dependencies, build settings, state, and logs isolated.

## Quick start

1. Install Git, Rustup, and Visual Studio 2022 Build Tools with the C++ workload and a Windows SDK. The installer can offer to install missing prerequisites through `winget`.
2. Clone this repository:

   ```powershell
   git clone https://github.com/cmyk-ux/r4y.git
   cd r4y
   ```

3. Run `r4y.cmd`, or choose a backend explicitly:

   ```cmd
   r4y.cmd --backend minevictory
   r4y.cmd --backend xcl
   r4y.cmd --backend upstream
   ```

4. Select the folder containing your game files and the game's executable. R4Y remembers the selection locally.
5. When the build and inspection checks finish, launch with `r4y-run.cmd`.

The first Rust build downloads dependencies and can take a while. Subsequent builds use the backend's isolated Cargo target directory and can reuse incremental artifacts.

## Installer options

```text
r4y.cmd [--backend upstream|minevictory|xcl]
        [--dry-run] [--no-build] [--no-run] [--yes] [--test]

  --backend NAME  Select the engine (default: minevictory)
  --dry-run       Check prerequisites without installing, cloning, or writing files
  --no-build      Save local selection/configuration but skip compilation
  --no-run        Build and validate without offering to launch the game
  --yes           Accept dependency installation prompts
  --test          Run cargo test --workspace before building
  --help          Show the available options
```

The legacy `--channel upstream` and `--channel fork` arguments remain accepted; `fork` maps to `minevictory`.

## Directory layout

```text
r4y.cmd                  Windows entry point
r4y-run.cmd              Portable launcher wrapper
backends.json            Backend registry (single source of truth)
scripts/r4y.ps1          Installer, updater, builder, validator, and launcher
patches/<backend>/       Backend-specific patches, applied in filename order
docs/INTEGRACAO.md       Backend architecture and integration notes
CONTRIBUTING.md          Contributor workflow and testing

src/backends/<backend>/  Local backend source checkouts (generated)
build/<backend>/         Isolated Cargo target directories (generated)
bin/backends/<backend>/  Built backend executables (generated)
config/                  Per-machine selection and backend configs (generated)
```

Generated source checkouts, binaries, build outputs, personal configuration, and logs are not committed. User data and game files remain outside the source repositories. Backend data is stored under `%LOCALAPPDATA%\\R4Y\\backends\\<backend>`.

## Diagnostics and environment

The launcher keeps the existing R4Y environment interface for VIctory-derived engines:

| R4Y variable | Backend variable |
|---|---|
| `R4Y_LOG` | `VICTORY_LOG` |
| `R4Y_D3D12_DEBUG` | `VICTORY_D3D12_DEBUG` |
| `R4Y_D3D12_DRED` | `VICTORY_D3D12_DRED` |
| `R4Y_D3D12_WARP` | `VICTORY_D3D12_WARP` |

For example, in Command Prompt:

```cmd
set R4Y_D3D12_WARP=1
r4y-run.cmd
```

WARP uses a software adapter and is intended for troubleshooting, not performance. Backend-specific diagnostic options still depend on that backend's build features.

XCL stores its title data beneath `%LOCALAPPDATA%\\R4Y\\backends\\xcl` through `XCL_DATA_ROOT`. VIctory-derived engines receive separate `cache_dir` and `data_dir` values in their generated TOML configuration.

## For contributors

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request. The short version:

- Keep backend-specific logic in the backend adapter/registry rather than adding scattered repository URLs to the installer.
- Do not modify files inside a downloaded backend checkout as part of an R4Y change. Use a patch under `patches/<backend>/` when a repeatable integration patch is required.
- Keep build outputs, local paths, game data, logs, and generated configuration out of commits.
- Validate installer metadata with `powershell -ExecutionPolicy Bypass -File scripts/r4y.ps1 --validate-only`.
- Test the affected backend on Windows and include the backend revision, build command, and test results in the pull request.

Issues and pull requests are welcome. Bug reports should identify the backend, Windows version, GPU/driver, backend commit, exact command, and relevant R4Y/backend logs. Never attach game files or copyrighted assets.

## Credits

R4Y builds on the work of the VIctory, XCL, and Leonida projects. See [`NOTICE.md`](NOTICE.md) for source links and attribution.

## License

See [`LICENSE`](LICENSE) and [`NOTICE.md`](NOTICE.md). Each backend remains a separately built project with its own source repository and notices.
