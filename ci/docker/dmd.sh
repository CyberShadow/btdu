#!/bin/bash
set -eEuo pipefail

dmd_version=2.100.2

cd /build/src

curl -fsSLO https://downloads.dlang.org/releases/2.x/${dmd_version}/dmd.${dmd_version}.linux.tar.xz
tar Jxf dmd.${dmd_version}.linux.tar.xz
