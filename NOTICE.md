# NOTICE

R4Y (Recompile4You) is distributed under GPL-3.0-or-later. See [LICENSE](LICENSE).

## Source projects and attribution

- **VIctory** — Marvisak and contributors: the upstream Rust runtime, loader, HLE, D3D12 backend, shader translator, formats, tools and tests incorporated as the initial R4Y workspace base.
- **MineVIctory / victory-fork** — cmyk-ux, fxceless and contributors: the VIctory-derived fork used as the source of selected GPU, shader and performance fixes. R4Y ports are rebased and tested individually; the fork is not merged wholesale.
- **XCL** — ivall / xcl-dev and contributors: independent Xbox Series compatibility runtime. R4Y references its public issue/PR research and selected algorithms; it does not include the XCL runtime as a second backend.
- **Leonida** — ItsNotRexed, cmyk-ux and contributors: source of the simple Windows installer/bootstrap pattern. The separate Leonida asset pipeline is not included in R4Y.

Preserve the original source notices and project history when working on files derived from these projects. See [docs/SOURCE_MAP.md](docs/SOURCE_MAP.md) for the provenance and current integration decisions.

## No game data

This repository does not distribute game files, keys, executables, generated shaders, saves or other copyrighted game assets. It does not decrypt files or bypass platform protection. Do not attach game data to issues or pull requests.

Grand Theft Auto and related names are trademarks of their respective owners. R4Y is not affiliated with Rockstar Games or Take-Two Interactive.
