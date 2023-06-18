#!/bin/bash
set -eEuo pipefail

target_arch=$BTDU_ARCH


# /build/host/bin/ldc-build-runtime --help
# exit 123


cflags=(
	-fuse-ld=/build/host/bin/ld.lld
	--rtlib=compiler-rt
	-resource-dir=/build/target
	--sysroot=/build/target
	# -flto=full
	# --target=$target_arch-linux-musl -fuse-ld=/tmp/btdu-build-x86_64/bin/ld.musl-clang -v -nodefaultlibs -lc
)
dflags=(
	-mtriple="$target_arch"-unknown-linux-musl
	-flto=full
	-O
	--release
)

args=(
	env
	CC=/build/host/bin/clang
	# CFLAGS="-flto=full --target=$target_arch-linux-musl -fuse-ld=gold -v -nodefaultlibs -lc"
	CFLAGS="${cflags[*]}"
	# LDFLAGS="--target=$target_arch-linux-musl"

	# CC=clang
	# CFLAGS="-flto=full --sysroot /tmp/btdu-build-x86_64 -isystem /tmp/btdu-build-x86_64/include --target=$target_arch-linux-musl -fuse-ld=gold"


	/build/host/bin/ldc-build-runtime
	--ldcSrcDir=/build/src/ldc/ldc
	--buildDir=/build/target/druntime
	"${dflags[@]/#/--dFlags=}"
	--ninja
	BUILD_SHARED_LIBS=OFF
) ; "${args[@]}"
