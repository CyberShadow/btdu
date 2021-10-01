FROM debian:buster-20210902

ARG BTDU_ARCH

COPY setup.sh /root/setup.sh
RUN /root/setup.sh

COPY setup-ldc.sh /root/setup-ldc.sh
RUN /root/setup-ldc.sh

RUN apt-get install -y cmake

COPY setup-ldc2.sh /root/setup-ldc2.sh
RUN /root/setup-ldc2.sh
