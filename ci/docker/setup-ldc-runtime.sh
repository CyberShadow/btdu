#!/bin/bash
set -eEuo pipefail

host_arch=$(uname -m)
target_arch=$BTDU_ARCH

cd /tmp

args=(
	env
)

target_api=gnu
case "$target_arch" in
	arm)
		target_api=gnueabihf
		;;
	*)
esac

if [[ "$host_arch" != "$target_arch" ]]; then
	args+=(CC="$target_arch"-linux-"$target_api"-gcc)
fi

args+=(
	ldc2-host/bin/ldc-build-runtime
	--dFlags="-mtriple=$target_arch-linux-$target_api"
	--dFlags="-flto=full"
	--dFlags="-O"
	--dFlags="--release"
	BUILD_SHARED_LIBS=OFF
) ; "${args[@]}"

