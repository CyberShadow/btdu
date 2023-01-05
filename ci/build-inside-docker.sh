#!/bin/bash
cd "$(dirname "$0")"/..

PATH=/tmp/ldc2-host/bin:$PATH

target_arch=$BTDU_ARCH

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

if $static
then
	fn=btdu-static-"$target_arch"
fi

args=(
	ldc2
	-mtriple "$target_arch"-linux-gnu
	-i
	-flto=full
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

