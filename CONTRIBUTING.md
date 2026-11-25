# Contributing to R4Y

Thanks for helping improve R4Y. This repository contains the Windows runtime, shader translator, GPU backend, command-line tools, tests and installer. There is one Rust workspace and one runtime.

## Development setup

- Windows 10/11 x64 for D3D12 integration tests.
- Git.
- Rustup with the toolchain pinned in `rust-toolchain.toml`.
- Visual Studio 2022 C++ Build Tools and a Windows SDK.
- A D3D12 GPU for hardware-dependent tests; synthetic and WARP tests should be used when possible.

Clone the repository and create a focused branch:

```powershell
git clone https://github.com/cmyk-ux/r4y.git
cd r4y
git switch -c fix/short-description
rustup toolchain install
```

## Validate changes

Run the repository policy check, tests, Clippy and release build:

```powershell
cargo xtask policy
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo build --release --locked -p r4y
```

A diagnostics build is separate:

```powershell
cargo build --profile diag --locked -p r4y --features diagnostics
```

The first build downloads dependencies and compiles the workspace. GPU-dependent tests may require Windows Graphics Tools, DXC/validator components, a supported D3D12 driver or a specific adapter. The generic GitHub-hosted Windows runner filters out only `gathers_at_a_level_match_the_hardware` and `permutes_read_the_lane_named_and_zero_from_lanes_left_out` because it does not provide a guaranteed matching GPU. Plain local `cargo test --workspace --locked` still runs both tests. Report filtered tests rather than claiming that hardware paths were tested.

## Runtime and GPU changes

- Fix resource-state, descriptor-lifetime and command-list issues in `crates/r4y-gpu`.
- Shader decoding, control flow and DXIL lowering belong in `crates/r4y-shader`.
- Console API behavior belongs in `crates/r4y-hle`.
- PE loading and binding belong in `crates/r4y-loader` and `crates/r4y-pe`.
- Keep every shader-cache setting in the cache fingerprint. A translation switch omitted from the key can reuse stale DXIL.
- Preserve synthetic and WARP tests. Add focused regression tests for every issue that can be reproduced without game data.
- Check the current R4Y implementation and open issues before introducing overlapping behavior.

Do not add a second runtime or backend selector.

## Pull requests

A good pull request includes:

1. The problem and intended behavior.
2. The affected subsystem and the R4Y issue or reproducible report that motivates the change.
3. The R4Y base commit.
4. Commands run and results, including whether tests were hardware, WARP, synthetic or offline-only.
5. For GPU/runtime fixes: GPU model, driver version, Windows build, title build, test duration, D3D12 debug-layer/DRED evidence and before/after behavior.

Keep pull requests focused. Avoid combining shader translation, GPU state tracking, installer refactors and unrelated documentation changes in one change.

## Safe test data

Never commit game executables, archives, shader dumps, title assets, keys, personal game paths, save files, crash dumps containing game data or generated cache contents. Tests should use synthetic fixtures or files that are explicitly safe to redistribute. Do not attach copyrighted game files to issues or pull requests.

## Reporting bugs

Include the R4Y commit, Windows version/build, CPU, actual D3D12 adapter and driver version, game build, exact command, runtime duration and relevant logs. Remove usernames and absolute paths before posting.
