#!/bin/bash
set -eEuo pipefail

llvm_version=15.0.7

mkdir /build/src/llvm
cd /build/src/llvm

# curl -fsSOL https://github.com/ldc-developers/llvm-project/releases/download/ldc-v${llvm_version}/llvm-${llvm_version}.src.tar.xz
# tar xf llvm-${llvm_version}.src.tar.xz

# mv llvm-${llvm_version}.src llvm.src

git clone --depth=1 -b ldc-v"${llvm_version}" --recursive https://github.com/ldc-developers/llvm-project
