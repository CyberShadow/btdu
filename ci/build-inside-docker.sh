#!/bin/bash
set -eEuo pipefail

cd "$(dirname "$0")"/..

ldc_ver=1.27.1
host_arch=$(uname -m)

PATH=/tmp/ldc2-"$ldc_ver"-linux-"$host_arch"/bin:$PATH

for arch in x86_64 aarch64
do
	(
		cd /tmp
		curl --location --fail --remote-name https://github.com/ldc-developers/ldc/releases/download/v$ldc_ver/ldc2-$ldc_ver-linux-"$arch".tar.xz
		tar axf ldc2-$ldc_ver-linux-"$arch".tar.xz
	)

	if [[ "$arch" == "$host_arch" ]]
	then
		gnu_prefix=
	else
		gnu_prefix="$arch"-linux-gnu-
		cat >> /tmp/ldc2-"$ldc_ver"-linux-"$host_arch"/etc/ldc2.conf <<EOF
"$arch-.*-linux-gnu":
{
    switches = [
        "-defaultlib=phobos2-ldc,druntime-ldc",
        "-gcc=aarch64-linux-gnu-gcc",
    ];
    lib-dirs = [
        "/tmp/ldc2-$ldc_ver-linux-$arch/lib",
    ];
    rpath = "/tmp/ldc2-$ldc_ver-linux-$arch/lib";
};
EOF
	fi

	# shellcheck disable=SC2054
	args=(
		ldc2
		-v
		-mtriple "$arch"-linux-gnu
		-i
		-ofbtdu-static-"$arch"
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

	"${gnu_prefix}"strip btdu-static-"$arch"
done
