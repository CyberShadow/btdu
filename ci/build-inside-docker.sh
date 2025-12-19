#!/bin/bash
set -eEuo pipefail

cd "$(dirname "$0")"/..

PATH=/tmp/ldc2-host/bin:$PATH

host_arch=$(uname -m)
target_arch=$BTDU_ARCH

target_api=gnu
case "$target_arch" in
	arm)
		target_api=gnueabihf
		;;
	*)
esac

if [[ "$target_arch" == "$host_arch" ]]
then
	gnu_prefix=
else
	gnu_prefix="$target_arch"-linux-"$target_api"-
fi

cat >> /tmp/ldc2-host/etc/ldc2.conf <<EOF
"$target_arch-.*-linux-$target_api":
{
switches = [
	"-defaultlib=phobos2-ldc,druntime-ldc",
	"-gcc=$target_arch-linux-$target_api-gcc",
];
lib-dirs = [
	"/tmp/ldc-build-runtime.tmp/lib",
];
rpath = "/tmp/ldc-build-runtime.tmp/lib";
};
EOF

static=true

if $static
then
	fn=btdu-static-"$target_arch"
else
	fn=btdu-glibc-"$target_arch"
fi

# shellcheck disable=SC2054
args=(
	ldc2
	-v
	-mtriple "$target_arch"-linux-"$target_api"
	--linker=lld
	-i
	-i=-deimos  # https://issues.dlang.org/show_bug.cgi?id=23597
	-of"$fn"
	-L-Lrelease
	-L-l:libtermcap.a
	-L-l:libncursesw.a
	-L-l:libtinfo.a
	-L-l:libz.a
	-flto=full
	-O
	--release
	source/btdu/main
)

if $static ; then
	args+=(-static)
fi

while read -r path
do
	args+=(-I"$path")
done < <(dub describe | jq -r '.targets[] | select(.rootPackage=="btdu") | .buildSettings.importPaths[]')

"${args[@]}"

"${gnu_prefix}"strip "$fn"
