FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS builder
LABEL maintainer="Russell Martin - github/rmartin16/docker-keepalived"
LABEL description="multiarch keepalived"

RUN apk --update-cache add \
       autoconf \
       automake \
       bash \
       binutils \
       curl \
       file \
       file-dev \
       gcc \
       ipset \
       ipset-dev \
       iptables \
       iptables-dev \
       libip6tc \
       libip4tc \
       libmnl-dev \
       libnftnl-dev \
       libnl3 \
       libnl3-dev \
       linux-headers \
       make \
       musl-dev \
       net-snmp-dev \
       openssl \
       openssl-dev \
       pcre2 \
       pcre2-dev

ARG KEEPALIVED_VERSION=2.3.2
RUN curl -sSfL -o keepalived.tar.gz https://keepalived.org/software/keepalived-${KEEPALIVED_VERSION}.tar.gz && \
    mkdir -p /build/keepalived && \
    tar -xzf keepalived.tar.gz --strip 1 -C /build/keepalived

WORKDIR /build/keepalived
ENV CFLAGS="-Wno-incompatible-pointer-types -Wno-error=declaration-after-statement"
RUN sed -i 's/#include <linux\/if_ether.h>//' keepalived/vrrp/vrrp.c
RUN ./build_setup
RUN /bin/bash ./configure \
      MKDIR_P='/bin/mkdir -p' \
      --disable-dynamic-linking \
      --disable-dependency-tracking \
      --enable-bfd \
      --enable-json \
      --enable-nftables \
      --enable-snmp \
      --enable-snmp-rfc \
      --enable-regex \
      --prefix=/usr \
      --exec-prefix=/usr \
      --bindir=/usr/bin \
      --sbindir=/usr/sbin \
      --sysconfdir=/etc \
      --datadir=/usr/share \
      --localstatedir=/var \
      --mandir=/usr/share/man
RUN make
RUN make install
RUN strip /usr/sbin/keepalived

FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a
RUN apk --no-cache add \
       file \
       ipset \
       iptables \
       libip6tc \
       libip4tc \
       libmagic \
       libnl3 \
       libgcc \
       net-snmp \
       openssl \
       pcre2 && \
    addgroup -S keepalived_script && \
    adduser -D -S -G keepalived_script keepalived_script && \
    # workaround for https://github.com/acassen/keepalived/issues/2503
    mkdir -p /usr/share/iproute2/rt_addrprotos.d && \
    mkdir -p /etc/iproute2/rt_addrprotos.d

COPY --from=builder /usr/sbin/keepalived /usr/sbin/keepalived
COPY assets/keepalived.conf /etc/keepalived/keepalived.conf
COPY assets/notify.sh /notify.sh
COPY assets/entrypoint.sh /entrypoint.sh

ENV INTERFACE="eth0" \
    STATE="BACKUP" \
    ROUTER_ID="41" \
    PRIORITY="100" \
    UNICAST_PEERS="192.168.2.101 192.168.2.102 192.168.2.103" \
    VIRTUAL_IPS="192.168.2.100/24" \
    PASSWORD="KeptAliv" \
    NOTIFY="/notify.sh"

CMD ["/bin/sh", "-x", "entrypoint.sh"]
