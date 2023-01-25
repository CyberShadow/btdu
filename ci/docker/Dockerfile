# FROM debian:buster-20210902 AS base
FROM docker.io/debian:sid-20221219@sha256:f57caa7a1b85743fe9a14c90bf281fa5986b137101f7087cce10e651a16efd61 AS base

RUN apt-get update

# TODO collapse into one command
RUN mkdir /build
RUN mkdir /build/src
RUN mkdir /build/host
RUN mkdir /build/target


FROM base AS llvm-build

RUN apt-get install -y git-core

COPY llvm-dl.sh /build/llvm-dl.sh
RUN /build/llvm-dl.sh

RUN apt-get install -y binutils-dev cmake g++ ninja-build python3

ARG BTDU_ARCH

COPY llvm-build.sh /build/llvm-build.sh
RUN /build/llvm-build.sh



RUN apt-get install -y curl make rsync xz-utils

COPY linux-api-headers.sh /build/linux-api-headers.sh
RUN /build/linux-api-headers.sh



RUN apt-get install -y curl make binutils

COPY musl.sh /build/musl.sh
RUN /build/musl.sh



RUN apt-get install -y python3-distutils

COPY llvm-runtimes.sh /build/llvm-runtimes.sh
RUN /build/llvm-runtimes.sh


COPY llvm-compiler-rt.sh /build/llvm-compiler-rt.sh
RUN /build/llvm-compiler-rt.sh



# FROM base AS llvm

# COPY --from=llvm-build /build/host /build/host
# COPY --from=llvm-build /build/target /build/target

# RUN apt-get install -y strace

# RUN apt-get install -y patch
# COPY llvm.patch /build/src/llvm.patch
# RUN cd /build/src/llvm/llvm-project && patch -p1 < /build/src/llvm.patch
# RUN cd /build/src/llvm/llvm.build && ninja install

COPY ncurses.sh /build/ncurses.sh
RUN /build/ncurses.sh


FROM base AS ldc

RUN apt-get install -y curl
COPY ldc-dl.sh /build/ldc-dl.sh
RUN /build/ldc-dl.sh


RUN apt-get install -y xz-utils
COPY dmd.sh /build/dmd.sh
RUN /build/dmd.sh

RUN apt-get install -y patch
COPY ldc-druntime.patch /build/src/ldc-druntime.patch
RUN cd /build/src/ldc/ldc/runtime/druntime && patch -p1 < /build/src/ldc-druntime.patch


# RUN apt-get install -y cmake clang lld ldc ninja-build
RUN apt-get install -y cmake g++ ninja-build

COPY --from=llvm-build /build/host /build/host
COPY --from=llvm-build /build/target /build/target

ARG BTDU_ARCH

COPY ldc-build.sh /build/ldc-build.sh
RUN /build/ldc-build.sh


COPY ldc-runtime.sh /build/ldc-runtime.sh
RUN /build/ldc-runtime.sh


# RUN find / -mount -name '*runtime*a' && exit 1

# FROM llvm AS musl

# RUN apt-get install -y curl make binutils

# ARG BTDU_ARCH

# COPY musl.sh /build/musl.sh
# RUN /build/musl.sh


# FROM 
# COPY setup.sh /root/setup.sh
# RUN /root/setup.sh

# COPY setup-ldc.sh /root/setup-ldc.sh
# RUN /root/setup-ldc.sh

# COPY setup-musl.sh /root/setup-musl.sh
# RUN /root/setup-musl.sh

# COPY setup-ncurses.sh /root/setup-ncurses.sh
# RUN /root/setup-ncurses.sh

# # # For some reason Debian does not package this script.
# # COPY musl-clang /usr/bin

# RUN apt-get install -y lld

# COPY setup-ldc-runtime.sh /root/setup-ldc-runtime.sh
# RUN /root/setup-ldc-runtime.sh

# # COPY setup-llvm-compiler-rt.sh /root/setup-llvm-compiler-rt.sh
# # RUN /root/setup-llvm-compiler-rt.sh

# RUN apt-get install -y libunwind-14-dev:amd64

