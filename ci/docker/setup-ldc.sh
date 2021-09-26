#!/bin/bash
set -eEuo pipefail

ldc_ver=1.27.1

host_arch=$(uname -m)
target_arch=$BTDU_ARCH

cd /tmp

for arch in "$host_arch" "$target_arch"
do
	name=ldc2-$ldc_ver-linux-"$arch"
	filename="$name".tar.xz
	test -f "$filename" || curl --location --fail --remote-name https://github.com/ldc-developers/ldc/releases/download/v$ldc_ver/"$filename"
	test -d "$name" || tar axf "$filename"
done

ln -s ldc2-$ldc_ver-linux-"$host_arch" ldc2-host
ln -s ldc2-$ldc_ver-linux-"$target_arch" ldc2-target
