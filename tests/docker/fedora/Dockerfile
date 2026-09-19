FROM fedora:39

RUN dnf install -y \
      bash \
      coreutils \
      curl \
      nftables \
      firewalld \
      dbus-daemon \
      iproute \
      iputils \
      procps-ng \
 && dnf clean all

WORKDIR /src
CMD ["/bin/bash"]
