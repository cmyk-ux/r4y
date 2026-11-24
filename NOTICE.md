# NOTICE

R4Y is the integration, installer, and launcher project. It builds the selected engine from a separate source checkout; backend source remains maintained in its own repository.

## Source projects and credits

- **VIctory** — Marvisak and contributors: upstream runtime and original VIctory codebase. R4Y exposes it as the `upstream` backend.
- **MineVIctory** — cmyk-ux: R4Y's VIctory-derived working fork, exposed as the default `minevictory` backend. The fork retains the history and upstream attribution of its base project.
- **XCL** — ivall / xcl-dev and contributors: independent Xbox Series compatibility runtime and tooling. R4Y's `xcl` backend builds the cmyk-ux/minexcl source checkout.
- **Leonida** — ItsNotRexed, cmyk-ux, and contributors: the one-click Windows installer pattern that informed the initial R4Y bootstrapper.

See each linked source repository for its current authorship, license, and third-party notices. Backend repositories are built independently and are not vendored into the R4Y source tree.

## No game data

R4Y does not distribute game files, keys, executables, shaders, saves, or other copyrighted game assets. Do not attach game files or dumps to issues or pull requests. R4Y is not affiliated with Rockstar Games or Take-Two Interactive; Grand Theft Auto and related names are trademarks of their respective owners.
