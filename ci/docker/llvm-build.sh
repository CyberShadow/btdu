#!/bin/bash
set -eEuo pipefail

cd /build/src/llvm

target_arch=$BTDU_ARCH

case "$target_arch" in
	x86_64)
		target_llvm_arch=X86
		;;
	aarch64)
		target_llvm_arch=AArch64
		;;
esac


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

		-DLLVM_DEFAULT_TARGET_TRIPLE="$target_arch"-pc-linux-musl
		-DLLVM_TARGET_ARCH="$target_llvm_arch"
		-DLLVM_TARGETS_TO_BUILD="$target_llvm_arch"

		-DCOMPILER_RT_INCLUDE_TESTS=OFF
		-DLLVM_INCLUDE_TESTS=OFF
		-DLLVM_ENABLE_PROJECTS='clang;lld'
	) ; "${args[@]}"
	ninja install
)
rm -rf llvm.build
