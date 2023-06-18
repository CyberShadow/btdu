#!/bin/bash
set -eEuo pipefail

cd "$(dirname "$0")"

docker=${DOCKER-docker}

arches=("$@")
if [[ ${#arches[@]} -eq 0 ]]
then
	arches=("$(uname -m)")
	printf 'No architectures specified, building for host architecture.\n'
fi

for arch in "${arches[@]}"
do
	# BTDU_ARCH is what's in `uname -m`.
	# It's also the first item in the target triple.
	BTDU_ARCH=$arch

	# BTDU_LLVM_ARCH is what's specified in LLVM_TARGET_ARCH / LLVM_TARGETS_TO_BUILD.
	# BTDU_SUB_ARCH is what's specified in "-march=".
	case "$arch" in
		i686|x86_64)
			BTDU_LLVM_ARCH=X86
			BTDU_SUB_ARCH=
			;;
		arm)
			BTDU_LLVM_ARCH=ARM
			# compiler-rt doesn't support armv7 yet, and requires v6+
			BTDU_SUB_ARCH=armv6
			;;
		aarch64)
			BTDU_LLVM_ARCH=AArch64
			BTDU_SUB_ARCH=
			;;
	esac

	"$docker" build \
			  --build-arg BTDU_ARCH="$BTDU_ARCH" \
			  --build-arg BTDU_SUB_ARCH="$BTDU_SUB_ARCH" \
			  --build-arg BTDU_LLVM_ARCH="$BTDU_LLVM_ARCH" \
			  -t btdu-"$arch" docker

	"$docker" run \
			  --rm \
			  -v "$(cd .. && pwd)":/btdu \
			  --env BTDU_ARCH="$BTDU_ARCH" \
			  --env BTDU_SUB_ARCH="$BTDU_SUB_ARCH" \
			  --env BTDU_LLVM_ARCH="$BTDU_LLVM_ARCH" \
			  btdu-"$arch" \
			  /btdu/ci/build-inside-docker.sh
done
