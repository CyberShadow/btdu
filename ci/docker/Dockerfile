FROM debian:sid-20210902

RUN dpkg --add-architecture arm64
RUN apt-get update

RUN apt-get install -y \
    gcc                         binutils-x86-64-linux-gnu:amd64  libncurses-dev:amd64 libz-dev:amd64 libtinfo-dev:amd64 \
    gcc-aarch64-linux-gnu:amd64 binutils-aarch64-linux-gnu:amd64 libncurses-dev:arm64 libz-dev:arm64 libtinfo-dev:arm64 \
    jq xz-utils libxml2 curl

RUN mkdir /btdu
