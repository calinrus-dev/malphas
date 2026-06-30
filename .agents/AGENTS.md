# Malphas Agent Instructions — v2.10.0

These rules govern every AI agent that modifies code, documentation, or build configuration in the Malphas repository. Violations will be rejected in review.

## 1. Language Rule

ALL code, comments, variable names, file names, documentation, and commit messages MUST be in English. No Spanish. No non-ASCII characters in identifiers, file names, or code comments.

## 2. Nomenclature Rule

Use ONLY the canonical Malphas terms:

- Entity
- Payload
- System
- MSP (Malphas Source Pack)
- MXC (Malphas eXecutable Core)
- Environment
- Silver Platter
- Memory Router
- Blind Painter

Never use legacy or generic OOP terms such as `Object`, `Asset`, `Component`, `Skin`, `GameObject`, `Actor`, `Scene`, `Model`, or `ViewModel`.

## 3. FFI Rule

The Rust/Dart boundary is a C-ABI contract. Treat it as immutable unless explicitly instructed otherwise.

- Never modify struct layouts without updating both Rust and Dart definitions.
- `DartRenderCommand`, `MalphasDoubleBufferBridge`, `MspHeader`, and `MspEntityDescriptor` are `#[repr(C, align(64))]` and must remain 64 bytes on both sides.
- Bump `BRIDGE_ABI_VERSION` in `malphas_core/src/pipeline.rs` and `flutter_app/lib/core/ffi/types.dart` on any layout change.
- Bump `MSP_VERSION` in `malphas_core/src/msp_loader.rs` and `malphas_cli/src/compiler.rs` on MSP format changes.

## 4. Safety Rule

Every `unsafe` block in Rust MUST have a `// SAFETY:` comment explaining why the operation is sound. No exceptions. Dart MUST NOT allocate, free, or write into Rust-owned memory (bridge, command buffers, MSP mapping).

## 5. Design Rule

Malphas is Data-Oriented. Entities are `u32` IDs. Payloads are raw bytes. Systems are `.mxc` files. Do not introduce classes, inheritance, virtual methods, or object hierarchies in hot paths.

## 6. Test Rule

Every change must pass the full local verification sequence before submission:

```bash
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test --release --locked
cd flutter_app && flutter analyze --no-fatal-infos
cd flutter_app && dart format --set-exit-if-changed .
cd flutter_app && flutter test
```

## 7. Security Rule

Assume `.mxc` files are malicious. Do not weaken signature checks, sandbox rules, or validation. `MALPHAS_INSECURE_SKIP_VERIFY` is a debug-only escape hatch and must not be relied upon in production code or release workflows.

## 8. Version Rule

Keep `Cargo.toml`, `pubspec.yaml`, `README.md`, `CHANGELOG.md`, and `BRIDGE_ABI_VERSION` in sync. A version bump is a deliberate release action and must be accompanied by an updated tag and release notes.

## 9. CI/CD Rule

Native binaries are never committed to git. They are built by `rust_ci.yml` and consumed by Flutter workflows via artifacts. Preserve artifact naming conventions and do not introduce duplicate uploads.

## 10. Minimal Change Rule

Make the smallest change that achieves the goal. Do not refactor for style. Do not invent features. Document only what exists.
