#!/usr/bin/env bash
# Produces TetherFFI.xcframework and refreshes the checked-in Swift bindings.
#
# Consumers never run this: it needs the Rust toolchain, which the spec says
# they must not. It runs here and in CI, and its outputs are what ship.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: ./scripts/build-xcframework.sh

Produce swift/Artifacts/TetherFFI.xcframework and refresh the checked-in
Swift bindings. Needs the Rust toolchain; consumers never run it.

Options:
  -h, --help   show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Keep native dependencies aligned with the Swift packages, even on a newer Xcode host.
export MACOSX_DEPLOYMENT_TARGET=26.0
export IPHONEOS_DEPLOYMENT_TARGET=26.0

TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)
LIB=libtether_ffi.a
OUT=swift/Artifacts
STAGE=target/xcframework

for target in "${TARGETS[@]}"; do
  echo "building $target"
  cargo build --locked --release --lib -p tether-ffi --features render --target "$target"
done

# Headers and the module map are generated, not hand-written, so the C module
# the bindings import and the one the XCFramework exposes cannot drift apart.
# uniffi picks up crates/tether-ffi/uniffi.toml from the crate itself.
rm -rf "$STAGE"
mkdir -p "$STAGE/include"
cargo run -q --bin uniffi-bindgen -- generate \
  --library "target/aarch64-apple-darwin/release/libtether_ffi.dylib" \
  --language swift --out-dir "$STAGE/gen"
cp "$STAGE/gen/TetherFFI.h" "$STAGE/gen/TetherFFI.modulemap" "$STAGE/include/"
mv "$STAGE/include/TetherFFI.modulemap" "$STAGE/include/module.modulemap"

args=()
for target in "${TARGETS[@]}"; do
  slice="$STAGE/$target"
  mkdir -p "$slice"
  cp "target/$target/release/$LIB" "$slice/$LIB"
  cp -R "$STAGE/include" "$slice/include"
  args+=(-library "$slice/$LIB" -headers "$slice/include")
done

mkdir -p "$OUT"
xcodebuild -create-xcframework "${args[@]}" -output "$STAGE/TetherFFI.xcframework" >/dev/null
rm -rf "$OUT/TetherFFI.xcframework"
mv "$STAGE/TetherFFI.xcframework" "$OUT/TetherFFI.xcframework"

# The generated Swift is checked in so a consumer needs no Rust to build.
# CI compares it and does not replace the file under test. A local run refreshes it.
mkdir -p swift/Sources/TetherFFIBindings
bindings=swift/Sources/TetherFFIBindings/TetherFFIBindings.swift
if [[ -n "${CI:-}" ]]; then
  diff -u "$bindings" "$STAGE/gen/TetherFFIBindings.swift"
else
  cp "$STAGE/gen/TetherFFIBindings.swift" "$bindings"
fi

echo "wrote $OUT/TetherFFI.xcframework and swift/Sources/TetherFFIBindings/TetherFFIBindings.swift"
