# Contributing to Malphas

Thank you for contributing to Malphas. This document describes how to set up a
local development environment, the conventions we follow, and the checklist every
pull request must complete.

## Prerequisites

- **Rust** -- latest stable toolchain (`rustc`, `cargo`, `clippy`, `rustfmt`).
- **Flutter** -- stable channel, SDK `>=3.0.0 <4.0.0`.
- **Git** -- for cloning, branching, and signing commits if you choose to.
- **Android NDK r26c** (optional) -- only if you need to build Android engines locally.
- **PowerShell** (Windows only) -- for `build_core.ps1`.

### Optional but recommended

- `ANDROID_NDK_HOME` exported to the NDK r26c root when running `./build.sh` on Linux or macOS.
- A local `TEST_SIGNING_KEY` secret (32-byte Ed25519 private key in hex) if you want to exercise the signing flow.

## Project layout

| Path | Purpose |
|------|---------|
| `malphas_core/` | Rust `cdylib` with the C-ABI exports, VM, bridge, and pipeline. |
| `malphas_cli/` | Rust executable that compiles `manifest.json` into `.msp`/`.mxc` and signs files. |
| `flutter_app/` | Flutter frontend, FFI bindings, and UI screens. |
| `examples/` | Canonical packages (e.g., `bouncing_demo`) used by tests and the UI. |
| `build.sh` / `build_core.ps1` | Cross-platform native build scripts kept in parity. |
| `.github/workflows/` | CI/CD definitions. |

## Build locally

From the repository root:

```bash
# Build the Rust workspace and copy native artifacts into flutter_app/motors/
./build.sh               # Linux / macOS / Git Bash on Windows
.\build_core.ps1         # Windows PowerShell
```

The scripts build `malphas_core` and `malphas_cli` in release mode, timestamp the
native motor, keep the three most recent motors, and deploy a non-timestamped
copy plus signature to the workspace root and existing Flutter build directories.

## Run tests

All Rust commands run from the repository root. Flutter commands run from
`flutter_app/`.

```bash
# Rust
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test --release --locked

# Flutter
cd flutter_app
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
dart format --set-exit-if-changed .

# Linux: the dynamic linker needs to find the shared motor
export LD_LIBRARY_PATH="$PWD/motors:$LD_LIBRARY_PATH"
flutter test
```

On Windows, `flutter test` finds the motor automatically once `build_core.ps1`
has copied `malphas_core.dll` into `flutter_app/motors/`.

## Commit convention

We use [Conventional Commits](https://www.conventionalcommits.org/) with the
following types:

- `feat:` -- new feature or behavior
- `fix:` -- bug fix
- `docs:` -- documentation-only change
- `style:` -- formatting, missing semicolons, etc. (no logic change)
- `refactor:` -- code change that neither fixes a bug nor adds a feature
- `perf:` -- performance improvement
- `test:` -- adding or correcting tests
- `chore:` -- build, CI, tooling, or dependency changes
- `ci:` -- continuous integration configuration

A scope is encouraged when the change touches a single area, for example:

```text
feat(core): add arena layout getter for TextPayload pointer
fix(flutter): restore .sig file in engine signature test tearDown
docs: update flutter_app/README with real development instructions
```

Breaking changes must include a `BREAKING CHANGE:` footer and, when appropriate,
a `!` marker in the type/scope.

## Pull request checklist

Before requesting a review, verify the items that apply to your change:

- [ ] The change is limited to the workstream scope and does not touch unrelated files.
- [ ] Rust code passes `cargo fmt -- --check`.
- [ ] Rust code passes `cargo clippy --release -- -D warnings`.
- [ ] Rust tests pass with `cargo test --release --locked`.
- [ ] Security tests pass with `cargo test --release --locked --test security_tests`.
- [ ] Dart code is formatted with `dart format --set-exit-if-changed .`.
- [ ] Flutter analyze passes with `flutter analyze --no-fatal-infos --no-fatal-warnings`.
- [ ] Flutter tests pass with `flutter test` (Linux/macOS require `LD_LIBRARY_PATH`).
- [ ] `./build.sh` or `.\build_core.ps1` succeeds locally and leaves `flutter_app/motors/` populated.
- [ ] FFI struct layouts, field order, and alignment are updated in both Rust and Dart if changed.
- [ ] `CHANGELOG.md` is updated under `[Unreleased]` when the change is user-facing.
- [ ] New example packages compile with `malphas-cli compile <manifest.json>`.
- [ ] No native binaries (`.dll`, `.so`, `.dylib`, `.sig`) are committed to git.
- [ ] Commit messages follow the Conventional Commits convention.

## Code style

- Rust: format with `rustfmt`, follow `clippy --release -- -D warnings`.
- Dart: format with the project-bundled `dart format`.
- Prefer explicit, commented, safe code over cleverness.
- Keep the C-ABI layouts and the single-clock VSync pulse model intact.
- Do not add web stubs, conditional web imports, or Chrome-specific abstractions.

## Reporting issues

Use the GitHub issue templates in `.github/ISSUE_TEMPLATE/`. Include:

- The operating system and target platform.
- The output of `flutter doctor` or `rustc --version` as relevant.
- The exact commands you ran and the full error output.
- Whether the issue reproduces on a clean checkout.

## Security

Do not commit private signing keys. The repository uses the `TEST_SIGNING_KEY`
GitHub secret in CI. If you discover a security issue, please report it privately
instead of opening a public issue. See `docs/SECURITY.md` for the full policy and
reporting instructions.

### Threat model

- The runtime trusts only the configured Ed25519 trust anchor. Every loaded
  native binary (engine, `.msp`, `.mxc`) must carry a valid sidecar signature.
- The runtime does **not** trust the Flutter UI with bridge ownership; Dart only
  receives a read-only pointer to the front buffer.
- The runtime does **not** trust arbitrary file-system paths; `.mxc` loading is
  sandboxed to `systems/`, `packages/`, and `motors/`.
- The runtime does **not** trust loaded systems; panics and buffer overflows are
  isolated with `catch_unwind` and tainting.
- `MALPHAS_INSECURE_SKIP_VERIFY` is a debug-only escape hatch and must never be
  enabled in production.

## FFI change checklist

The Rust/Dart boundary is version-locked and layout-sensitive.  Any change that
touches the following must update both sides and the contract documentation:

- [ ] `MalphasDoubleBufferBridge` in `malphas_core/src/pipeline.rs` **and**
  `flutter_app/lib/core/ffi/types.dart`.
- [ ] `DartRenderCommand` in `malphas_core/src/pipeline.rs` **and**
  `flutter_app/lib/core/ffi/types.dart`.
- [ ] `BRIDGE_ABI_VERSION` in `malphas_core/src/pipeline.rs` whenever a layout
  changes (format `0xMMmmpp00`).
- [ ] ABI version verification in `MalphasBindings.initEngine`.
- [ ] Atomic field access in Dart through Rust getters only (`get_back_index`,
  `get_buffer_a_command_count`, `get_buffer_b_command_count`, etc.).  No direct
  atomic struct field reads.
- [ ] Layout assertions in `malphas_core/src/pipeline.rs` and Dart tests.
- [ ] `docs/FFI_CONTRACT.md` updated with the new layout, ordering, or error
  codes.

## Test requirements

Every non-trivial change must be accompanied by tests:

- Rust: add unit or integration tests in `malphas_core/src/` or
  `malphas_core/tests/`.
- Dart: add widget/unit tests in `flutter_app/test/`.
- Security: add cases to `malphas_core/tests/security_tests.rs` for trust
  anchor, signature, or sandbox changes.
- FFI: add layout and concurrency tests when changing shared structures or
  atomic ordering.

All tests must pass locally before opening a pull request:

```bash
cargo fmt -- --check
cargo clippy --all-targets -- -D warnings
cargo test --release --locked
cargo test --release --locked --test security_tests
cd flutter_app && flutter analyze --no-fatal-infos --no-fatal-warnings
cd flutter_app && dart format --set-exit-if-changed .
cd flutter_app && flutter test
```

## Release process summary

1. Ensure the root `VERSION` file contains the new version (e.g. `2.9.0`).
2. Run `scripts/sync_version.sh` to propagate the version to `Cargo.toml`,
   `flutter_app/pubspec.yaml`, `README.md`, and `malphas_core/src/pipeline.rs`.
3. Run `scripts/check_version_sync.sh` to verify all version strings agree.
4. Update `CHANGELOG.md` with the new release section and migration notes.
5. Update `docs/SECURITY.md` and `docs/FFI_CONTRACT.md` if the security model or
   FFI boundary changed.
6. Verify the release build signs all native artifacts with a production key,
   not the `TEST_SIGNING_KEY`.
7. Tag the release as `v<VERSION>` and publish signed artifacts with a
  `SHA256SUMS` file.
