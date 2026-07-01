# Changelog

## [3.0.0] — Production-Ready Sovereign Runtime

### Added
- Runtime telemetry service: RAM budget, MSP mmap diagnostics, optional GPS via `geolocator`.
- Telemetry overlay in workspace with settings toggles and persisted user preferences.
- Memory budget enforcement in `malphas_core`: atomic reservation/release rejects oversize MSPs.
- mmap diagnostics exposed through FFI: mapped size, Silver Platter build time, command timing.
- Skippable splash screen with version/build display and first-launch detection.
- First-run onboarding flow with workspace directory selection and trust-anchor guidance.
- Reusable themed widgets: `MalphasCard`, `MalphasLoadingIndicator`, `MalphasEmptyState`, `MalphasIconButton`, `MalphasTag`.
- Empty states and loading skeletons on Hub and Workspace screens.
- Accessibility labels and tooltips on icon buttons and telemetry toggles.
- Byte-bounded LRU caches for decoded payloads and sprite `ui.Image` instances.
- `malphas_cli` developer commands: `keygen`, `verify`, `init`, `build-system`.
- Environment bundle commands: `environment bundle`, `environment list`, `environment unbundle`.
- User-configurable workspace directory with cross-platform fallback via `path_provider`.

### Changed
- Bumped ABI version to `0x03000000` and MSP version to `4`.
- `DartRenderCommand` and `MalphasDoubleBufferBridge` locked at 64 bytes, 64-byte aligned.
- `bouncing_demo` system uses typed payload schema and input-aware `malphas_tick_with_input`.
- Settings screen grouped into workspace directory and telemetry sections.
- Updated `docs/FFI_CONTRACT.md` to reflect the 64-byte render command layout.

### Fixed
- Flutter workspace tests now seed the trust anchor directly so signed artifacts load end-to-end.
- Native release artifacts rebuilt and re-signed against the repository trust anchor.
- Engine controller disposes image caches and payload decode caches on teardown.

### Security
- Test trust anchor fallback gated behind the `test-anchor` Cargo feature only.
- All distributed `.msp`, `.mxc`, and engine binaries re-signed with the current Ed25519 trust anchor.

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
