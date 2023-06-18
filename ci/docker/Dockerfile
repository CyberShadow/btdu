# FROM debian:buster-20210902 AS base
FROM docker.io/debian:sid@sha256:140e346276a32ebc31a02735366e0ba270bc81161e97258ee36d14aafc3c988b AS base

RUN apt-get update

RUN mkdir /build /build/src /build/host /build/target


FROM base AS llvm

RUN apt-get install -y git-core binutils-dev cmake g++ ninja-build python3

COPY llvm-dl.sh /build/llvm-dl.sh
RUN /build/llvm-dl.sh

COPY llvm-build.sh /build/llvm-build.sh
ARG BTDU_ARCH
ARG BTDU_LLVM_ARCH
RUN /build/llvm-build.sh


FROM base AS linux-api-headers

RUN apt-get install -y curl make rsync xz-utils gcc

COPY linux-api-headers.sh /build/linux-api-headers.sh
RUN /build/linux-api-headers.sh


FROM base AS musl

RUN apt-get install -y curl make binutils

COPY --from=llvm /build/host /build/host
COPY --from=llvm /build/target /build/target

COPY musl.sh /build/musl.sh
ARG BTDU_ARCH
RUN /build/musl.sh


FROM base AS llvm-runtimes

RUN apt-get install -y python3-distutils cmake ninja-build

COPY --from=llvm /build/src /build/src
COPY --from=llvm /build/host /build/host
COPY --from=musl /build/target /build/target
COPY --from=linux-api-headers /build/target /build/target

COPY llvm-runtimes.sh /build/llvm-runtimes.sh
ARG BTDU_ARCH
ARG BTDU_LLVM_ARCH
RUN /build/llvm-runtimes.sh


FROM base AS llvm-compiler-rt

RUN apt-get install -y cmake ninja-build python3

COPY --from=llvm /build/src /build/src
COPY --from=llvm /build/host /build/host
COPY --from=llvm-runtimes /build/target /build/target
COPY --from=musl /build/target /build/target

COPY llvm-compiler-rt.sh /build/llvm-compiler-rt.sh
ARG BTDU_ARCH
RUN /build/llvm-compiler-rt.sh


# FROM base AS llvm

# COPY --from=llvm-build /build/host /build/host
# COPY --from=llvm-build /build/target /build/target

# RUN apt-get install -y strace

# RUN apt-get install -y patch
# COPY llvm.patch /build/src/llvm.patch
# RUN cd /build/src/llvm/llvm-project && patch -p1 < /build/src/llvm.patch
# RUN cd /build/src/llvm/llvm.build && ninja install

FROM base AS ncurses

# gcc is needed to build some stuff on the host, I guess to build the terminfo database
RUN apt-get install -y curl make gcc

COPY --from=llvm /build/host /build/host
COPY --from=llvm-compiler-rt /build/target /build/target

COPY ncurses.sh /build/ncurses.sh
ARG BTDU_ARCH
RUN /build/ncurses.sh


FROM base AS dmd

RUN apt-get install -y curl xz-utils
COPY dmd.sh /build/dmd.sh
RUN /build/dmd.sh


FROM base AS ldc

RUN apt-get install -y curl
COPY ldc-dl.sh /build/ldc-dl.sh
RUN /build/ldc-dl.sh

RUN apt-get install -y patch
COPY ldc-druntime.patch /build/src/ldc-druntime.patch
RUN cd /build/src/ldc/ldc && patch -p1 < /build/src/ldc-druntime.patch

RUN apt-get install -y cmake g++ ninja-build

COPY --from=llvm /build/host /build/host
COPY --from=llvm /build/target /build/target
COPY --from=dmd /build/src/dmd2 /build/src/dmd2

COPY ldc-build.sh /build/ldc-build.sh
ARG BTDU_ARCH
RUN /build/ldc-build.sh


FROM base AS ldc-runtime

RUN apt-get install -y cmake ninja-build

COPY --from=llvm-runtimes /build/target /build/target
COPY --from=llvm-compiler-rt /build/target /build/target
COPY --from=ldc /build/host /build/host
COPY --from=ldc /build/src/ldc /build/src/ldc
COPY --from=musl /build/target /build/target

COPY ldc-runtime.sh /build/ldc-runtime.sh
ARG BTDU_ARCH
RUN /build/ldc-runtime.sh


FROM base

# libcurl is needed by Dub to download packages
# jq is used by build-inside-docker.sh to parse Dub output
RUN apt-get install -y libcurl4 jq

# For Dub:
COPY --from=dmd /build/src/dmd2 /build/src/dmd2
COPY --from=ldc /build/host /build/host
COPY --from=ldc-runtime /build/target /build/target
COPY --from=musl /build/target /build/target
COPY --from=ncurses /build/target /build/target

# # RUN find / -mount -name '*runtime*a' && exit 1

# # FROM llvm AS musl

# # RUN apt-get install -y curl make binutils

# # ARG BTDU_ARCH

# # COPY musl.sh /build/musl.sh
# # RUN /build/musl.sh


# # FROM 
# # # # For some reason Debian does not package this script.
# # # COPY musl-clang /usr/bin

# # RUN apt-get install -y lld

# # COPY setup-ldc-runtime.sh /root/setup-ldc-runtime.sh
# # RUN /root/setup-ldc-runtime.sh

# # # COPY setup-llvm-compiler-rt.sh /root/setup-llvm-compiler-rt.sh
# # # RUN /root/setup-llvm-compiler-rt.sh

# # RUN apt-get install -y libunwind-14-dev:amd64
