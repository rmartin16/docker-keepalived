FROM alpine AS builder
LABEL maintainer = "Russell Martin - github/rmartin16/docker-keepalived"
LABEL description = "multiarch keepalived"

ARG KEEPALIVED_VERSION=2.2.7

RUN apk --no-cache add \
       autoconf \
       automake \
       binutils \
       curl \
       file \
       file-dev \
       gcc \
       ipset \
       ipset-dev \
       iptables \
       iptables-dev \
       libmnl-dev \
       libnftnl-dev \
       libnl3 \
       libnl3-dev \
       make \
       musl-dev \
       net-snmp-dev \
       openssl \
       openssl-dev \
       pcre2 \
       pcre2-dev \
    && curl -s -o keepalived.tar.gz -SL http://keepalived.org/software/keepalived-${KEEPALIVED_VERSION}.tar.gz \
    && mkdir -p /build/keepalived \
    && tar -xzf keepalived.tar.gz --strip 1 -C /build/keepalived \
    && cd /build/keepalived \
    && ./configure \
      MKDIR_P='/bin/mkdir -p'  \
      --disable-dynamic-linking \
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
      --mandir=/usr/share/man \
    && make && make install \
    && strip /usr/sbin/keepalived

FROM alpine
RUN apk --no-cache add \
       file \
       ipset \
       iptables \
       libmagic \
       libnl3 \
       libgcc \
       net-snmp \
       openssl \
       pcre2 \
    && addgroup -S keepalived_script \
    && adduser -D -S -G keepalived_script keepalived_script
COPY --from=builder /usr/sbin/keepalived /usr/sbin/keepalived
COPY assets/keepalived.conf /etc/keepalived/keepalived.conf
COPY assets/notify.sh /notify.sh
COPY assets/entrypoint.sh /entrypoint.sh

ENV INTERFACE="eth0"
ENV STATE="BACKUP"
ENV ROUTER_ID="41"
ENV PRIORITY="100"
ENV UNICAST_PEERS="192.168.2.101 192.168.2.102 192.168.2.103"
ENV VIRTUAL_IPS="192.168.2.100/24"
ENV PASSWORD="KeptAliv"
ENV NOTIFY="/notify.sh"

CMD ["/bin/sh", "-x", "entrypoint.sh"]
