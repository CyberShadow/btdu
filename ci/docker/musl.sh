#!/bin/bash
set -eEuo pipefail

musl_version=1.2.3

arch=$BTDU_ARCH
triple="$arch"-pc-linux-musl

cc=(/build/host/bin/clang)
cflags=(
	-Os
	-ffunction-sections
	-fdata-sections
	# -flto=full   # Fails with "error: undefined symbol: __libc_start_main"
)

cd /build/src

curl -LO https://www.musl-libc.org/releases/musl-${musl_version}.tar.gz
tar zxf musl-${musl_version}.tar.gz
cd musl-${musl_version}
# LDFLAGS="${ldflags[*]}" 
CC="${cc[*]}" CFLAGS="${cflags[*]}" LIBCC=-lcompiler_rt \
  ./configure \
  --prefix=/build/target \
  --disable-shared

make -j "$(nproc)" install

# rm -rf /build/src
