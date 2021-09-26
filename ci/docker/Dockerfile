FROM debian:sid-20210902

ARG BTDU_ARCH

COPY setup.sh /root/setup.sh
RUN /root/setup.sh

COPY setup-ldc.sh /root/setup-ldc.sh
RUN /root/setup-ldc.sh
