FROM rockylinux/rockylinux:9

RUN dnf install -y --allowerasing epel-release \
 && dnf install -y --allowerasing \
      bash \
      coreutils \
      curl \
      nftables \
      firewalld \
      dbus-daemon \
      iproute \
      iputils \
      bats \
      procps-ng \
 && dnf clean all

WORKDIR /src
CMD ["/bin/bash"]
