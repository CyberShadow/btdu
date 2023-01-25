#!/bin/bash
set -eEuo pipefail

ldc_version=1.30.0

mkdir /build/src/ldc
cd /build/src/ldc

curl -fsSOL https://github.com/ldc-developers/ldc/releases/download/v${ldc_version}/ldc-${ldc_version}-src.tar.gz
tar xf ldc-${ldc_version}-src.tar.gz

mv ldc-${ldc_version}-src ldc
