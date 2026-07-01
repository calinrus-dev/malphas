# Malphas 3.0.0 Roadmap — Production-Ready Sovereign Runtime

> Status: draft — based on audit of workspace `v2.10.0`.  
> Target: a fully functional, cross-platform, developer-first editor/runtime that turns every Environment into a self-contained mini operating system for native experiences.

---

## 1. Vision

Malphas 3.0.0 is the first **product-grade** release. It is no longer a runtime with a paper architecture, but a complete toolchain:

* **Environments are mini OS instances.** Each Environment owns one MSP data pack, one or more MXC logic cores, its own trust anchor, telemetry policy, and local storage sandbox. A user can create, export, install, and run an Environment like a standalone app or game.
* **The UI is a real package editor.** Create packages, add Entities, name them, tag them, attach real assets (sprites, audio, fonts, binary payloads), preview them, save drafts, compile MSPs, and install them into Environments.
* **Developer experience is first-class.** Asset thumbnails, audio playback, drag-and-drop import, file pickers, project templates, auto-generated bindings, one-shot build commands, and hot reload.
* **Production hardening is mandatory.** Ed25519 trust anchors, signed artifacts, path sandboxing, memory telemetry, optional GPS/RAM overlays, secure user directories on Android/iOS/Linux/macOS/Windows, and CI-gated releases.
* **Memory is still the API, but it is observable.** mmap diagnostics, Silver Platter introspection, command-buffer telemetry, and runtime memory budgets.

---

## 2. Current State Snapshot

### What already works (v2.10.0)

| Area | State |
|------|-------|
| Rust core runtime | mmap MSP loader, Silver Platter table, sandboxed MXC loading, Ed25519 signature enforcement, double-buffer FFI bridge, panic isolation. |
| CLI | `compile`, `sign`, `pubkey` for stripped manifests. |
| Flutter shell | Environments hub, package manager, package creator form, workspace screen, engine controller, zero-copy `PrimitiveCanvas`. |
| FFI | Internally consistent 64-byte `DartRenderCommand` and 64-byte `MalphasDoubleBufferBridge`. |
| Security | Global trust anchor, sidecar signatures, path sandbox, SHA-256 integrity, debug bypass flag. |

### Critical gaps blocking v3.0.0

1. **Editor/runtime payload mismatch.** `PackageController.createAndCompilePackage` writes a generic 64-byte payload (`entity_id` + JSON snippet) that no existing system can interpret. Only hand-written `examples/bouncing_demo` runs.
2. **Stale FFI contract.** `docs/FFI_CONTRACT.md` still documents a 24-byte `DartRenderCommand` that contradicts the real 64-byte layout.
3. **Swallowed input.** `process_engine_tick_internal` drains input events and discards them; systems cannot react to touch/mouse.
4. **No real asset pipeline.** Payload attachment is a raw text path. There is no file picker, asset preview, audio playback, or content addressing.
5. **No user workspace directory.** The app resolves the repo root via `Cargo.toml` or falls back to app documents. Users cannot choose a cross-platform home for their packs and systems.
6. **No Environment install/runtime coupling.** An Environment is a list of package ids; there is no formal bundle that pairs MSP + MXC + config + signature.
7. **Incomplete CLI.** No `keygen`, `verify`, `init`, `build-system`, `inspect`, or bundle commands.
8. **No visual canvas editing.** Entities are edited through a form; the canvas is read-only.
9. **No runtime telemetry.** RAM, GPS, command-buffer stats are not exposed in the UI.
10. **Production gaps.** Test trust anchor fallback in debug builds, platform-specific hard-coded paths, missing asset signature UI, no memory budgets.

---

## 3. Definition of Done for 3.0.0

A 3.0.0 release is achieved when **all** of the following are true:

1. A new user can open the app, create an Environment, create a Package, add Entities with names/tags, attach assets via a file picker, compile an MSP, build or import an MXC, install both into the Environment, press Play, and see the result on the canvas.
2. The same user can export the Environment as a single signed bundle and import it on another device.
3. All native artifacts (MSP, MXC, engine library) are signed and verified against a trust anchor; debug bypass is opt-in and clearly labeled.
4. `cargo test --release --locked` and `flutter test` pass on Linux, macOS, and Windows CI; Android smoke tests pass.
5. `docs/FFI_CONTRACT.md`, `docs/SECURITY.md`, `README.md`, `CHANGELOG.md`, and `pubspec.yaml` are synced to v3.0.0 and ABI `0x03000000`.
6. The app runs with a user-chosen storage directory on Android, iOS, Linux, macOS, and Windows without requiring a source checkout.

---

## 4. Milestones

### Milestone 1 — Foundation of Truth
**Goal:** Make the codebase internally consistent and safe to extend.

| Task | Owner | Files | Acceptance Criteria |
|------|-------|-------|---------------------|
| Reconcile `DartRenderCommand` documentation | docs/core | `docs/FFI_CONTRACT.md`, `README.md`, `flutter_app/README.md` | Doc matches 64-byte layout; ABI version bumped to `0x03000000`. |
| Bump version constants | core/cli/flutter | `Cargo.toml`, `pubspec.yaml`, `pipeline.rs`, `types.dart`, `BRIDGE_ABI_VERSION`, `MSP_VERSION` | All version strings read `3.0.0` / `0x03000000` / MSP version `4`. |
| Remove stale 24-byte references | flutter | `flutter_app/lib/core/ffi/types.dart` comments, tests | No 24-byte claims remain. |
| Fix spelling convention | all | files with `Initialise` vs `Initialize` | One spelling chosen and applied. |
| Harden trust-anchor fallback | core | `malphas_core/src/integrity_policy.rs` | Test anchor behind explicit `test-anchor` feature only; release builds fail closed. |
| Fix ZIP fallback traversal | core | `malphas_core/src/crypto.rs` | `canonicalize` failure rejects the extraction instead of falling back to a relative prefix. |
| Collision detection in bindings codegen | cli | `malphas_cli/src/bindings_codegen.rs` | Compilation aborts if two sanitized entity names collide. |

### Milestone 2 — Payload Schema & Runtime Contract
**Goal:** Define a real, versioned payload language so the editor and runtime agree.

| Task | Owner | Files | Acceptance Criteria |
|------|-------|-------|---------------------|
| Design payload type registry | core/cli/flutter | new `malphas_core/src/payload_schema.rs`, `malphas_cli/src/schema.rs` | Registry maps `tag_mask` + `payload_type_id` to a known binary layout. |
| Define built-in payload types | core | `malphas_core/src/payload_types/` | `Rectangle`, `Sprite`, `Sound`, `Text`, `PhysicsBody`, `Transform` layouts are `#[repr(C, align(64))]`. |
| Migrate `bouncing_demo` | systems | `systems/bouncing_demo/src/lib.rs` | Uses the registry; no `Mutex` in hot path; frame-rate independent tick. |
| Update CLI manifest schema | cli | `malphas_cli/src/manifest.rs` | Rich manifest accepts `name`, `version`, `author`, `description`, `canvas_size`, `tags`, `payloads[]`, `dependencies[]`. |
| Compiler emits typed payloads | cli | `malphas_cli/src/compiler.rs` | Payload bytes match the schema registry; no more generic JSON blobs. |
| Add engine validation | core | `malphas_core/src/msp_loader.rs` | Refuses to load MSPs whose payload types are unknown or whose sizes mismatch the schema. |

### Milestone 3 — Asset Pipeline & Package Editor
**Goal:** Make the package editor actually usable.

| Task | Owner | Files | Acceptance Criteria |
|------|-------|-------|---------------------|
| Asset registry service | flutter | `flutter_app/lib/core/services/asset_registry_service.dart` | Hashes files with SHA-256, copies them into the project, returns stable relative IDs. |
| File picker integration | flutter | `flutter_app/lib/features/package_manager/asset_picker.dart` | Uses `file_picker` / `image_picker` on all platforms; rejects traversal paths. |
| Asset preview widgets | flutter | `flutter_app/lib/core/ui_primitives/asset_preview.dart` | Image thumbnails, audio waveform/playback, text preview, binary hex summary. |
| Payload type selector | flutter | `flutter_app/lib/features/package_manager/payload_type_selector.dart` | User picks a type; editor shows relevant fields. |
| Real-time property sync | flutter/core | `flutter_app/lib/features/package_manager/package_creator_screen.dart`, `engine_controller.dart` | Editing an entity updates a live engine preview without full rebuild (where possible). |
| Unique entity-id allocator | flutter | `flutter_app/lib/core/state/entity_store.dart` | Prevents collisions across packages and re-edits. |
| Undo/redo stack | flutter | `flutter_app/lib/core/state/change_stack.dart` | At least 50 undo levels in the package creator. |
| Replace "Skin" terminology | flutter | `package_creator_screen.dart`, `package_controller.dart` | Uses "Payload" per `AGENTS.md`. |

### Milestone 4 — Environments as Mini OS
**Goal:** Turn Environments into installable, runnable, self-contained units.

| Task | Owner | Files | Acceptance Criteria | Status |
|------|-------|-------|---------------------|--------|
| Environment bundle format | cli | `malphas_cli/src/environment.rs` | `.menv` bundle = `environment.json` + MSP + MXC; ZIP archive with hardened extraction. | Done |
| Bundle CLI commands | cli | `malphas_cli/src/main.rs` | `environment bundle`, `environment list`, `environment unbundle`. | Done |
| User app directory setting | flutter | `flutter_app/lib/features/settings/settings_screen.dart`, `app_state_persistence_service.dart`, `user_workspace_directory_service.dart` | Profile/settings screen lets user choose a directory; falls back to platform idiomatic path; works on Android/iOS/Linux/macOS/Windows. | Done |
| Environment install flow | flutter | `flutter_app/lib/features/workspace/workspace_screen.dart` | Install MSP and MXC into Environment; verify signatures; show progress/errors. | Pending |
| Environment runtime policy | flutter | `flutter_app/lib/core/models/environment_policy_model.dart`, `features/hub/environment_model.dart` | Per-environment read-only flag, max RAM budget, filesystem/network/audio/location telemetry flags. | Done |
| Export/import Environments | flutter | `flutter_app/lib/features/hub/hub_screen.dart` | Share a signed `.menv` bundle via platform share sheet or file save. | Pending |

### Milestone 5 — Input, Rendering & Canvas UX
**Goal:** Close the loop between user input, simulation, and rendering.

| Task | Owner | Files | Acceptance Criteria | Status |
|------|-------|-------|---------------------|--------|
| Pass input events to systems | core/systems | `malphas_core/src/pipeline.rs`, `malphas_core/src/system_host.rs`, `systems/bouncing_demo/src/lib.rs` | Optional `malphas_tick_with_input` receives input event slice; legacy `malphas_tick` still works. | Done |
| Input Silver Platter | core | `malphas_core/src/input.rs` | Bounded queue with coalescence; Dart injects via `process_input_event`. | Done |
| Visual canvas editing | flutter | `flutter_app/lib/features/workspace/workspace_screen.dart` | Touch/pan events drive the engine; tap selects an entity via front-buffer hit-test. | Done |
| Real text rendering | flutter | `flutter_app/lib/core/ui_primitives/primitive_canvas.dart` | Draws placeholder text with payload id; full string decoding pending core text payload ABI. | Pending |
| Sprite rendering | flutter | `primitive_canvas.dart`, `package_controller.dart` | `cmd_type == sprite` resolves to cached `ui.Image` through an optional resolver. | Done |
| Audio playback | flutter | `flutter_app/lib/core/services/audio_service.dart` | `AudioService` wraps `audioplayers`; UI trigger integration pending. | Done |

### Milestone 6 — Developer Tooling
**Goal:** Make MXC/MSP development delightful.

| Task | Owner | Files | Acceptance Criteria | Status |
|------|-------|-------|---------------------|--------|
| `keygen` CLI command | cli | `malphas_cli/src/dev_tools.rs` | Generates Ed25519 keypair; writes private/public files; optional local seed phrase. | Done |
| `verify` CLI command | cli | `malphas_cli/src/dev_tools.rs` | Verifies a sidecar signature against a public key file or hex string. | Done |
| `init` workspace command | cli | `malphas_cli/src/dev_tools.rs` | Creates a template package manifest + Rust `cdylib` system crate. | Done |
| `build-system` command | cli | `malphas_cli/src/dev_tools.rs` | Builds a Rust `cdylib` crate and writes a sidecar signature. | Done |
| Auto-generated Dart bindings | cli | `malphas_cli/src/bindings_codegen.rs` | Emits Rust bindings next to the manifest; Dart mirror generation pending. | Partial |
| Dev onboarding docs | docs | `docs/DEV_WORKFLOW.md` | Step-by-step guide from zero to running Environment. | Pending |
| Hot reload for systems | core | `malphas_core/src/system_host.rs` | `load_system` can replace a system by id without full engine restart. | Pending |

### Milestone 7 — Production Hardening
**Goal:** Ship something safe and observable.

| Task | Owner | Files | Acceptance Criteria |
|------|-------|-------|---------------------|
| Memory budget enforcement | core | `malphas_core/src/memory_budget.rs` | Per-environment cap on MSP + command-buffer + system memory; rejects oversize MSPs. |
| mmap diagnostics | core/flutter | `malphas_core/src/msp_loader.rs`, `engine_controller.dart` | Expose mapped size, page faults estimate, Silver Platter build time. |
| Telemetry overlay settings | flutter | `flutter_app/lib/features/settings/settings_screen.dart` | Toggle RAM, FPS, entity count, system list, GPS; persist choices. |
| GPS telemetry (optional) | flutter | `flutter_app/lib/core/services/telemetry_service.dart` | Uses `geolocator` only when enabled and permission granted; never leaks to systems without opt-in. |
| Secure user directory on mobile | flutter | `desktop_path_service.dart` (renamed), Android/iOS native paths | Packs and motors stored in app-private directories; not accessible to other apps. |
| Signature UI | flutter | `flutter_app/lib/features/settings/trust_anchor_settings.dart` | Import/export trust anchor, sign current Environment, show signature status per artifact. |
| CI release hardening | ci | `.github/workflows/release.yml` | Signs release binaries, bundles, and `SHA256SUMS`; blocks if `MALPHAS_INSECURE_SKIP_VERIFY` is enabled. |
| Fuzz/pen tests | tests | `malphas_core/tests/fuzz_msp.rs`, `security_tests.rs` | Fuzz MSP loader and sandbox with arbitrary inputs; no panics or sandbox escapes. |

### Milestone 8 — Polish & Memory Management
**Goal:** Make the app feel finished.

| Task | Owner | Files | Acceptance Criteria |
|------|-------|-------|---------------------|
| Splash redesign | flutter | `flutter_app/lib/features/splash/splash_screen.dart` | Themed, skippable, shows version/build, no hard-coded 2.5s wait on subsequent launches. |
| Memory-aware caches | flutter | `flutter_app/lib/core/services/payload_decode_service.dart`, `skinImages` | LRU with byte-size budget; dispose of unused `ui.Image` instances. |
| Engine shutdown hygiene | core/flutter | `malphas_core/src/bridge.rs`, `engine_controller.dart` | Dispose isolates, free images, unload systems, unmap MSP in deterministic order. |
| Theme & navigation polish | flutter | `theme.dart`, `hub_screen.dart`, `workspace_screen.dart` | Consistent typography, error states, empty states, loading skeletons. |
| Onboarding flow | flutter | `flutter_app/lib/features/onboarding/` | First-run permission requests, directory setup, trust-anchor guidance. |
| Accessibility pass | flutter | all screens | Sufficient contrast, labels on interactive elements, screen-reader support for core flows. |

---

## 5. Architecture Decisions

1. **Unified manifest schema.** The rich UI manifest becomes the source of truth. The CLI compiler normalizes it to the binary MSP format; a new `manifest_version: 2` field distinguishes legacy stripped manifests.
2. **Payload schema registry.** Binary payload layouts are declared in Rust, mirrored in Dart, and identified by a `payload_type_id`. Unknown types are rejected at load time.
3. **Content-addressed asset registry.** Every imported asset gets a SHA-256 hash and is stored under `<project>/assets/<hash[:2]>/<hash>.ext`. Payload descriptors reference the hash, not a fragile path.
4. **Environment bundles.** A `.malphas` file is a signed archive containing one MSP, zero or more MXC files, an `environment.json` policy, and a `signatures/` directory. This is the distribution unit.
5. **User workspace root.** The app persists a user-chosen directory. If none is chosen, it uses `path_provider` idiomatic directories. The repo-root fallback is removed from release builds.
6. **Input as data.** Input events are written into a lock-free ring buffer that is memory-mapped into the MSP address space as an additional Silver Platter slice. Systems read events with the same O(1) model as payloads.
7. **Telemetry is opt-in and UI-only.** RAM/GPS/FPS telemetry is collected in Dart, not passed to MXC systems, unless the user explicitly enables a "systems telemetry" bridge.

---

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| 64-byte FFI layout changes break existing systems. | High | Freeze layout in Milestone 1; add compile-time size assertions; bump ABI version once. |
| Mobile dynamic library loading constraints. | High | Keep `.mxc` as renamed `cdylib`; test on Android API 21+ and iOS with signed frameworks; provide fallback interpreter path. |
| File picker plugins add platform fragility. | Medium | Use well-maintained plugins (`file_picker`, `image_picker`, `path_provider`); abstract behind a service interface. |
| Asset hashing/copying increases disk usage. | Medium | Deduplicate by hash; implement LRU cache; allow users to clear build cache. |
| GPS permission denials hurt UX. | Low | Make GPS telemetry fully optional; default off; explain value in onboarding. |
| Hot system reload introduces state corruption. | Medium | Snapshot system state before reload; mark system tainted on failure; keep old system until new init succeeds. |

---

## 7. Suggested Order of Implementation

For a small team, tackle milestones in this order:

1. **Milestone 1** — stop the drift and establish a safe baseline.
2. **Milestone 2** — define the payload contract; without it the editor cannot produce runnable data.
3. **Milestone 6** (partial) — add `keygen`, `verify`, and `init` so contributors can work without Python scripts.
4. **Milestone 3** — build the editor that produces real assets.
5. **Milestone 4** — make Environments installable and portable.
6. **Milestone 5** — input, canvas interaction, and real rendering.
7. **Milestone 7** — production hardening and telemetry.
8. **Milestone 8** — polish and ship.

---

## 8. Success Metrics

* **Functional:** A non-developer can build a bouncing-ball Environment in under 10 minutes without touching JSON or Rust.
* **Correctness:** `cargo test --release --locked` ≥ 95% pass rate; `flutter test` green on CI.
* **Security:** No sandbox escape or signature bypass in fuzz tests.
* **Performance:** 60 FPS on a mid-range Android device with 1,000 rectangles and 10 systems.
* **Memory:** App stays under a 128 MB RSS budget for the default demo Environment.
* **Adoption:** At least one example Environment can be exported, transferred, and imported on a second device without a source checkout.

---

## 9. Related Documents

* `docs/FFI_CONTRACT.md` — must be updated in Milestone 1.
* `docs/SECURITY.md` — must reflect bundle signing and keygen workflow.
* `.agents/AGENTS.md` — terminology rules (e.g., no "Skin") apply to all new code.
* `CHANGELOG.md` — add the `[3.0.0]` section as work completes.
