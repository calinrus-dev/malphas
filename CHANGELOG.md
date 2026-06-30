# Changelog

## [2.10.0] — Hardened Frontend & Zero-Copy Blind Painter

### Added
- Flutter frontend: zero-copy `PrimitiveCanvas` rendering via FFI.
- Silver Platter lookup table: O(1) payload resolution for `.mxc` systems.
- ArcSwap-based MSP snapshot loading: hot-swap without data races.
- Ed25519 signature verification for `.msp` and `.mxc` binaries.
- Path sandbox: canonicalization, traversal rejection, symlink blocking.
- Trust anchor service: secure storage integration (Android Keystore, iOS Keychain, desktop keyring).
- Lock-free input queue with event coalescence.
- FFI contract tests: ABI version lock, struct size verification (64-byte alignment).
- Security integration tests: signature rejection, sandbox enforcement, malformed MSP handling.
- CI/CD: Android AAB/APK, Windows release, Linux/macOS builds with signed artifacts.

### Changed
- Bumped ABI version to `0x02100000`.
- `MspHeader` and `MspEntityDescriptor` strictly aligned to 64 bytes.
- MSP version bumped to `3` to reflect the new 64-byte aligned descriptor layout.
- Dart models flattened to final classes with integer IDs (no OOP hierarchies).
- Package manager: virtualized `GridView`, async Isolate decoding, tag-based filtering.

### Fixed
- FFI struct size mismatch between Rust and Dart — aligned `DartRenderCommand` to 64 bytes.
- Use-after-free in Silver Platter during MSP refresh.
- Data race in double-buffer bridge pointer access.
- Path traversal vulnerability in payload file resolution.
- Hardcoded test trust anchor removed from release builds.

### Security
- All `.mxc` binaries must carry a valid Ed25519 signature or the engine refuses load.
- MSP checksum migrated from partial XOR to SHA-256 over the entity table and payload section.
- ZIP extraction hardened against bombs, symlinks, and hardlinks.
- Constant-time signature comparison via `subtle::ConstantTimeEq`.

## [2.7.0] — Fortress Master Implementation

### Added
- Data-Oriented Memory Router: Rust core with mmap-based MSP loading.
- Stateless `.mxc` system loading via `libloading`.
- `catch_unwind` panic isolation around system ticks.
- `MALPHAS_INSECURE_SKIP_VERIFY` debug escape hatch.

### Security
- Initial sandbox and signature verification framework.
