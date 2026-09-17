#!/usr/bin/env bash
# Produces TetherFFI.xcframework and refreshes the checked-in Swift bindings.
#
# Consumers never run this: it needs the Rust toolchain, which the spec says
# they must not. It runs here and in CI, and its outputs are what ship.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)
LIB=libtether_ffi.a
OUT=swift/Artifacts
STAGE=target/xcframework

for target in "${TARGETS[@]}"; do
  echo "building $target"
  cargo build --release -p tether-ffi --target "$target"
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

rm -rf "$OUT/TetherFFI.xcframework"
mkdir -p "$OUT"
xcodebuild -create-xcframework "${args[@]}" -output "$OUT/TetherFFI.xcframework" >/dev/null

# The generated Swift is checked in so a consumer needs no Rust to build.
# CI re-runs this and fails on a diff; it is never hand-edited.
mkdir -p swift/Sources/TetherFFIBindings
cp "$STAGE/gen/TetherFFIBindings.swift" swift/Sources/TetherFFIBindings/TetherFFIBindings.swift

echo "wrote $OUT/TetherFFI.xcframework and swift/Sources/TetherFFIBindings/TetherFFIBindings.swift"
