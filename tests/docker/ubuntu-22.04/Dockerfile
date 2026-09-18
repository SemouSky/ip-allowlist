FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      coreutils \
      curl \
      ca-certificates \
      nftables \
      ufw \
      firewalld \
      dbus \
      iptables \
      iproute2 \
      shellcheck \
      procps \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
CMD ["/bin/bash"]
