FROM debian:buster-20210902

ARG BTDU_ARCH

COPY setup.sh /root/setup.sh
RUN /root/setup.sh

COPY setup-ldc.sh /root/setup-ldc.sh
RUN /root/setup-ldc.sh

COPY setup-ldc-runtime.sh /root/setup-ldc-runtime.sh
RUN /root/setup-ldc-runtime.sh
