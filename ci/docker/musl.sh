#!/bin/bash
set -eEuo pipefail

musl_version=1.2.3

arch=$BTDU_ARCH
triple="$arch"-linux-musl

# target_dir=/tmp/btdu-build-$arch

# cc=("${target_dir}/bin/musl-gcc" -static)
cc=(/build/host/bin/clang)
cflags=(
	-Os
	# -ffunction-sections
	# -fdata-sections
	-flto=full
	# -static
	--target="$triple"
	# -DHAVE_SETENV -DHAVE_PUTENV
)
# ldflags=(
# 	# "-Wl,--gc-sections"
# )

cd /build/src

curl -LO https://www.musl-libc.org/releases/musl-${musl_version}.tar.gz
tar zxf musl-${musl_version}.tar.gz
cd musl-${musl_version}
# LDFLAGS="${ldflags[*]}" 
CC="${cc[*]}" CFLAGS="${cflags[*]}" \
  ./configure \
  --prefix=/build/target \
  --disable-shared

make -j "$(nproc)" install

# rm -rf /build/src
