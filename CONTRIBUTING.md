# Contributing to R4Y

Thanks for helping improve R4Y. This repository is the installer, backend manager, integration patches, and contributor workflow; the actual engines live in their own source repositories.

## Development setup

- Windows 10/11 x64.
- Git.
- Windows PowerShell 5.1 or PowerShell 7+.
- Rustup and the MSVC Rust toolchain.
- Visual Studio 2022 C++ Build Tools and a Windows SDK for backend builds.

Clone the repository and create a focused branch:

```powershell
git clone https://github.com/cmyk-ux/r4y.git
cd r4y
git switch -c fix/short-description
```

## Validate changes

Validate the backend registry and the portable launcher without downloading or building an engine:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\r4y.ps1 --validate-only
```

Run the installer in read-only prerequisite-check mode:

```cmd
r4y.cmd --dry-run --backend minevictory
```

To build and test a backend locally:

```cmd
r4y.cmd --backend minevictory --test --no-run
r4y.cmd --backend xcl --test --no-run
r4y.cmd --backend upstream --test --no-run
```

The first build can take considerable time. GPU-dependent tests may be skipped by the backend when required hardware or driver features are unavailable; report those skips rather than claiming the GPU path was tested.

## Backend changes

- `backends.json` is the canonical backend registry. Do not scatter hard-coded source URLs through scripts or docs.
- Backend source checkouts are generated under `src/backends/` and are not part of R4Y commits.
- Do not hand-edit a downloaded checkout as an R4Y integration change. Put a repeatable patch in `patches/<backend>/`, test it against the backend revision, and describe when it should be rebased.
- Keep each engine's build artifacts, runtime data, logs, environment variables, and configuration isolated.
- If a new engine has a different command-line or config contract, add a small explicit adapter in `scripts/r4y.ps1` and document it in `docs/INTEGRACAO.md`.

## Pull requests

A good pull request should include:

1. The problem and intended behavior.
2. The affected backend(s) and exact backend commit(s) used for testing.
3. Commands run and their results (`--validate-only`, build, tests, and manual launch checks where applicable).
4. Relevant log excerpts with personal paths and unrelated machine details removed.
5. Screenshots only when they clarify a UI or installer issue.

Keep pull requests focused. Avoid mixing installer refactors, engine code changes, and unrelated documentation edits in one change.

## Safe test data

Never commit game executables, archives, shader dumps, title assets, keys, personal game paths, save files, or crash dumps containing game data. Tests should use synthetic fixtures or files that are explicitly safe to redistribute. Do not attach copyrighted game files to issues or pull requests.

## Reporting bugs

Select the affected backend and include the R4Y commit, backend revision, Windows version, GPU and driver version, exact command, and the relevant log. Remove personal usernames and absolute paths before posting.
