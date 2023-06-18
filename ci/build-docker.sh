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
	# arch is what's in `uname -m`.
	# It's also the first item in the target triple.

	# llvm_arch is what's specified in LLVM_TARGET_ARCH / LLVM_TARGETS_TO_BUILD.
	case "$arch" in
		i686|x86_64)
			llvm_arch=X86
			;;
		aarch64)
			llvm_arch=AArch64
			;;
	esac

	"$docker" build \
			  --build-arg BTDU_ARCH="$arch" \
			  --build-arg BTDU_LLVM_ARCH="$llvm_arch" \
			  -t btdu-"$arch" docker

	"$docker" run \
			  --rm \
			  -v "$(cd .. && pwd)":/btdu \
			  --env BTDU_ARCH="$arch" \
			  --env BTDU_LLVM_ARCH="$llvm_arch" \
			  btdu-"$arch" \
			  /btdu/ci/build-inside-docker.sh
done
