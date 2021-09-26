#!/bin/bash
set -eEuo pipefail

cd "$(dirname "$0")"/..

PATH=/tmp/ldc2-host/bin:$PATH

host_arch=$(uname -m)
target_arch=$BTDU_ARCH

if [[ "$target_arch" == "$host_arch" ]]
then
	gnu_prefix=
else
	gnu_prefix="$target_arch"-linux-gnu-
	cat >> /tmp/ldc2-host/etc/ldc2.conf <<EOF
"$target_arch-.*-linux-gnu":
{
switches = [
	"-defaultlib=phobos2-ldc,druntime-ldc",
	"-gcc=aarch64-linux-gnu-gcc",
];
lib-dirs = [
	"/tmp/ldc2-target/lib",
];
rpath = "/tmp/ldc2-target/lib";
};
EOF
fi

# shellcheck disable=SC2054
args=(
	ldc2
	-v
	-mtriple "$target_arch"-linux-gnu
	-i
	-ofbtdu-static-"$target_arch"
	-L-Lrelease
	-L-l:libtermcap.a
	-L-l:libncursesw.a
	-L-l:libtinfo.a
	-L-l:libz.a
	-flto=full
	-static
	-O
	--release
	source/btdu/main
)
while read -r path
do
	args+=(-I"$path")
done < <(dub describe | jq -r '.targets[] | select(.rootPackage=="btdu") | .buildSettings.importPaths[]')

"${args[@]}"

"${gnu_prefix}"strip btdu-static-"$target_arch"
