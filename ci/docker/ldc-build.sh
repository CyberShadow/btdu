#!/bin/bash
set -eEuo pipefail

cd /build/src/ldc

mkdir ldc.build
(
	cd ldc.build
	args=(
		cmake
		-G Ninja
		../ldc
		-DCMAKE_BUILD_TYPE=Release
		-DCMAKE_INSTALL_PREFIX=/build/host
		-DLLVM_ROOT_DIR=/build/host
		-DLLVM_CONFIG=/build/host/bin/llvm-config
		-DD_COMPILER=/build/src/dmd2/linux/bin64/dmd
		-DBUILD_LTO_LIBS=ON
		-DBUILD_SHARED_LIBS=OFF
	) ; "${args[@]}"
	ninja install
)
rm -rf ldc.build
