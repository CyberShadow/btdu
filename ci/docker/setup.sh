#!/bin/bash
set -eEuo pipefail

target_arch=$BTDU_ARCH

# Translate LDC target architecture to Debian architecture
target_api=gnu
case "$target_arch" in
	x86_64)
		target_debian_arch=amd64
		;;
	arm)
		target_debian_arch=armhf
		target_api=gnueabihf
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

# Add LLVM apt repository for lld-20 (matches LDC's LLVM version)
apt-get install -y wget gnupg
wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc
echo "deb http://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-20 main" > /etc/apt/sources.list.d/llvm.list
apt-get update

packages=(
    jq        # To parse `dub --describe` output
	xz-utils  # To unpack LDC archives
	libxml2   # Needed by LDC
	curl      # To download LDC; Needed by Dub
	cmake     # To rebuild the LDC runtime
	lld-20    # LLVM linker matching LDC's LLVM version
)

if [[ "$target_arch" == "$host_arch" ]]
then
	packages+=(
		gcc
		g++
	)
else
	packages+=(
		gcc-"${target_arch/_/-}"-linux-"$target_api"
		g++-"${target_arch/_/-}"-linux-"$target_api"
	)
fi
packages+=(
	binutils-"${target_arch/_/-}"-linux-"$target_api"
	libncurses-dev:"$target_debian_arch"
	libz-dev:"$target_debian_arch"
	libtinfo-dev:"$target_debian_arch"
)

apt-get install -y "${packages[@]}"

# Create symlinks so -fuse-ld=lld finds lld-20
ln -sf /usr/bin/ld.lld-20 /usr/bin/ld.lld
# Also create symlink in cross-compiler directory if it exists
if [[ -d /usr/"${target_arch/_/-}"-linux-"$target_api"/bin ]]; then
	ln -sf /usr/bin/ld.lld-20 /usr/"${target_arch/_/-}"-linux-"$target_api"/bin/ld.lld
fi

mkdir /btdu
