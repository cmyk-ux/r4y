## What changed?

<!-- Describe the problem and intended behavior. -->

## Subsystem

- [ ] Installer / CLI
- [ ] PE loader
- [ ] HLE / console services
- [ ] D3D12 GPU backend
- [ ] Shader translator
- [ ] Formats / title metadata
- [ ] Cache / pipeline
- [ ] Tests / tooling / documentation

## Motivation and provenance

**Related issue/PR:**

**Adapted from source commit or PR (if applicable):**

**R4Y base commit:**

## Validation

- [ ] `cargo xtask policy`
- [ ] `cargo test --workspace --locked`
- [ ] Clippy (normal and diagnostics)
- [ ] Release build
- [ ] Manual runtime test (when applicable)

**Hardware / driver / Windows / game build:**

**Commands and results:**

**Test class:** synthetic / WARP / offline shader corpus / real GPU runtime

## Safety

- [ ] No game files, keys, assets, shader dumps, saves or copyrighted data are included.
- [ ] No personal absolute paths or unrelated machine information are included in logs.
