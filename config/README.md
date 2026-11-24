# Local configuration

R4Y writes per-machine state here when you run the installer. Files other than this README are ignored by Git:

- `r4y-state.json` remembers the selected backend and game executable.
- `backends/*.toml` contains backend-specific paths (for VIctory-compatible engines).

Do not commit personal game paths, logs, or generated configuration.
