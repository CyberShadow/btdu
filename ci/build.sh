#!/bin/bash
set -eEuo pipefail
shopt -s lastpipe

musl_version=1.2.3
ncurses_version=6.4

arch=$1
triple="$arch"-linux-musl

target_dir=/tmp/btdu-build-$arch

tasks=$(($(nproc) + 1))
# cc=("${target_dir}/bin/musl-gcc" -static)
cc=(clang)
cflags=( -Os -ffunction-sections -fdata-sections  -flto=full -static --target="$triple" -DHAVE_SETENV -DHAVE_PUTENV)
# if "${REALGCC:-gcc}" -v 2>&1 | grep -q -- --enable-default-pie; then
#   cflags+=( -no-pie )
# fi
ldflags=("-Wl,--gc-sections" -print-targets)

_musl() {
	if [[ ! -e musl-${musl_version}.tar.gz ]]; then
		curl -LO https://www.musl-libc.org/releases/musl-${musl_version}.tar.gz
	fi
	tar zxf musl-${musl_version}.tar.gz --skip-old-files
	(
		cd musl-${musl_version}
		CC="${cc[*]}" CFLAGS="${cflags[*]}" LDFLAGS="${ldflags[*]}" \
		  ./configure \
		  --prefix="${target_dir}" \
		  --disable-shared
		make -j $tasks
		make install
		make clean
	)
}

_ncurses() {
	if [[ ! -e ncurses-${ncurses_version}.tar.gz ]]; then
		curl -LO https://ftp.gnu.org/pub/gnu/ncurses/ncurses-${ncurses_version}.tar.gz
	fi
	tar zxvf ncurses-${ncurses_version}.tar.gz --skip-old-files
	pushd .
	cd ncurses-${ncurses_version}

	_cflags=("${_CFLAGS[@]}" -flto)
	CC="${cc[*]}" CFLAGS="${cflags[*]}" LDFLAGS="${ldflags[*]}" ./configure \
	    --prefix="$target_dir" \
	    --host="$triple" \
	    --target="$triple" \
		--with-default-terminfo-dir=/usr/share/terminfo \
		--with-terminfo-dirs="/etc/terminfo:/lib/terminfo:/usr/share/terminfo" \
		--enable-pc-files \
		--with-pkg-config-libdir="${target_dir}/lib/pkgconfig" \
		--without-ada \
		--without-debug \
		--with-termlib \
		--without-cxx \
		--without-progs \
		--without-manpages \
		--disable-db-install \
		--without-tests
	make -j $tasks
	make install
	make clean
	popd
}

# rm -rf "${target_dir}/out"

# _musl
# _ncurses

