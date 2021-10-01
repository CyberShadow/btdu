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
fi

cat >> /tmp/ldc2-host/etc/ldc2.conf <<EOF
"$target_arch-.*-linux-gnu":
{
switches = [
	"-defaultlib=phobos2-ldc,druntime-ldc",
	"-gcc=$target_arch-linux-gnu-gcc",
];
lib-dirs = [
	"/tmp/ldc2-host/bin/ldc-build-runtime.tmp/lib",
];
rpath = "/tmp/ldc2-host/bin/ldc-build-runtime.tmp/lib";
};
EOF

case "$target_arch" in
	aarch64)
		# See https://forum.dlang.org/post/ulkljredphpgipqfmlvf@forum.dlang.org
		static=false
		;;
	*)
		static=true
esac

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
	-mtriple "$target_arch"-linux-gnu
	-i
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
