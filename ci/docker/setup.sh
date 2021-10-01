#!/bin/bash
set -eEuo pipefail

target_arch=$BTDU_ARCH

# Translate LDC target architecture to Debian architecture
case "$target_arch" in
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
	libxml2   # Needed by LDC
	curl      # To download LDC; Needed by Dub
	cmake     # To rebuild the LDC runtime
)

if [[ "$target_arch" == "$host_arch" ]]
then
	packages+=(
		gcc
	)
else
	packages+=(
		gcc-"${target_arch/_/-}"-linux-gnu
	)
fi
packages+=(
	binutils-"${target_arch/_/-}"-linux-gnu
	libncurses-dev:"$target_debian_arch"
	libz-dev:"$target_debian_arch"
	libtinfo-dev:"$target_debian_arch"
)

apt-get install -y "${packages[@]}"

mkdir /btdu
