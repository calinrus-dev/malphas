# Contributing to Malphas

Thank you for contributing to Malphas. This document is the source of truth for design philosophy, FFI rules, code standards, and commit conventions. PRs that violate these rules will be rejected regardless of functionality.

## Design Philosophy

Malphas is a Data-Oriented Design (DOD) runtime. Hot paths are allocation-free, cache-friendly, and struct-of-arrays oriented. The following are mandatory:

- **Entities are `u32` IDs**. They carry no logic, no methods, and no inheritance.
- **Payloads are raw bytes**. They are 64-byte aligned raw data blocks (textures, audio, geometry). Do not wrap them in objects.
- **Systems are `.mxc` files**. They are compiled dynamic libraries that receive the Silver Platter and write render commands. They are stateless with respect to the core.
- **No OOP in hot paths**. If your PR introduces `class`, `object`, `inheritance`, or `virtual method` semantics, it will be rejected.
- **Rust owns memory**. Dart is a passive display server. Never allocate, free, or write into the FFI bridge or command buffers from Dart.

## FFI Contract Rules

The boundary between Rust and Dart is a C-ABI contract. Breaking it causes crashes on ARM64, torn frames, or use-after-free.

1. Every struct crossing the boundary MUST be `#[repr(C)]` and explicitly aligned to 64 bytes where required (`#[repr(C, align(64))]`).
2. `DartRenderCommand`, `MalphasDoubleBufferBridge`, `MspHeader`, and `MspEntityDescriptor` may not change field order, size, or alignment without updating both Rust and Dart definitions.
3. The ABI version (`BRIDGE_ABI_VERSION`) MUST be bumped on any layout change.
4. Dart MUST NOT perform pointer arithmetic on `MalphasDoubleBufferBridge` or copy nested structs by value. Read front-buffer pointers and counts directly from the bridge fields.
5. Use `malphas_alloc` / `malphas_free` only for auxiliary payloads, never for the bridge or command buffers. Free with the exact size that was allocated.
6. Every `unsafe` block MUST have a `// SAFETY:` comment explaining why the operation is sound and what invariants the caller guarantees.

## Code Standards

### Rust

- Run `cargo clippy --all-targets -- -D warnings` before submitting. Warnings are errors.
- Run `cargo fmt` and `cargo fmt -- --check`.
- Run `cargo test --release --locked`.
- All `unsafe` blocks require a `// SAFETY:` comment.
- Prefer explicit, safe code over cleverness.

### Dart

- Run `flutter analyze --no-fatal-infos`.
- Run `dart format --set-exit-if-changed .`.
- Run `flutter test`.
- Do not trigger global Flutter rebuilds on high-speed ticks. The canvas is repaint-driven.
- Do not use Spanish or non-ASCII characters in identifiers, comments, or strings.

### General

- Keep changes minimal and surgical. Do not refactor for style.
- Preserve existing file conventions and naming.
- All code, comments, and documentation MUST be in English.

## Threat Model

Assume `.mxc` files from users are potentially malicious. The engine must survive:

- Malformed MSP headers, bad checksums, and out-of-bounds descriptors.
- Path traversal attempts (`..`, absolute paths, symlinks).
- Panicking or overflowing systems.
- Invalid FFI arguments from Dart.

Never trust size arguments from FFI. Always validate lengths and offsets before pointer arithmetic. A bug that crashes the engine is a security bug.

## Commit Message Format

Use Conventional Commits:

- `feat(component): description`
- `fix(component): description`
- `security(scope): description`
- `refactor(scope): description`
- `docs(scope): description`
- `test(scope): description`

Examples:

```text
feat(msp_loader): add 64-byte aligned descriptor layout
security(system_host): reject symlinked system paths
fix(ffi): align DartRenderCommand to 64 bytes
```

## Release Checklist

Before a release tag is pushed:

1. Update `Cargo.toml`, all crate manifests, `pubspec.yaml`, `README.md`, and `CHANGELOG.md` to the new version.
2. Bump `BRIDGE_ABI_VERSION` if the FFI layout changed.
3. Bump `MSP_VERSION` if the MSP format changed.
4. Run the full verification sequence from `README.md`.
5. Ensure `TEST_SIGNING_KEY` and `RELEASE_SIGNING_KEY` repository secrets are configured.
6. Push a tag matching `v*`. The `release.yml` workflow handles the rest.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
