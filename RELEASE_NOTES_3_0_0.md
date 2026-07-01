# Malphas v3.0.0 Release Notes

**Release date:** 2026-07-01  
**Codename:** Sovereign Runtime  
**Commit:** `calinrus-dev`

---

## Summary

Malphas v3.0.0 is the first product-grade release. It transforms the engine from a runtime-with-a-paper-architecture into a complete, cross-platform toolchain where every **Environment** is a self-contained mini operating system.

---

## Highlights

### Editor & Asset Pipeline
- Visual package editor with entities, names, tags and payload attachments.
- File-picker import for images, audio, fonts and binary payloads.
- Content-addressed asset registry with SHA-256 hashes.
- Live engine preview while editing.

### Environments as Mini OS
- `Environment` bundles MSP data, MXC logic, trust policy and storage sandbox.
- Bundle/unbundle CLI: `malphas-cli environment bundle|list|unbundle`.
- User-configurable workspace directory with platform fallbacks.
- Install/update flow inside the workspace screen.

### Input, Rendering & Canvas UX
- Zero-copy `PrimitiveCanvas` reads native command buffers via FFI.
- Touch/pan input events are coalesced and delivered to systems.
- Tap-to-select entity via front-buffer hit-test.
- Real sprite rendering through an image resolver.

### Production Hardening
- Ed25519 signature verification for `.msp` and `.mxc` binaries.
- Path sandbox with canonicalization, traversal rejection and symlink blocking.
- Memory budget enforcement with atomic reservation/release.
- mmap diagnostics: mapped size, Silver Platter build time, engine timing.
- Optional GPS/RAM telemetry overlay with user-controlled settings.

### Developer Tooling
- `malphas-cli` commands: `keygen`, `verify`, `init`, `build-system`, `compile`, `sign`, `pubkey`, `environment`.
- Auto-generated Rust bindings from manifests.
- Hot-swap engine binaries and MSPs without full restart.

### Polish & Memory Management
- Skippable splash screen with first-launch detection.
- First-run onboarding flow for workspace and trust-anchor setup.
- Reusable themed widgets, empty states, loading skeletons and accessibility labels.
- Byte-bounded LRU caches for decoded payloads and sprite images.
- Deterministic engine shutdown: free bridge, unload MSP, clear systems, dispose caches.

---

## Version Constants

| Component | Value |
|-----------|-------|
| Workspace | `3.0.0` |
| Bridge ABI | `0x03000000` |
| MSP version | `4` |

---

## Tested On

- Windows 11 (host development)
- Rust 1.79+
- Flutter 3.32+

CI targets: Android, Linux, macOS, Windows.

---

## Known Limitations

- Full text-payload string decoding in the core is pending (UI draws placeholder text with payload id).
- Dart mirror generation from `bindings_codegen` is partial.
- Accessibility audit covers core flows; screen-reader coverage can be expanded.

---

## Migration from v2.10.0

1. Bump `BRIDGE_ABI_VERSION` to `0x03000000` in any custom `.mxc` systems.
2. Re-sign all `.msp` and `.mxc` artifacts with an Ed25519 trust anchor.
3. Update manifests to `manifest_version: 2` if using the rich UI manifest schema.
4. Recompile systems against the 64-byte `DartRenderCommand` layout.

---

## Assets

- `malphas_core.dll` / `libmalphas_core.so` / `libmalphas_core.dylib`
- `malphas-cli`
- `bouncing_demo.{msp,mxc,sig}`
- `flutter_app` Android / iOS / desktop builds

---

## License

MIT. See [LICENSE](LICENSE).
