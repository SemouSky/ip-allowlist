FROM rockylinux/rockylinux:9

RUN dnf install -y --allowerasing \
      bash \
      coreutils \
      curl \
      nftables \
      firewalld \
      dbus-daemon \
      iproute \
      procps-ng \
 && dnf clean all

WORKDIR /src
CMD ["/bin/bash"]
