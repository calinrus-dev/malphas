# Security Policy

This document describes the security model, trust anchor setup, runtime sandbox,
and reporting process for Malphas v2.9.0.

## Threat Model

### What the Runtime Trusts

The runtime trusts exactly one thing: a configured **Ed25519 trust anchor** (a
32-byte verifying key).  Every native binary the engine executes or loads must
carry a valid sidecar signature that verifies against this anchor.

Assets validated through the trust anchor include:

- The engine library itself (`malphas_core.dll` / `libmalphas_core.so` /
  `libmalphas_core.dylib`).
- MSP data packs (`.msp` with `.msp.sig` or `.sig`).
- MXC system libraries (`.mxc` / `.so` / `.dll` with `.sig`).

Release builds of `malphas_core` do **not** ship with a built-in trust anchor.
The engine refuses to load signed assets until a real anchor is configured.

### What the Runtime Does Not Trust

- **The Flutter UI / Dart side.**  Dart receives only a read-only pointer to the
  shared `MalphasDoubleBufferBridge`.  It cannot allocate or free the bridge, the
  command buffers, or any MSP memory.  A compromised Flutter layer can, at worst,
  render incorrect frames or crash its own process; it cannot execute arbitrary
  native code through the engine boundary.
- **The host file system.**  All `.mxc` loads are sandboxed to the workspace
  subdirectories `systems/`, `packages/`, `motors/`, and `flutter_app/motors/`.
  Symlinks, parent-dir traversal (`..`), and absolute paths outside the workspace
  are rejected before any file is opened.
- **Third-party systems.**  Each `.mxc` system is treated as untrusted native
  code.  System `init` and `tick` entry points are wrapped in `catch_unwind`, and
  a panicking or overflowing system is tainted rather than allowed to crash the
  engine.  Systems are forbidden from writing into the MSP or calling back into
  the core.
- **Debug bypass flags.**  `MALPHAS_INSECURE_SKIP_VERIFY` is a debug-only escape
  hatch.  It is compiled out of release builds and must never be enabled in
  production.

## Trust Anchor Setup

### Generating an Ed25519 Keypair

Use `malphas-cli` to generate a fresh keypair.  The private key is a 32-byte
Ed25519 seed; the public key is the 32-byte verifying key used as the trust
anchor.

```bash
# Generate a keypair with any standard Ed25519 tool.  For example:
python3 - <<'PY'
import nacl.signing, binascii
sk = nacl.signing.SigningKey.generate()
print("private:", binascii.hexlify(sk.encode()).decode())
print("public: ", binascii.hexlify(sk.verify_key.encode()).decode())
PY
```

Store the private key in a secure location (e.g. a password manager or CI secret
store).  The public key is what you distribute to clients and configure as the
trust anchor.

### Setting the Trust Anchor at Runtime

#### Dart / Flutter — `setTrustAnchor`

Call `MalphasBindings.setTrustAnchor(publicKeyHex)` before loading MSP or MXC
assets:

```dart
final bindings = MalphasBindings();
final result = bindings.setTrustAnchor(
    'aac8adcae7707a961bd03e24c1196d2593ba62f491ab00c0dd20bfa9b284aa1c');
if (result != 0) {
  throw Exception('Failed to configure Malphas trust anchor (code $result)');
}
```

Return values:

| Code | Meaning |
|------|---------|
| `0`  | Success. |
| `-1` | Native library unavailable or null argument. |
| `-2` | Invalid hex encoding. |
| `-3` | Wrong public key length (must be 32 bytes). |
| `-4` | Public key is cryptographically invalid. |
| `-5` | Other trust anchor error. |

#### Rust / C — `set_trust_anchor`

```rust
use malphas_core::set_global_trust_anchor;

set_global_trust_anchor("<32-byte-public-key-hex>")?;
```

```c
int set_trust_anchor(const char *public_key_hex);
```

### Build-Time Trust Anchor for Flutter

For release builds the trust anchor should be baked in at compile time so the
Flutter engine manager can verify the engine binary before it is loaded.  Pass
the public key via `--dart-define`:

```bash
flutter build apk --release \
    --dart-define=MALPHAS_TRUST_ANCHOR="<32-byte-public-key-hex>"
```

If `MALPHAS_TRUST_ANCHOR` is empty in a release build, the engine is reported as
corrupt and will not start.

### Signing Native Artifacts

Sign engine libraries, MSP files, and MXC systems with `malphas-cli` using the
private key stored in `MALPHAS_SIGNING_KEY`:

```bash
export MALPHAS_SIGNING_KEY="<32-byte-private-key-hex>"
malphas-cli sign path/to/malphas_core.dll
malphas-cli sign path/to/package.msp
malphas-cli sign path/to/system.mxc
```

Each command writes a sidecar `.sig` file containing the hex-encoded Ed25519
signature over the SHA-256 hash of the target file.

## Sandbox Rules

`load_system` (and the `load_system_file` FFI entry point) enforce the following
rules for every `.mxc` path:

1. **Allowed roots only.**  The resolved, canonical path must start with one of:
   - `<workspace>/systems/`
   - `<workspace>/packages/`
   - `<workspace>/motors/`
   - `<workspace>/flutter_app/motors/`
2. **No parent-dir traversal.**  Any `..` component in the input path is
   rejected before canonicalization.
3. **No symlinks.**  If the input path or any resolved component is a symlink,
   the load is rejected.
4. **Workspace-relative resolution.**  Relative paths are resolved against the
   workspace root discovered from `CARGO_MANIFEST_DIR` or by walking up to a
   `Cargo.toml` containing `[workspace]`.
5. **Signature first.**  The sandbox is checked before signature verification,
   but the file is not opened until both sandbox and signature checks pass.

Violations return `ERR_SYSTEM_SANDBOX` (`-210`).

## Key Rotation

Call `setTrustAnchor` / `set_trust_anchor` again at runtime to replace the active
trust anchor.  The new anchor takes effect immediately for subsequent signature
verifications.  Already-loaded systems are not re-verified retroactively; rotate
the anchor during a maintenance window or after calling `shutdown_engine` and
re-initializing.

A multi-key keyring is planned for a future release.  v2.9.0 supports only a
single active anchor at a time.

## Reporting Security Issues

Do not open a public issue for security vulnerabilities.  Instead, report them
privately so they can be fixed before disclosure.

1. Email the maintainers at the address listed in the repository owner profile
   or use GitHub private vulnerability reporting if enabled for this repository.
2. Include a clear description, steps to reproduce, affected version(s), and any
   suspected impact.
3. Allow reasonable time for a fix before publicly discussing the issue.

Security reports are acknowledged within 72 hours when contact details are
provided.
