#!/bin/bash
set -eEuo pipefail

target_arch=$BTDU_ARCH

# Translate LDC target architecture to Debian architecture
case "$target_arch" in
	i686)
		target_debian_arch=i386
		;;
	x86_64)
		target_debian_arch=amd64
		;;
	aarch64)
		target_debian_arch=arm64
		;;
	*)
esac

host_arch=$(uname -m)

if [[ "$target_arch" != "$host_arch" ]]
then
   dpkg --add-architecture "$target_debian_arch"
fi

apt-get update

packages=(
    jq        # To parse `dub --describe` output
	xz-utils  # To unpack LDC archives
	curl      # To download LDC; Needed by Dub
	cmake     # To rebuild the LDC runtime
)

if [[ "$target_arch" == "$host_arch" ]]
then
	packages+=(
	)
else
	packages+=(
		gcc-"${target_arch/_/-}"-linux-gnu
	)
fi
packages+=(
)

apt-get install -y "${packages[@]}"

