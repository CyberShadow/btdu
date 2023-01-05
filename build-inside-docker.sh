#!/bin/bash
set -eEuo pipefail

target_arch=i686
target_debian_arch=i386
host_arch=$(uname -m)

dpkg --add-architecture "$target_debian_arch"
apt-get update

packages=(
	xz-utils  # To unpack LDC archives
	curl      # To download LDC
	cmake     # To rebuild the LDC runtime
	gcc-"${target_arch/_/-}"-linux-gnu
)

apt-get install -y "${packages[@]}"

ldc_ver=1.30.0

(
	cd /tmp

	arch=$host_arch
	name=ldc2-$ldc_ver-linux-"$arch"
	filename="$name".tar.xz
	test -f "$filename" || curl --location --fail --remote-name https://github.com/ldc-developers/ldc/releases/download/v$ldc_ver/"$filename"
	test -d "$name" || tar axf "$filename"

	ln -s ldc2-$ldc_ver-linux-"$host_arch" ldc2-host

	args=(
		env
		CC="$target_arch"-linux-gnu-gcc
		ldc2-host/bin/ldc-build-runtime
		--dFlags="-mtriple=$target_arch-linux-gnu"
		--dFlags="-flto=full"
		BUILD_SHARED_LIBS=OFF
	) ; "${args[@]}"
)

PATH=/tmp/ldc2-host/bin:$PATH

cat >> /tmp/ldc2-host/etc/ldc2.conf <<EOF
"$target_arch-.*-linux-gnu":
{
switches = [
	"-defaultlib=phobos2-ldc,druntime-ldc",
	"-gcc=$target_arch-linux-gnu-gcc",
];
lib-dirs = [
	"/tmp/ldc-build-runtime.tmp/lib",
];
};
EOF

cd /test

args=(
	ldc2
	-mtriple "$target_arch"-linux-gnu
	-flto=full
	-static
	main.d
)
"${args[@]}"
