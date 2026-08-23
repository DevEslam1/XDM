#!/usr/bin/env bash
#
# Rebuild packages/libtorrent_flutter's Android native library from source.
#
# ── Why this script exists ────────────────────────────────────────────────────
#
# The prebuilt liblibtorrent_flutter.so in packages/libtorrent_flutter/prebuilt/
# android/ predates bridge ABI 2. Verified against the shipped x86_64 binary:
#
# Of the 44 unique symbols ffi_bindings.dart looks up, 30 are present and these
# 14 are ABSENT:
#
#   lt_add_magnet_resume        lt_add_torrent_file_resume
#   lt_save_resume_data         lt_take_saved_resume_data
#   lt_load_resume_data         lt_get_file_progress
#   lt_get_trackers             lt_add_tracker
#   lt_remove_tracker           lt_force_reannounce
#   lt_force_dht_announce       lt_set_piece_deadline
#   lt_set_sequential_download  lt_set_super_seeding
#
# Every one of the 14 is implemented in src/torrent_bridge.cpp (lines 2174-2709),
# so nothing needs writing — they exist in source and are simply not in this
# binary. Note the last two: sequential download and super seeding are silently
# unavailable on Android today.
#
# The binary also contains no "bridge_abi=" / "status_size=" strings, so its
# lt_version() cannot emit the markers src/torrent_bridge.cpp appends since
# LT_BRIDGE_ABI 2. BridgeAbiReport.reportsAbi is therefore false, isCompatible
# is false, and TorrentService.bridgeCompatible flips off at startup — which is
# the "INCOMPATIBLE native bridge" line in the run log.
#
# Because lt_torrent_status is a different size in that binary than the 1880
# bytes ffi_bindings.dart reads, every field past the drift point decodes as
# unrelated memory. That is the root cause of seeds/peers reading 0, the
# invented download speeds, and the fake percentages — not a Dart bug.
#
# Redownloading cannot fix it. prebuilt/android/.libtorrent_flutter_version
# records that the on-disk .so already came from release v2.0.0, and
# android/build.gradle builds the asset URL from pubspec's version, so the same
# tag returns the same pre-ABI-2 bytes. Only compiling torrent_bridge.cpp does.
#
# To force a redownload anyway (cheap, and the only way to be certain):
#   rm packages/libtorrent_flutter/prebuilt/android/.libtorrent_flutter_version
#   rm packages/libtorrent_flutter/prebuilt/android/*/liblibtorrent_flutter.so
#   flutter run            # gradle re-fetches on the next Android configure
#
# ── What this script does ─────────────────────────────────────────────────────
#
# src/CMakeLists.txt refuses to configure for Android unless a static libtorrent
# already exists (it hard-errors at the FATAL_ERROR in its ANDROID branch):
#
#   packages/libtorrent_flutter/android/src/main/jniLibs/<ABI>/libtorrent-rasterbar.a
#   packages/libtorrent_flutter/android/src/main/include/   <- libtorrent + boost
#
# Right now android/src/main/ holds only AndroidManifest.xml. This script fills
# both paths by cross-compiling libtorrent 2.1.1 with the NDK, then flips the
# plugin over to the source build.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   tool/rebuild_android_native.sh                 # x86_64 only (the emulator)
#   tool/rebuild_android_native.sh x86_64 arm64-v8a
#
# Env overrides:
#   LT_CRYPTO=built-in|openssl   crypto backend (default built-in — see below)
#   LT_CMAKE_EXTRA="..."         extra flags appended to the libtorrent configure
#   NDK_VER=28.2.13676358        NDK to build with
#
# ── The crypto trade-off, stated plainly ──────────────────────────────────────
#
# Default is LT_CRYPTO=built-in, which keeps libtorrent-rasterbar.a free of
# external dependencies. That matters because src/CMakeLists.txt links only
# `libtorrent_static log` — it passes no OpenSSL to the linker, so an OpenSSL-
# backed libtorrent.a would fail to link the shared object with undefined
# symbols unless the archives are merged or that CMakeLists is patched.
#
# built-in keeps DHT, PEX, LSD, uTP, and MSE/PE peer encryption. What it gives
# up is SSL torrents and https:// tracker/webseed URLs (udp:// and http://
# trackers still work). If you need https trackers, cross-compile OpenSSL for
# each ABI, re-run with LT_CRYPTO=openssl, and merge libcrypto.a/libssl.a into
# libtorrent-rasterbar.a with an `ar -M` MRI script so the archive stays self
# contained. Note that OpenSSL's build needs perl and GNU make, which a bare
# Git-Bash-on-Windows host does not have.
#
# ── Status ────────────────────────────────────────────────────────────────────
#
# UNVERIFIED. This was written while no shell was available to run it, so no
# step below has been executed. Expect to iterate on the libtorrent configure
# flags in particular: 2.1.x spells the backend `-Dcrypto=<x>`, whereas 2.0.x
# used `-Dencryption=ON|OFF`. If configure rejects -Dcrypto, that is the first
# thing to switch.
#
set -euo pipefail

# ── Locate the repo and the Android SDK ───────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$REPO_ROOT/packages/libtorrent_flutter"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

[ -d "$PLUGIN" ] || die "plugin not found at $PLUGIN"

LOCAL_PROPS="$REPO_ROOT/android/local.properties"
[ -f "$LOCAL_PROPS" ] || die "missing $LOCAL_PROPS (need sdk.dir)"

# sdk.dir is written with escaped Windows separators; normalise to forward slashes.
SDK="$(sed -n 's/^sdk\.dir=//p' "$LOCAL_PROPS" | head -1 | sed 's/\\\\/\//g; s/\\/\//g')"
[ -n "$SDK" ] || die "could not read sdk.dir from $LOCAL_PROPS"
[ -d "$SDK" ] || die "sdk.dir points at $SDK, which does not exist"

NDK_VER="${NDK_VER:-28.2.13676358}"   # pinned by android/app/build.gradle.kts
NDK="$SDK/ndk/$NDK_VER"
[ -d "$NDK" ] || die "NDK $NDK_VER not installed at $NDK"

TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
[ -f "$TOOLCHAIN" ] || die "no NDK toolchain file at $TOOLCHAIN"

# Prefer the SDK's cmake 3.22.x over 4.x: libtorrent and Boost still declare
# pre-3.5 compatibility in places, which cmake 4 removed support for.
CMAKE=""; NINJA=""
for v in 3.22.1 3.31.6 4.1.2; do
  if [ -x "$SDK/cmake/$v/bin/cmake.exe" ]; then
    CMAKE="$SDK/cmake/$v/bin/cmake.exe"
    NINJA="$SDK/cmake/$v/bin/ninja.exe"
    break
  fi
done
[ -n "$CMAKE" ] || CMAKE="$(command -v cmake || true)"
[ -n "$CMAKE" ] || die "no cmake found (looked in $SDK/cmake/*/bin and PATH)"
[ -n "$NINJA" ] && [ -x "$NINJA" ] || NINJA="$(command -v ninja || true)"
[ -n "$NINJA" ] || die "no ninja found (looked in $SDK/cmake/*/bin and PATH)"

# NDK host prebuilt dir, for the Boost.System stub compile below.
HOST_TAG="windows-x86_64"
[ -d "$NDK/toolchains/llvm/prebuilt/$HOST_TAG" ] || {
  for t in linux-x86_64 darwin-x86_64; do
    [ -d "$NDK/toolchains/llvm/prebuilt/$t" ] && HOST_TAG="$t" && break
  done
}
LLVM_BIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
[ -d "$LLVM_BIN" ] || die "no llvm prebuilt toolchain under $NDK/toolchains/llvm/prebuilt"

ABIS=("$@"); [ ${#ABIS[@]} -gt 0 ] || ABIS=(x86_64)
API=24                                # matches minSdk in app/build.gradle.kts
LT_CRYPTO="${LT_CRYPTO:-built-in}"
LT_CMAKE_EXTRA="${LT_CMAKE_EXTRA:-}"

BOOST_VER=1.86.0
BOOST_TAR=boost_1_86_0
LT_VER=2.1.1

DEPS="$REPO_ROOT/build/native-deps"
BOOST_SRC="$DEPS/$BOOST_TAR"
LT_SRC="$DEPS/libtorrent-rasterbar-$LT_VER"
INSTALL_INC="$PLUGIN/android/src/main/include"

say "repo      $REPO_ROOT"
say "sdk       $SDK"
say "ndk       $NDK ($NDK_VER)"
say "cmake     $CMAKE"
say "ninja     $NINJA"
say "abis      ${ABIS[*]}"
say "crypto    $LT_CRYPTO"

mkdir -p "$DEPS"

# ── Fetch sources ─────────────────────────────────────────────────────────────
fetch() { # url dest
  [ -f "$2" ] && { echo "  cached $(basename "$2")"; return; }
  echo "  downloading $(basename "$2")"
  curl -fL --retry 3 -o "$2.part" "$1"
  mv "$2.part" "$2"
}

say "Fetching Boost $BOOST_VER headers and libtorrent $LT_VER"
fetch "https://archives.boost.io/release/$BOOST_VER/source/$BOOST_TAR.tar.gz" \
      "$DEPS/$BOOST_TAR.tar.gz"
fetch "https://github.com/arvidn/libtorrent/releases/download/v$LT_VER/libtorrent-rasterbar-$LT_VER.tar.gz" \
      "$DEPS/libtorrent-rasterbar-$LT_VER.tar.gz"

[ -d "$BOOST_SRC" ] || { echo "  extracting boost"; tar -xzf "$DEPS/$BOOST_TAR.tar.gz" -C "$DEPS"; }
[ -d "$LT_SRC" ]    || { echo "  extracting libtorrent"; tar -xzf "$DEPS/libtorrent-rasterbar-$LT_VER.tar.gz" -C "$DEPS"; }

[ -d "$BOOST_SRC/boost" ] || die "boost headers missing at $BOOST_SRC/boost"
[ -f "$LT_SRC/CMakeLists.txt" ] || die "libtorrent source missing at $LT_SRC"

# ── Per-ABI build ─────────────────────────────────────────────────────────────
# Boost.System has been header-only since 1.69, but CMake's FindBoost module
# still insists on an importable archive for the `system` component. Compiling a
# stub translation unit that pulls in the header satisfies the search without
# needing b2 cross-compiled for Android.
abi_triple() {
  case "$1" in
    x86_64)      echo "x86_64-linux-android" ;;
    x86)         echo "i686-linux-android" ;;
    arm64-v8a)   echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "armv7a-linux-androideabi" ;;
    *) die "unknown ABI $1" ;;
  esac
}

for ABI in "${ABIS[@]}"; do
  TRIPLE="$(abi_triple "$ABI")"
  STUB_DIR="$DEPS/boost-stub/$ABI/lib"
  BUILD="$DEPS/build/libtorrent-$ABI"
  JNI_DIR="$PLUGIN/android/src/main/jniLibs/$ABI"

  say "[$ABI] Boost.System stub for FindBoost"
  mkdir -p "$STUB_DIR"
  if [ ! -f "$STUB_DIR/libboost_system.a" ]; then
    printf '#include <boost/system/error_code.hpp>\nnamespace { int lt_boost_system_stub_tu; }\n' \
      > "$DEPS/boost-stub/stub.cpp"
    "$LLVM_BIN/clang++" --target="$TRIPLE$API" -c -O2 -std=c++17 \
      -I"$BOOST_SRC" -o "$DEPS/boost-stub/$ABI/stub.o" "$DEPS/boost-stub/stub.cpp"
    "$LLVM_BIN/llvm-ar" rcs "$STUB_DIR/libboost_system.a" "$DEPS/boost-stub/$ABI/stub.o"
  fi

  say "[$ABI] configuring libtorrent $LT_VER"
  # shellcheck disable=SC2086
  "$CMAKE" -S "$LT_SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API" \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -Dcrypto="$LT_CRYPTO" \
    -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF \
    -Dpython-bindings=OFF \
    -DBOOST_ROOT="$BOOST_SRC" \
    -DBoost_INCLUDE_DIR="$BOOST_SRC" \
    -DBoost_LIBRARY_DIR="$STUB_DIR" \
    -DBoost_USE_STATIC_LIBS=ON \
    -DBoost_NO_BOOST_CMAKE=ON \
    $LT_CMAKE_EXTRA

  say "[$ABI] building libtorrent (this is the slow part)"
  "$CMAKE" --build "$BUILD" --parallel

  say "[$ABI] installing libtorrent-rasterbar.a"
  ARCHIVE="$(find "$BUILD" -name 'libtorrent-rasterbar.a' -print -quit)"
  [ -n "$ARCHIVE" ] || die "[$ABI] build produced no libtorrent-rasterbar.a under $BUILD"
  mkdir -p "$JNI_DIR"
  cp "$ARCHIVE" "$JNI_DIR/libtorrent-rasterbar.a"
  echo "  -> $JNI_DIR/libtorrent-rasterbar.a"
done

# ── Headers (shared across ABIs; src/CMakeLists.txt points both include vars
#    at this one directory) ─────────────────────────────────────────────────────
say "Installing headers into $INSTALL_INC"
mkdir -p "$INSTALL_INC"
cp -r "$LT_SRC/include/libtorrent" "$INSTALL_INC/"
cp -r "$BOOST_SRC/boost" "$INSTALL_INC/"
# libtorrent generates a few headers (export.hpp / version macros) into its
# build tree rather than the source tree; fold them in if present.
for ABI in "${ABIS[@]}"; do
  GEN="$DEPS/build/libtorrent-$ABI/include"
  [ -d "$GEN" ] && cp -r "$GEN/." "$INSTALL_INC/" || true
done
[ -f "$INSTALL_INC/libtorrent/session.hpp" ] || die "libtorrent headers did not install"
[ -d "$INSTALL_INC/boost/asio" ] || die "boost headers did not install"

# ── Retire the stale prebuilt so gradle cannot pick it over the source build ──
say "Retiring the stale prebuilt"
PREBUILT="$PLUGIN/prebuilt/android"
rm -f "$PREBUILT/.libtorrent_flutter_version"
for ABI in "${ABIS[@]}"; do
  rm -f "$PREBUILT/$ABI/liblibtorrent_flutter.so"
  echo "  removed $ABI/liblibtorrent_flutter.so and the version stamp"
done

cat <<EOF

── Done. Next ────────────────────────────────────────────────────────────────

android/build.gradle selects the source build from a gradle property, and
project.findProperty() reads android/gradle.properties, so adding it there makes
every 'flutter run' use it:

    libtorrentFlutterBuildFromSource=true
    libtorrentFlutterAbis=${ABIS[*]// /,}

Then:

    flutter run

Verify the new binary really is ABI 2 — these must all print a match:

    grep -c lt_get_file_progress packages/libtorrent_flutter/prebuilt/android/*/liblibtorrent_flutter.so
    grep -c status_size=         packages/libtorrent_flutter/prebuilt/android/*/liblibtorrent_flutter.so

and the run log must no longer contain "INCOMPATIBLE native bridge".
EOF
