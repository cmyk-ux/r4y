//! Title-specific container formats, build identities and runtime adapters.
//! Per-build hooks are located by offsets or byte-pattern signatures. What
//! may and may not be stored here is defined in docs/asset-policy.md.

pub mod cityhash;
pub mod pipelines;
pub mod sgd5;
pub mod shaderpack;

/// A title build identified by the hash of its original executable.
#[derive(Debug, Clone, Copy)]
pub struct KnownBuild {
    /// Our own label, e.g. "1.0.0 retail".
    pub label: &'static str,
    /// BLAKE3 of the original executable, hex.
    pub blake3: &'static str,
}

/// Build identities explicitly supported by this runtime.
pub const KNOWN_BUILDS: &[KnownBuild] = &[];

/// Looks up a build by the BLAKE3 hash of its executable.
pub fn identify(blake3_hex: &str) -> Option<&'static KnownBuild> {
    KNOWN_BUILDS
        .iter()
        .find(|b| b.blake3.eq_ignore_ascii_case(blake3_hex))
}
