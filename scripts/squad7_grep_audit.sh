#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/../flutter_app"
failures=0
check() {
  local label="$1"
  shift
  local count
  # Grep returns 1 when there are no matches; that is the desired "0" result,
  # so we must not abort on that exit code.
  count=$("$@" 2>/dev/null | wc -l) || true
  echo "$label: $count"
  if [ "$count" -ne 0 ]; then
    failures=1
  fi
}
check "MalphasObject/MalphasSkin/class Object matches" grep -r "MalphasObject\|MalphasSkin\|class.*Object" lib/
check "toJson/fromJson in core/models" grep -r "toJson\|fromJson" lib/core/models/
check "stale ABI versions 0x0207/0x0208" grep -r "0x0207\|0x0208" lib/core/ffi/
check "hardcoded/test/fake keys" grep -r "hardcoded\|test_key\|fake_key" lib/
check "non-ASCII Spanish chars" grep -r "[áéíóúñÁÉÍÓÚÑ]" lib/
if [ "$failures" -ne 0 ]; then
  echo "SQUAD 7 grep audit FAILED"
  exit 1
fi
echo "SQUAD 7 grep audit PASSED"
