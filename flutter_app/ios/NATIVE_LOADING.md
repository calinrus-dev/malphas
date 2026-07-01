# iOS Native Loading Notes

## Dynamic `.mxc` / `.dylib` loading

iOS strictly limits dynamic library loading outside the app bundle. Apps distributed
through the App Store cannot download or `dlopen` unsigned dynamic libraries at
runtime. The current `MalphasBindings` attempts to load:

- `malphas_core.framework/malphas_core`
- `libmalphas_core.dylib`

## Required setup

1. Embed `libmalphas_core.dylib` (or a framework wrapper) into the iOS app bundle
   via Xcode:
   - `Runner.xcodeproj` → Target → `Build Phases` → `Embed Libraries`
   - Ensure `Code Sign On Copy` is checked.

2. If `.mxc` system libraries are used, they must also be embedded and signed.

## Static linking fallback

For production App Store builds, consider statically linking `malphas_core` into a
Flutter plugin or directly into the Runner target. The dynamic-loading code in
`MalphasBindings` will then fall back to framework lookup, but the symbol set must
be exported with the exact FFI names expected by Dart.

## Runtime behavior

If no native library can be loaded, `MalphasBindings.isNativeAvailable` returns
`false` and the engine controller surfaces a user-friendly error dialog instead of
crashing.
