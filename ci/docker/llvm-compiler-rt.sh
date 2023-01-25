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


# find /build/target/include -name atomic
# find /build/target/include -name cstring 
# exit 1

# find / -name crtbeginS.o
# exit 1






mkdir compiler-rt.build
(
	cd compiler-rt.build
	# args=(
	# 	env
	# 	CC=/build/host/bin/clang
	# 	CXX=/build/host/bin/clang++
	# 	# CFLAGS="-static"  # --rtlib=compiler-rt
	# 	CFLAGS="-nostdlib"
	# 	CXXFLAGS="-nostdlib"
	# 	LDFLAGS="-fuse-ld=lld"
	# 	# LLVM_CONFIG=/build/host/bin/llvm-config

	# 	cmake
	# 	-G Ninja
	# 	../llvm-project/compiler-rt

	# 	# -DCMAKE_C_COMPILER_WORKS=1
	# 	# -DCMAKE_CXX_COMPILER_WORKS=1

	# 	-DCMAKE_BUILD_TYPE=Release
	# 	-DCMAKE_INSTALL_PREFIX=/build/target2
	# 	-DLLVM_CONFIG_PATH=/build/host/bin/llvm-config

	# 	-DCMAKE_SYSROOT=/build/target
	# 	# -DDEFAULT_SYSROOT=/build/target

	# 	# -DCMAKE_C_COMPILER=/build/host/bin/clang
	# 	# -DCMAKE_CXX_COMPILER=/build/host/bin/clang++
	# 	-DLLVM_DEFAULT_TARGET_TRIPLE="$target_arch"-pc-linux-musl
	# 	# -DLLVM_TARGET_ARCH="$target_llvm_arch"
	# 	-DLLVM_TARGETS_TO_BUILD="$target_llvm_arch"
	# ) ; "${args[@]}"

	# cflags="--rtlib=compiler-rt"
	cflags=""
	args=(
		cmake
		-G Ninja
	 	../llvm-project/compiler-rt

		# -DCMAKE_C_COMPILER_WORKS=1
		# -DCMAKE_CXX_COMPILER_WORKS=1

		-DCMAKE_INSTALL_PREFIX=/build/target

		-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY		

		-DCMAKE_AR=/build/host/bin/llvm-ar
		-DCMAKE_ASM_COMPILER_TARGET="$target_arch"-pc-linux-musl
		-DCMAKE_C_COMPILER=/build/host/bin/clang
		-DCMAKE_C_COMPILER_TARGET="$target_arch"-pc-linux-musl
		-DCMAKE_ASM_FLAGS="$cflags"
		-DCMAKE_C_FLAGS="$cflags"
		-DCMAKE_CXX_FLAGS="$cflags -nostdinc++ -isystem /build/target/include/c++/v1"
		-DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld"
		-DCMAKE_NM=/build/host/bin/llvm-nm
		-DCMAKE_RANLIB=/build/host/bin/llvm-ranlib
		-DCOMPILER_RT_BUILD_BUILTINS=ON
		-DCOMPILER_RT_BUILD_LIBFUZZER=OFF
		-DCOMPILER_RT_BUILD_MEMPROF=OFF
		-DCOMPILER_RT_BUILD_PROFILE=OFF
		-DCOMPILER_RT_BUILD_SANITIZERS=OFF
		-DCOMPILER_RT_BUILD_XRAY=OFF
		-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
		-DLLVM_CONFIG_PATH=/build/host/bin/llvm-config		
		-DCMAKE_SYSROOT=/build/target
		# -DLLVM_HOST_TRIPLE="$target_arch"-pc-linux-musl
	) ; "${args[@]}"
	ninja
	ninja install
)
rm -rf compiler-rt.build

# find /build/target2
# exit 1




rm -rf /build/src
