# Malphas Flutter Frontend

This directory contains the Flutter frontend for Malphas: a passive display server
that drives the native Rust core through a small C-ABI boundary and reads a
shared-memory render command stream on every VSync pulse.

## What lives here

```
flutter_app/
├── lib/
│   ├── main.dart                              # App entry point
│   ├── core/
│   │   ├── ffi/                               # Dart FFI bindings and C struct mirrors
│   │   │   ├── malphas_bindings.dart
│   │   │   └── types.dart
│   │   ├── compiler/                          # Thin wrapper around malphas-cli
│   │   │   └── package_compiler.dart
│   │   ├── theme/                             # Terminal-inspired dark theme
│   │   │   └── theme.dart
│   │   └── ui_primitives/                     # Low-level canvas rasterizer
│   │       └── primitive_canvas.dart
│   └── features/
│       ├── splash/                            # Splash screen
│       ├── hub/                               # Environment / workspace hub
│       ├── workspace/                         # Live simulation workspace
│       ├── engine_manager/                    # Native motor discovery and hot-swap
│       └── package_manager/                   # MHP/MSP discovery and compilation
├── android/app/src/main/jniLibs/              # Android native libraries (generated)
├── motors/                                    # Native motors + CLI (generated, gitignored)
├── test/                                      # Dart widget and integration tests
├── assets/                                    # Fonts and sprites
├── pubspec.yaml
└── analysis_options.yaml
```

## Local development

### 1. Build the Rust workspace

From the repository root, run the build script for your platform:

```bash
# Linux / macOS / Git Bash on Windows
./build.sh

# Windows PowerShell
.\build_core.ps1
```

This produces:

- `malphas_core` native motor (`libmalphas_core.so`, `libmalphas_core.dylib`, or `malphas_core.dll`).
- `malphas-cli` executable.
- Timestamped copies under `flutter_app/motors/` plus a non-timestamped symlink/copy.
- On Linux/macOS with `ANDROID_NDK_HOME` set, Android libraries under `flutter_app/android/app/src/main/jniLibs/<abi>/`.

`motors/` is gitignored; never commit native binaries.

### 2. Install Flutter dependencies

```bash
cd flutter_app
flutter pub get
```

### 3. Static analysis and format

```bash
flutter analyze --no-fatal-infos --no-fatal-warnings
dart format --set-exit-if-changed .
```

### 4. Run tests

#### Linux / macOS

The dynamic linker must find the shared motor in `motors/`:

```bash
export LD_LIBRARY_PATH="$PWD/motors:$LD_LIBRARY_PATH"
flutter test
```

#### Windows

`flutter test` finds `malphas_core.dll` automatically once `build_core.ps1` has
copied it into `motors/`.

```powershell
flutter test
```

### 5. Run the app

```bash
# Desktop example — Linux
flutter run -d linux

# Windows
flutter run -d windows

# macOS
flutter run -d macos

# Android (requires a connected device or emulator)
flutter run
```

## Release builds

```bash
# Android
flutter build appbundle --release
flutter build apk --release

# Desktop
flutter build windows --release
flutter build linux --release
flutter build macos --release
```

## How the frontend relates to the core

- Flutter owns the only clock. On every `Ticker` pulse it calls `trigger_engine_pulse()`.
- The Rust simulation thread wakes up, drains pending input, executes one frame of bytecode, writes render commands into the back buffer, and flips the bridge.
- Flutter reads the front buffer on the next frame and rasterizes rectangles and text via `PrimitiveCanvas`.
- Render commands are homogeneous 24-byte `DartRenderCommand` slots. Text commands carry a pointer to a `TextPayload` in the Arena; Dart must not perform pointer arithmetic on the bridge or Arena.

See the repository `README.md` and `.agents/AGENTS.md` for the full FFI safety rules,
C-ABI layout, and CI contract.

## Common issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Failed to load dynamic library` | Motor missing from `motors/` or `LD_LIBRARY_PATH` not set. | Run `./build.sh` / `.\build_core.ps1` and export `LD_LIBRARY_PATH` on Linux/macOS. |
| `Invalid argument(s): Invalid ffi pointer` | Dart and Rust struct layouts out of sync. | Verify `flutter_app/lib/core/ffi/types.dart` matches the Rust `#[repr(C)]` definitions. |
| `flutter test` hangs | Engine thread not shutting down cleanly. | Ensure tests call `shutdown_engine` and restore `.sig` files in `tearDown`. |
| Android build cannot find `libmalphas_core.so` | `jniLibs/` not populated. | Set `ANDROID_NDK_HOME` and run `./build.sh`. |

## CI checks

Every pull request runs:

- `rust_ci.yml` — Rust build, test, Clippy, format, signing, and artifact upload.
- `flutter_lint.yml` — `flutter analyze` and `dart format --set-exit-if-changed .`.
- `flutter_ci.yml` — Download Rust artifacts, place them in `motors/`, and run `flutter test`.
- `android_build.yml` — Cross-compile Android engines.

See `.github/workflows/` for the exact commands.

## License

MIT
