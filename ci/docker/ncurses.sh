#!/bin/bash
set -eEuo pipefail
shopt -s lastpipe


# grep -R libc_start_main /build/target/lib
# exit 123


# # mkdir /build/src
# cd /build/src
# cat > test.c <<EOF
# int main() { return 0; }
# EOF


# args=(
# 	# strace
# 	/build/host/bin/clang
# 	-L /build/target/lib/linux
# 	-fuse-ld=/build/host/bin/ld.lld
# 	--rtlib=compiler-rt
# 	-static
# 	--sysroot=/build/target
# 	-resource-dir=/build/target
# 	-flto=full
# 	test.c

# 	--verbose
# 	-Wl,--verbose
# ) ; "${args[@]}"

# echo COMPILED OK
# exit 123



























target_dir=/build/target

ncurses_version=6.4

arch=$BTDU_ARCH
triple="$arch"-pc-linux-musl

cflags=(
	-Os
	-ffunction-sections
	-fdata-sections
	# -flto=full
	-fuse-ld=/build/host/bin/ld.lld
	--rtlib=compiler-rt
	-static
	--sysroot=/build/target
	-resource-dir=/build/target
	# --target="$triple"
	# -DHAVE_SETENV
	# -DHAVE_PUTENV
)
ldflags=(
	# "-Wl,--gc-sections"
	--verbose
	-L--verbose
	-Wl,--verbose
)

# find / -mount -name crt1.o
# find / -mount -name crti.o
# find / -mount -name crtbeginT.o
# find / -mount -name crtend.o
# find / -mount -name crtn.o
# find / -mount -name libclang_rt.builtins-aarch64.a
# exit 1

curl -LO https://ftp.gnu.org/pub/gnu/ncurses/ncurses-${ncurses_version}.tar.gz
tar zxvf ncurses-${ncurses_version}.tar.gz
cd ncurses-${ncurses_version}

_cflags=("${_CFLAGS[@]}" -flto)
args=(
	env
	CC=/build/host/bin/clang
	CFLAGS="${cflags[*]}"
	LDFLAGS="${ldflags[*]}"
	./configure
	--prefix=/build/target
	--host="$triple"
	--target="$triple"
	--with-default-terminfo-dir=/usr/share/terminfo
	--with-terminfo-dirs="/etc/terminfo:/lib/terminfo:/usr/share/terminfo"
	--enable-pc-files
	--with-pkg-config-libdir="${target_dir}/lib/pkgconfig"
	--without-ada
	--without-debug
	--with-termlib
	--without-cxx
	--without-progs
	--without-manpages
	--disable-db-install
	--enable-widec
	--without-tests
) ; "${args[@]}" || cat config.log
make -j "$(nproc)" install
make install
make clean
