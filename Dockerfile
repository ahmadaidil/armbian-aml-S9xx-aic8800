FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        cloud-guest-utils \
        curl \
        dosfstools \
        e2fsprogs \
        mount \
        parted \
        python3 \
        udev \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
