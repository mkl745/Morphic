#!/usr/bin/env bash
# Build libmorphic_bridge.so for the Android ABIs using the NDK, and place the
# results in the Flutter app's jniLibs. Phase 0 builds the native lib in CI; M1.1
# replaces this with cargokit (ADR-0002 addendum).
#
# Requires: cargo/rustup, and an Android NDK (ANDROID_NDK_HOME or under $ANDROID_HOME/ndk).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Locate the NDK.
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK:-}}}}"
if [[ -z "$NDK" ]]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
  NDK="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
if [[ -z "$NDK" || ! -d "$NDK" ]]; then
  echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME." >&2
  exit 1
fi
echo "Using NDK: $NDK"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [[ ! -d "$TOOLCHAIN" ]]; then
  echo "ERROR: NDK toolchain not found at $TOOLCHAIN" >&2
  exit 1
fi

JNI_LIBS="apps/morphic_flutter/android/app/src/main/jniLibs"

build_target() {
  local RUST_TARGET="$1" CLANG_TRIPLE="$2" ABI="$3"
  local API=24
  local LINKER="$TOOLCHAIN/${CLANG_TRIPLE}${API}-clang"
  local UPPER
  UPPER="$(echo "$RUST_TARGET" | tr '[:lower:]-' '[:upper:]_')"

  echo "==> Building $RUST_TARGET ($ABI)"
  rustup target add "$RUST_TARGET"

  # Pure-Rust crate: only the linker + archiver are needed from the NDK.
  export "CARGO_TARGET_${UPPER}_LINKER=$LINKER"
  export "CARGO_TARGET_${UPPER}_AR=$TOOLCHAIN/llvm-ar"
  # Force 16 KB page alignment (Google Play requirement for native code).
  export "CARGO_TARGET_${UPPER}_RUSTFLAGS=-C link-arg=-Wl,-z,max-page-size=16384"

  cargo build --release -p morphic-bridge --target "$RUST_TARGET"

  mkdir -p "$JNI_LIBS/$ABI"
  cp "target/$RUST_TARGET/release/libmorphic_bridge.so" \
     "$JNI_LIBS/$ABI/libmorphic_bridge.so"
  echo "    -> $JNI_LIBS/$ABI/libmorphic_bridge.so"
}

build_target aarch64-linux-android   aarch64-linux-android   arm64-v8a
build_target armv7-linux-androideabi armv7a-linux-androideabi armeabi-v7a
build_target x86_64-linux-android    x86_64-linux-android    x86_64

echo "Native builds complete."
