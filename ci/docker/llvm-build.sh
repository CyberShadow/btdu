#!/bin/bash
set -eEuo pipefail

cd /build/src/llvm

mkdir llvm.build
(
	cd llvm.build
	args=(
		cmake
		-G Ninja
		../llvm-project/llvm
		-DCMAKE_BUILD_TYPE=Release
		-DCMAKE_INSTALL_PREFIX=/build/host
		-DLLVM_BINUTILS_INCDIR=/usr/include  # for ld.gold plugin

		-DLLVM_DEFAULT_TARGET_TRIPLE="$BTDU_ARCH"-unknown-linux-musl
		-DLLVM_TARGET_ARCH="$BTDU_LLVM_ARCH"
		-DLLVM_TARGETS_TO_BUILD="$BTDU_LLVM_ARCH"

		-DCOMPILER_RT_INCLUDE_TESTS=OFF
		-DLLVM_INCLUDE_TESTS=OFF
		-DLLVM_ENABLE_PROJECTS='clang;lld'
	) ; "${args[@]}"
	ninja install
)
rm -rf llvm.build
