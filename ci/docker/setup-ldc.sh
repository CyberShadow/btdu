#!/bin/bash
set -eEuo pipefail

ldc_ver=1.27.1

host_arch=$(uname -m)

cd /tmp

arch=$host_arch
name=ldc2-$ldc_ver-linux-"$arch"
filename="$name".tar.xz
test -f "$filename" || curl --location --fail --remote-name https://github.com/ldc-developers/ldc/releases/download/v$ldc_ver/"$filename"
test -d "$name" || tar axf "$filename"

ln -s ldc2-$ldc_ver-linux-"$host_arch" ldc2-host
