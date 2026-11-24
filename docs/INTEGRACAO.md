# Backend architecture and integration

R4Y is the orchestration layer. It selects an engine, obtains its source, applies R4Y-owned patches, builds the backend, generates per-backend configuration, validates the selected executable, and launches the engine. The backend registry in `backends.json` is the source of truth for repository URL, branch, Cargo package, output binary, and adapter type.

## Supported backends

| Backend ID | Repository | Cargo package | Executable | Adapter |
|---|---|---|---|---|
| `minevictory` | `cmyk-ux/minevictory` | `victory` | `victory.exe` | `victory` |
| `upstream` | `Marvisak/VIctory` | `victory` | `victory.exe` | `victory` |
| `xcl` | `cmyk-ux/minexcl` | `xcl` | `xcl.exe` | `xcl` |

The default is `minevictory`. `upstream` remains available as a baseline. `xcl` is an independent engine, not a VIctory build variant.

## Isolation contract

Every backend gets its own source checkout, Cargo target directory, output binary directory, generated configuration, and user data root:

```text
src/backends/<backend>/
build/<backend>/target/
bin/backends/<backend>/
config/backends/<backend>.toml
%LOCALAPPDATA%/R4Y/backends/<backend>/
```

The installer refuses to reset a checkout with local modifications or an unexpected Git origin. It never silently discards contributor changes in a downloaded source directory. For an intentional clean refresh, move the checkout aside and rerun the installer.

Patches are backend-scoped under `patches/<backend>/` and applied in filename order. A patch that no longer applies stops the setup with an actionable error instead of being silently skipped. The original top-level `patches/*.patch` location is retained as a migration path for VIctory-derived backends.

## VIctory adapter

`minevictory` and `upstream` share the VIctory command contract:

```text
victory config
victory inspect <game.exe>
victory run <game.exe> --execute [-- <game arguments>]
```

R4Y writes a TOML file for each backend and sets `VICTORY_CONFIG` at launch. The generated `[paths]` section contains the selected game directory plus backend-specific `cache_dir` and `data_dir`, keeping cache and persistent title data separate from the source checkout and from other backends.

R4Y-prefixed environment variables are translated to the existing `VICTORY_*` variables only at process launch. This avoids requiring R4Y users to learn internal backend variable names while preserving the backend's existing interface.

## XCL adapter

XCL has a different command and configuration model:

```text
xcl inspect <game.exe>
xcl run <game.exe> [-- <game arguments>]
```

It does not use `VICTORY_CONFIG` or the VIctory `--execute` switch. R4Y sets `XCL_DATA_ROOT` to the isolated XCL data directory and invokes the XCL binary directly. Logs and title state remain in that root.

## Installer lifecycle

1. Validate `backends.json` and parse the selected backend.
2. Check Windows, AVX2, Git, Rust, MSVC C++ tools, and Windows SDK.
3. Clone or update only the selected backend's checkout.
4. Refuse destructive updates when local modifications are present.
5. Apply backend-specific patches.
6. Select/restore the game directory and executable.
7. Generate backend-local configuration and local state.
8. Run backend tests when `--test` is requested, then build the declared Cargo package.
9. Inspect the selected executable with the backend's own CLI.
10. Generate the portable `r4y-run.cmd` wrapper.

## Adding a backend

A backend addition should update `backends.json`, `scripts/r4y.ps1` only when a genuinely new adapter contract is needed, `README.md`, this document, and the CI matrix. Prefer reusing an existing adapter type if the engine exposes the same CLI contract. Do not add repository-specific special cases to the installer when a manifest value is sufficient.
