#!/bin/bash
set -eEuo pipefail

cd /build/src/llvm

mkdir libcxx.build
(
	cd libcxx.build
	# args=(
	# 	env
	# 	CC=/build/host/bin/clang
	# 	CXX=/build/host/bin/clang++
	# 	# CFLAGS='-static'
	# 	LLVM_CONFIG=/build/host/bin/llvm-config
		
	# 	cmake
	# 	-G Ninja
	# 	../llvm-project/libcxx
	# 	-DCMAKE_BUILD_TYPE=Release
	# 	-DCMAKE_INSTALL_PREFIX=/build/target

	# 	-DCMAKE_SYSROOT=/build/target
	# 	-DDEFAULT_SYSROOT=/build/target

	# 	# -DCMAKE_C_COMPILER=/build/host/bin/clang
	# 	# -DCMAKE_CXX_COMPILER=/build/host/bin/clang++
	# 	-DLLVM_DEFAULT_TARGET_TRIPLE="$target_arch"-unknown-linux-musl
	# 	-DLLVM_TARGET_ARCH="$target_llvm_arch"
	# 	-DLLVM_TARGETS_TO_BUILD="$target_llvm_arch"
	# ) ; "${args[@]}"
	args=(
		env
		CC=/build/host/bin/clang
		CXX=/build/host/bin/clang++
		# CFLAGS="--rtlib=compiler-rt -static"  # --rtlib=compiler-rt
		# CXXFLAGS="--rtlib=compiler-rt -static"  # --rtlib=compiler-rt
		# LDFLAGS="-fuse-ld=lld -static"
		LLVM_CONFIG=/build/host/bin/llvm-config

		cmake
		-G Ninja
		../llvm-project/runtimes
		-DCMAKE_BUILD_TYPE=Release
		-DCMAKE_INSTALL_PREFIX=/build/target

		-DLIBCXX_HAS_MUSL_LIBC=1

		-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY		

		-DCMAKE_SYSROOT=/build/target
		-DDEFAULT_SYSROOT=/build/target

		# -DCMAKE_C_COMPILER=/build/host/bin/clang
		# -DCMAKE_CXX_COMPILER=/build/host/bin/clang++
		-DLLVM_DEFAULT_TARGET_TRIPLE="$BTDU_ARCH"-unknown-linux-musl
		# -DLLVM_TARGET_ARCH="$target_llvm_arch"
		-DLLVM_TARGETS_TO_BUILD="$BTDU_LLVM_ARCH"

		-DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=ON
		-DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON
		-DLIBCXX_STATICALLY_LINK_ABI_IN_SHARED_LIBRARY=ON
		# -DLIBCXXABI_USE_LLVM_UNWINDER=ON
		# -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_SHARED_LIBRARY=ON
		-DLIBCXX_ENABLE_STATIC=ON
		-DLIBCXX_ENABLE_SHARED=OFF
		-DLIBCXX_INSTALL_STATIC_LIBRARY=ON

		-DLIBCXXABI_ENABLE_STATIC=ON
		-DLIBCXXABI_ENABLE_SHARED=OFF

		-DLIBUNWIND_ENABLE_SHARED=OFF
		
		-DLLVM_ENABLE_RUNTIMES='libcxx;libcxxabi;libunwind'
	) ; "${args[@]}"
	ninja install
)
rm -rf libcxx.build
