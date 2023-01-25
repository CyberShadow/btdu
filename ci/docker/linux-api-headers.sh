#!/bin/bash
set -eEuo pipefail

cd /build/src

linux_api_headers_version=5.18.15
curl -LOfsS https://www.kernel.org/pub/linux/kernel/v${linux_api_headers_version:0:1}.x/linux-${linux_api_headers_version}.tar.xz
tar xJf linux-${linux_api_headers_version}.tar.xz
(
	cd linux-${linux_api_headers_version}
	make -j"$(nproc)" INSTALL_HDR_PATH=/build/target headers_install
)
