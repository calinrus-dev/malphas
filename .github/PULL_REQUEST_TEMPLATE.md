## Summary

Briefly describe what this PR does and which workstream it belongs to.

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation
- [ ] Refactor
- [ ] CI / build
- [ ] Breaking change

## Related issues

Closes #(issue)

## Checklist

- [ ] `cargo fmt -- --check` passes.
- [ ] `cargo clippy --release -- -D warnings` passes.
- [ ] `cargo test --release` passes.
- [ ] `dart format --set-exit-if-changed .` passes.
- [ ] `flutter analyze --no-fatal-infos --no-fatal-warnings` passes.
- [ ] `flutter test` passes (Linux/macOS require `LD_LIBRARY_PATH`).
- [ ] `./build.sh` or `.\build_core.ps1` succeeds and populates `flutter_app/motors/`.
- [ ] `CHANGELOG.md` is updated under `[Unreleased]` if the change is user-facing.
- [ ] No native binaries (`.dll`, `.so`, `.dylib`, `.sig`) are committed.

## Testing

Describe how you tested the change, including commands run and platforms verified.

## Notes for reviewers

Anything reviewers should pay special attention to (FFI layout changes, new CI dependencies, etc.).
