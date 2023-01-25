#!/bin/bash
set -eEuo pipefail




# find / -mount -name '*druntime*'
# exit 123


# cd /build/src

# cat > test.d <<EOF
# void main() { }
# EOF

# args=(
# 	/build/host/bin/ldc2
# 	--function-sections
# 	--data-sections
# 	--static
# 	--flto=full
# 	--defaultlib='phobos2-ldc-lto,druntime-ldc-lto'
# 	-v
# 	--Xcc=-v
# 	-L=--verbose
# 	--Xcc=--rtlib=compiler-rt
# 	--Xcc=--sysroot=/build/target
# 	--Xcc=-resource-dir=/build/target
# 	--gcc=/build/host/bin/clang
# 	--linker=/build/host/bin/ld.lld
# 	test.d
# ) ; "${args[@]}"



















# exit 0


cd "$(dirname "$0")"/..

# PATH=/tmp/ldc2-host/bin:$PATH

# host_arch=$(uname -m)
target_arch=$BTDU_ARCH

# if [[ "$target_arch" == "$host_arch" ]]
# then
# 	gnu_prefix=
# else
# 	gnu_prefix="$target_arch"-linux-musl-
# fi


cat >> /build/host/etc/ldc2.conf <<EOF
"$target_arch-.*-linux-musl":
{
switches = [
	"-defaultlib=phobos2-ldc,druntime-ldc",
	"-gcc=/build/host/bin/clang",
];
lib-dirs = [
	"/build/target/druntime/lib",
];
rpath = "/build/target/druntime/lib";
};
EOF

# case "$target_arch" in
# 	aarch64)
# 		# See https://forum.dlang.org/post/ulkljredphpgipqfmlvf@forum.dlang.org
# 		static=false
# 		;;
# 	*)
# 		static=true
# esac

# if $static
# then
# 	fn=btdu-static-"$target_arch"
# else
# 	fn=btdu-glibc-"$target_arch"
# fi




# cd /build/src

cat > test.c <<EOF
#include <sys/types.h>
#include <signal.h>
#include <stdio.h>
#include <time.h>

int main()
{
	printf("void*: %d\n", (int)sizeof(void*));
	printf("long: %d\n", (int)sizeof(long));
	printf("time_t: %d\n", (int)sizeof(time_t));
	printf("timespec: %d\n", (int)sizeof(struct timespec));
	struct timespec ts;
	printf("tv_sec: %d\n", (int)sizeof(ts.tv_sec));
	printf("tv_nsec: %d\n", (int)sizeof(ts.tv_nsec));

	int ret = clock_getres(CLOCK_MONOTONIC, &ts);
	printf("ret=%d\n", ret);

	printf("%ld:%ld\n", (long)ts.tv_sec, (long)ts.tv_nsec);
	printf("tv_sec = %lld\n", (long long)ts.tv_sec);
	printf("tv_nsec = %lld\n", (long long)ts.tv_nsec);

	return 0;
}
EOF

args=(
	/build/host/bin/clang
	-static
	-Wall -Wextra -Werror
	--rtlib=compiler-rt
	--sysroot=/build/target
	-resource-dir=/build/target
	# -fuse-ld=/build/host/bin/ld.lld
	--ld-path=/build/host/bin/ld.lld
	test.c
) ; "${args[@]}"
./a.out
# exit 123







cat > test.d <<EOF
/*
import core.sys.posix.sys.types;
import core.sys.posix.signal;

pragma(msg, time_t.sizeof);
pragma(msg, timespec.sizeof);

void main()
// extern (C) void main()
{
// 	import std.stdio;
// 	writeln("Hello, world!");
// 	try
// 	{
// 		throw new Exception("Test exception!");
// 	}
// 	catch (Exception e)
// 	{
// 		writeln("Caught!");
// 		writeln(e);
// 	}
// 	writeln("All OK!");

	import core.sys.posix.time;
	import core.stdc.stdio;
	import core.stdc.config;
	timespec ts;
	int ret = clock_getres(CLOCK_MONOTONIC, &ts);
	printf("ret=%d\n", ret);

	printf("%d:%d\n", cast(int)ts.tv_sec, cast(int)ts.tv_nsec);
	printf("%ld:%ld\n", cast(c_long)ts.tv_sec, cast(c_long)ts.tv_nsec);
}
*/
void main(){}
EOF

args=(
	/build/host/bin/ldc2
	--function-sections
	--data-sections
	--static
	--flto=full
	# --defaultlib='phobos2-ldc-lto,druntime-ldc-lto'
	-v
	--Xcc=-v
	-L=--verbose
	--Xcc=--rtlib=compiler-rt
	--Xcc=--sysroot=/build/target
	--Xcc=-resource-dir=/build/target
	--gcc=/build/host/bin/clang
	--linker=/build/host/bin/ld.lld
	# --defaultlib=
	-of test_"${target_arch}"
	test.d
) ; "${args[@]}"








# # shellcheck disable=SC2054
# args=(
# 	ldc2
# 	-v
# 	-mtriple "$target_arch"-linux-musl
# 	-i
# 	-of"$fn"
# 	-L-Lrelease
# 	-L-l:libtermcap.a
# 	-L-l:libncursesw.a
# 	-L-l:libtinfo.a
# 	-L-l:libz.a
# 	-flto=full
# 	-O
# 	--release
# 	source/btdu/main
# )

# if $static ; then
# 	args+=(-static)
# fi

# while read -r path
# do
# 	args+=(-I"$path")
# done < <(dub describe | jq -r '.targets[] | select(.rootPackage=="btdu") | .buildSettings.importPaths[]')

# "${args[@]}"

# "${gnu_prefix}"strip "$fn"
