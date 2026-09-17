#!/bin/bash

set -euo pipefail

ABSEIL_REPOSITORY=https://github.com/abseil/abseil-cpp.git
ABSEIL_TAG=20260107.0
ABSEIL_COMMIT=d407ef122a08203648451e0fec77b3f868b71112
PROTOBUF_URL=https://github.com/protocolbuffers/protobuf/releases/download/v33.6/protobuf-33.6.tar.gz
PROTOBUF_SHA256=16498d7dc7967e9b100632138babd4b86b61592beeccdd556f67539d9c231355

SOURCE_ROOT=sources
ABSEIL_SOURCE="$SOURCE_ROOT/abseil-cpp-$ABSEIL_TAG"
PROTOBUF_ARCHIVE="$SOURCE_ROOT/protobuf-33.6.tar.gz"
PROTOBUF_SOURCE="$SOURCE_ROOT/protobuf-33.6"
BUILD_ROOT=.build-camx-protobuf-sdk
STAGING_ROOT=camx-protobuf-sdk
PREFIX=/usr
DESTDIR="$PWD/$STAGING_ROOT"

mkdir -p "$SOURCE_ROOT"

if [[ ! -d "$ABSEIL_SOURCE/.git" ]]; then
    rm -rf "$ABSEIL_SOURCE"
    git clone --branch "$ABSEIL_TAG" --depth 1 "$ABSEIL_REPOSITORY" "$ABSEIL_SOURCE"
fi
abseil_source_absolute=$(realpath "$ABSEIL_SOURCE")
git_abseil=(git -c "safe.directory=$abseil_source_absolute" -C "$ABSEIL_SOURCE")
actual_abseil_commit=$("${git_abseil[@]}" rev-parse HEAD)
[[ "$actual_abseil_commit" == "$ABSEIL_COMMIT" ]] || {
    echo "Unexpected Abseil commit: $actual_abseil_commit" >&2
    exit 1
}
[[ -z "$("${git_abseil[@]}" status --porcelain)" ]] || {
    echo "Abseil source tree is dirty: $ABSEIL_SOURCE" >&2
    exit 1
}

if [[ ! -f "$PROTOBUF_ARCHIVE" ]]; then
    curl --fail --location --output "$PROTOBUF_ARCHIVE.tmp" "$PROTOBUF_URL"
    printf '%s  %s\n' "$PROTOBUF_SHA256" "$PROTOBUF_ARCHIVE.tmp" | sha256sum -c -
    mv "$PROTOBUF_ARCHIVE.tmp" "$PROTOBUF_ARCHIVE"
fi
printf '%s  %s\n' "$PROTOBUF_SHA256" "$PROTOBUF_ARCHIVE" | sha256sum -c -
rm -rf "$PROTOBUF_SOURCE"
tar -xzf "$PROTOBUF_ARCHIVE" -C "$SOURCE_ROOT"

rm -rf "$BUILD_ROOT" "$STAGING_ROOT"
mkdir -p "$BUILD_ROOT"

export DEB_HOST_ARCH=arm64
export DEB_HOST_GNU_TYPE=aarch64-linux-gnu
cppflags=$(dpkg-buildflags --get CPPFLAGS)
cflags="$(dpkg-buildflags --get CFLAGS) -march=armv8.2-a"
cxxflags="$(dpkg-buildflags --get CXXFLAGS) -march=armv8.2-a"
ldflags=$(dpkg-buildflags --get LDFLAGS)
common_args=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR=aarch64
    -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc
    -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++
    -DCMAKE_CXX_STANDARD=17
    -DCMAKE_C_FLAGS="$cppflags $cflags"
    -DCMAKE_CXX_FLAGS="$cppflags $cxxflags"
    -DCMAKE_SHARED_LINKER_FLAGS="$ldflags"
    -DCMAKE_EXE_LINKER_FLAGS="$ldflags"
)

cmake -S "$ABSEIL_SOURCE" -B "$BUILD_ROOT/abseil" "${common_args[@]}" \
    -DBUILD_SHARED_LIBS=ON \
    -DABSL_BUILD_TESTING=OFF \
    -DABSL_ENABLE_INSTALL=ON
cmake --build "$BUILD_ROOT/abseil" --parallel "$(nproc)"
DESTDIR="$DESTDIR" cmake --install "$BUILD_ROOT/abseil"
rm -f "$DESTDIR/usr/lib/aarch64-linux-gnu/pkgconfig/absl_heterogeneous_lookup_testing.pc"

cmake -S "$PROTOBUF_SOURCE" -B "$BUILD_ROOT/protobuf" "${common_args[@]}" \
    -DCMAKE_PREFIX_PATH="$DESTDIR/usr" \
    -DZLIB_LIBRARY=/usr/lib/aarch64-linux-gnu/libz.so \
    -DZLIB_INCLUDE_DIR=/usr/include \
    -Dprotobuf_BUILD_SHARED_LIBS=ON \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_CONFORMANCE=OFF \
    -Dprotobuf_BUILD_EXAMPLES=OFF \
    -Dprotobuf_LOCAL_DEPENDENCIES_ONLY=ON
cmake --build "$BUILD_ROOT/protobuf" --parallel "$(nproc)"
DESTDIR="$DESTDIR" cmake --install "$BUILD_ROOT/protobuf"

target_library_path="$DESTDIR/usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu"
if [[ "$(dpkg --print-architecture)" == arm64 ]]; then
    LD_LIBRARY_PATH="$target_library_path" "$DESTDIR/usr/bin/protoc" --version
else
    qemu-aarch64-static -L /usr/aarch64-linux-gnu \
        -E "LD_LIBRARY_PATH=$target_library_path" "$DESTDIR/usr/bin/protoc" --version
fi | grep -Fx 'libprotoc 33.6'
readelf -h "$DESTDIR/usr/lib/aarch64-linux-gnu/libprotobuf.so.33.6.0" | grep -q 'Machine:.*AArch64'
readelf -d "$DESTDIR/usr/lib/aarch64-linux-gnu/libprotobuf.so.33.6.0" | grep -Fq 'Library soname: [libprotobuf.so.33.6.0]'
