#!/bin/bash

set -ex
SOURCE_PATH="$(cd "$(dirname "$0")/../../.." && pwd)"
UTILS_PATH="$(cd "$(dirname "$0")" && pwd)"

WASI_SDK_PATH=$SOURCE_PATH/wasi-sdk

case $(uname -s) in
  Darwin)
    OS_SUFFIX=macos_x86_64
    HOST_PRESET=webassembly-host-install
    TARGET_PRESET=webassembly-macos-target-install
    HOST_SUFFIX=macosx-x86_64
  ;;
  Linux)
    if [ "$(grep RELEASE /etc/lsb-release)" == "DISTRIB_RELEASE=18.04" ]; then
      OS_SUFFIX=ubuntu18.04_x86_64
    elif [ "$(grep RELEASE /etc/lsb-release)" == "DISTRIB_RELEASE=20.04" ]; then
      OS_SUFFIX=ubuntu20.04_x86_64
    else
      echo "Unknown Ubuntu version"
      exit 1
    fi
    HOST_PRESET=webassembly-linux-host-install
    TARGET_PRESET=webassembly-linux-target-install
    HOST_SUFFIX=linux-x86_64
  ;;
  *)
    echo "Unrecognised platform $(uname -s)"
    exit 1
  ;;
esac

YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
TOOLCHAIN_VERSION="${YEAR}${MONTH}${DAY}"
TOOLCHAIN_NAME="swift-wasm-5.4-SNAPSHOT-${YEAR}-${MONTH}-${DAY}-a"

PACKAGE_ARTIFACT="$SOURCE_PATH/swift-wasm-5.4-SNAPSHOT-${OS_SUFFIX}.tar.gz"

BUNDLE_IDENTIFIER="swiftwasm.5.4-${YEAR}${MONTH}${DAY}"
DISPLAY_NAME_SHORT="Swift for WebAssembly 5.4 Snapshot"
DISPLAY_NAME="${DISPLAY_NAME_SHORT} ${YEAR}-${MONTH}-${DAY}"

DIST_TOOLCHAIN_DESTDIR=$SOURCE_PATH/dist-toolchain-sdk

DIST_TOOLCHAIN_SDK=$DIST_TOOLCHAIN_DESTDIR/$TOOLCHAIN_NAME


HOST_BUILD_ROOT=$SOURCE_PATH/host-build
TARGET_BUILD_ROOT=$SOURCE_PATH/target-build
HOST_BUILD_DIR=$HOST_BUILD_ROOT/Ninja-Release

build_host_toolchain() {
  # Build the host toolchain and SDK first.
  env SWIFT_BUILD_ROOT="$HOST_BUILD_ROOT" \
    "$SOURCE_PATH/swift/utils/build-script" \
    --preset-file="$UTILS_PATH/build-presets.ini" \
    --preset=$HOST_PRESET \
    --build-dir="$HOST_BUILD_DIR" \
    INSTALL_DESTDIR="$DIST_TOOLCHAIN_DESTDIR" \
    TOOLCHAIN_NAME="$TOOLCHAIN_NAME" \
    C_CXX_LAUNCHER="$(which sccache)"
}

build_target_toolchain() {

  COMPILER_RT_BUILD_DIR="$TARGET_BUILD_ROOT/compiler-rt-wasi-wasm32"
  cmake -B "$COMPILER_RT_BUILD_DIR" \
    -D CMAKE_TOOLCHAIN_FILE="$SOURCE_PATH/swift/utils/webassembly/compiler-rt-cache.cmake" \
    -D CMAKE_BUILD_TYPE=Release \
    -D CMAKE_C_COMPILER="$HOST_BUILD_DIR/llvm-$HOST_SUFFIX/bin/clang" \
    -D CMAKE_CXX_COMPILER="$HOST_BUILD_DIR/llvm-$HOST_SUFFIX/bin/clang++" \
    -D CMAKE_C_COMPILER_LAUNCHER=sccache \
    -D CMAKE_CXX_COMPILER_LAUNCHER=sccache \
    -D CMAKE_INSTALL_PREFIX="$DIST_TOOLCHAIN_SDK/usr" \
    -D COMPILER_RT_SWIFT_WASI_SDK_PATH="$WASI_SDK_PATH" \
    -G Ninja \
    -S ../llvm-project/compiler-rt

  ninja install -C "$COMPILER_RT_BUILD_DIR"

  SWIFT_STDLIB_BUILD_DIR="$TARGET_BUILD_ROOT/swift-stdlib-wasi-wasm32"
  cmake -B "$TARGET_BUILD_ROOT/swift-stdlib-wasi-wasm32" \
    -C "$SOURCE_PATH/swift/cmake/caches/Runtime-WASI-wasm32.cmake" \
    -D CMAKE_BUILD_TYPE=Release \
    -D CMAKE_C_COMPILER="$HOST_BUILD_DIR/llvm-$HOST_SUFFIX/bin/clang" \
    -D CMAKE_CXX_COMPILER="$HOST_BUILD_DIR/llvm-$HOST_SUFFIX/bin/clang++" \
    -D CMAKE_C_COMPILER_LAUNCHER="$(which sccache)" \
    -D CMAKE_CXX_COMPILER_LAUNCHER="$(which sccache)" \
    -D CMAKE_INSTALL_PREFIX="$DIST_TOOLCHAIN_SDK/usr" \
    -D LLVM_DIR="$HOST_BUILD_DIR/llvm-$HOST_SUFFIX/lib/cmake/llvm/" \
    -D SWIFT_NATIVE_SWIFT_TOOLS_PATH="$HOST_BUILD_DIR/swift-$HOST_SUFFIX/bin" \
    -D SWIFT_WASI_SDK_PATH="$WASI_SDK_PATH" \
    -G Ninja \
    -S "$SOURCE_PATH/swift"

  ninja install -C "$SWIFT_STDLIB_BUILD_DIR"

  "$UTILS_PATH/build-foundation.sh" "$DIST_TOOLCHAIN_SDK"
  "$UTILS_PATH/build-xctest.sh" "$DIST_TOOLCHAIN_SDK"

}

merge_toolchains() {
  # Merge wasi-sdk and the toolchain
  cp -r "$WASI_SDK_PATH/share/wasi-sysroot" "$DIST_TOOLCHAIN_SDK/usr/share"

  # Replace absolute sysroot path with relative path
  sed -i.bak -e "s@\".*/include@\"../../../../share/wasi-sysroot/include@g" "$DIST_TOOLCHAIN_SDK/usr/lib/swift/wasi/wasm32/wasi.modulemap"
  rm "$DIST_TOOLCHAIN_SDK/usr/lib/swift/wasi/wasm32/wasi.modulemap.bak"
  sed -i.bak -e "s@\".*/include@\"../../../../share/wasi-sysroot/include@g" "$DIST_TOOLCHAIN_SDK/usr/lib/swift_static/wasi/wasm32/wasi.modulemap"
  rm "$DIST_TOOLCHAIN_SDK/usr/lib/swift_static/wasi/wasm32/wasi.modulemap.bak"
}

create_darwin_info_plist() {
  echo "-- Create Info.plist --"
  PLISTBUDDY_BIN="/usr/libexec/PlistBuddy"

  DARWIN_TOOLCHAIN_VERSION="5.3.${YEAR}${MONTH}${DAY}"
  BUNDLE_PREFIX="org.swiftwasm"
  DARWIN_TOOLCHAIN_BUNDLE_IDENTIFIER="${BUNDLE_PREFIX}.${YEAR}${MONTH}${DAY}"
  DARWIN_TOOLCHAIN_DISPLAY_NAME_SHORT="Swift for WebAssembly Snapshot"
  DARWIN_TOOLCHAIN_DISPLAY_NAME="${DARWIN_TOOLCHAIN_DISPLAY_NAME_SHORT} ${YEAR}-${MONTH}-${DAY}"
  DARWIN_TOOLCHAIN_ALIAS="swiftwasm"

  DARWIN_TOOLCHAIN_INFO_PLIST="${DIST_TOOLCHAIN_SDK}/Info.plist"
  DARWIN_TOOLCHAIN_REPORT_URL="https://github.com/swiftwasm/swift/issues"
  COMPATIBILITY_VERSION=2
  COMPATIBILITY_VERSION_DISPLAY_STRING="Xcode 8.0"
  DARWIN_TOOLCHAIN_CREATED_DATE="$(date -u +'%a %b %d %T GMT %Y')"
  SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME="YES"

  rm -f "${DARWIN_TOOLCHAIN_INFO_PLIST}"

  ${PLISTBUDDY_BIN} -c "Add DisplayName string '${DARWIN_TOOLCHAIN_DISPLAY_NAME}'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add ShortDisplayName string '${DARWIN_TOOLCHAIN_DISPLAY_NAME_SHORT}'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add CreatedDate date '${DARWIN_TOOLCHAIN_CREATED_DATE}'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add CompatibilityVersion integer ${COMPATIBILITY_VERSION}" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add CompatibilityVersionDisplayString string ${COMPATIBILITY_VERSION_DISPLAY_STRING}" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add Version string '${DARWIN_TOOLCHAIN_VERSION}'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add CFBundleIdentifier string '${DARWIN_TOOLCHAIN_BUNDLE_IDENTIFIER}'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add ReportProblemURL string '${DARWIN_TOOLCHAIN_REPORT_URL}'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add Aliases array" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add Aliases:0 string '${DARWIN_TOOLCHAIN_ALIAS}'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add OverrideBuildSettings dict" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add OverrideBuildSettings:ENABLE_BITCODE string 'NO'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add OverrideBuildSettings:SWIFT_DISABLE_REQUIRED_ARCLITE string 'YES'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add OverrideBuildSettings:SWIFT_LINK_OBJC_RUNTIME string 'YES'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add OverrideBuildSettings:SWIFT_DEVELOPMENT_TOOLCHAIN string 'YES'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"
  ${PLISTBUDDY_BIN} -c "Add OverrideBuildSettings:SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME string '${SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME}'" "${DARWIN_TOOLCHAIN_INFO_PLIST}"

  chmod a+r "${DARWIN_TOOLCHAIN_INFO_PLIST}"
}

build_host_toolchain
build_target_toolchain

merge_toolchains

if [[ "$(uname)" == "Darwin" ]]; then
  create_darwin_info_plist
fi

cd "$DIST_TOOLCHAIN_DESTDIR"
tar cfz "$PACKAGE_ARTIFACT" "$TOOLCHAIN_NAME"
echo "Toolchain archive created successfully!"
