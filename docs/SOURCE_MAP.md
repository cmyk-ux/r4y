# R4Y source map

This document maps the current R4Y workspace. It describes the responsibilities and boundaries of the code that is maintained in this repository.

## Workspace map

| Path | Responsibility |
|---|---|
| `apps/r4y` | Command-line entry point and user-facing inspect, census, translation, configuration and run commands |
| `crates/r4y-core` | Configuration, paths, logging and repository asset-policy enforcement |
| `crates/r4y-pe` | Read-only PE32+ image and import-library parsing |
| `crates/r4y-loader` | Image preparation, mapping, import binding, title DLL loading, TLS and crash reporting |
| `crates/r4y-hle` | Console API implementations and host pass-through policy |
| `crates/r4y-gpu` | D3D12.X objects, descriptors, resource tracking, command lists, synchronization and host GPU submission |
| `crates/r4y-shader` | RDNA2 instruction decoding, analysis, lowering and DXIL emission |
| `crates/r4y-formats` | Texture, audio and archive format handling |
| `crates/r4y-game` | Title-specific metadata, build identities and pipeline descriptions |
| `crates/r4y-pipeline` | Conversion interfaces and content-addressed caches |
| `xtask` | Repository policy checks and Git hook setup |
| `tests` | Synthetic fixtures and regression tests |

## Runtime boundaries

1. The installer checks Windows, CPU, Rust, MSVC and Windows SDK prerequisites.
2. The user selects their own game directory and executable.
3. R4Y writes configuration, logs, saves and derived data below the user's local application-data directory.
4. The single Cargo workspace builds the `r4y` executable.
5. The loader inspects and maps the selected executable, HLE services resolve console imports, and the GPU/shader layers translate and submit work to the host D3D12 device.

The installer does not modify the game directory. Generated configuration, caches, pipeline libraries, logs, reports and saves stay outside the Git working tree.

## Testing boundaries

| Test type | What it can establish | What it cannot establish alone |
|---|---|---|
| Unit and synthetic tests | Deterministic parsing, state transitions, policy and helper behavior | Compatibility with a complete title build |
| WARP / software-device tests | Selected D3D12 API and resource behavior without a physical target GPU | Vendor-specific hardware behavior or performance |
| Offline shader corpus | Translator coverage for the tested shader inputs | Correctness of every runtime pipeline |
| Hardware runtime tests | Behavior on the recorded adapter, driver and title build | Results on different hardware or software versions |

GPU reports should include the exact R4Y commit, adapter, driver, Windows build, title build, run duration and D3D12 debug-layer/DRED output. Do not describe an untested hypothesis as a confirmed root cause.

## Configuration and data

Public environment variables use the `R4Y_` prefix. The configuration file is `r4y.toml`, with [`r4y.example.toml`](../r4y.example.toml) as the template. Game files remain user-supplied and read-only from the installer's perspective. Derived data must remain outside the repository.

## Legal notices

See [NOTICE.md](../NOTICE.md) for third-party attributions and [LICENSE](../LICENSE) for the project license.
