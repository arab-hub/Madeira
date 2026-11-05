#!/usr/bin/env bash
# Apply the Wine changes this repository carries as patches (docs/BUILDING.md,
# "OpenGL games"). Safe to run again. Without wine-opengl-winios.patch a build
# compiles, then 32-bit OpenGL games fault in wow64_thread_attach and 64-bit ones
# get an opengl32.dll at the wrong base, so a patch that will not apply stops the build.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PATCH="$ROOT/patches/wine-opengl-winios.patch"

if git -C "$ROOT/wine" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "Wine patch already applied: $(basename "$PATCH")"
else
  git -C "$ROOT/wine" apply "$PATCH"
  echo "Wine patch applied: $(basename "$PATCH")"
fi
