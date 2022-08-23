# docker-keepalived
[Keepalived](https://github.com/acassen/keepalived) docker image for `amd64`, `i386`, `arm64`, `arm/v6`, `arm/v7`.

## Quick start
    docker run \
        --name keepalived \
        --cap-add=NET_ADMIN \
        --net=host \
        --detach \
        ghcr.io/rmartin16/keepalived:weekly

## Environment Variables

The configuration can be set using environment variables:

    docker run \
        --env INTERFACE=eth1 \
        --env STATE=BACKUP \
        --name keepalived \
        --cap-add=NET_ADMIN \
        --net=host \
        --detach \
        ghcr.io/rmartin16/keepalived:weekly

- **INTERFACE**: Defaults to `eth0`
- **STATE**: Default state. Defaults to `BACKUP`
- **ROUTER_ID**: Virtual router ID. Defaults to `41`
- **PRIORITY**: Node priority. Defaults to `100`
- **UNICAST_PEERS**: Unicast peers, space-separated. Defaults to `192.168.2.101 192.168.2.102 192.168.2.103`
- **VIRTUAL_IPS**: Defaults to `192.168.2.100/24`
- **PASSWORD**: Defaults to `KeptAliv`
- **NOTIFY**: Notify script. Defaults to `/notify.sh`

## Configuration file
Example:

    docker run \
        --name keepalived \
        --cap-add=NET_ADMIN \
        --net=host \
        --volume $(pwd)/keepalived.conf:/etc/keepalived/keepalived.conf \
        --detach \
        ghcr.io/rmartin16/keepalived:weekly

## docker-compose
    
    version: "3"
    services:
      keepalived:
        container_name: keepalived
        image: ghcr.io/rmartin16/keepalived:weekly
        network_mode: host
        cap_add:
          - NET_ADMIN
        volumes:
          - ./config/keepalived/keepalived.conf:/etc/keepalived/keepalived.conf
        restart: unless-stopped

## Sources
[Oracle Linux Administrator's Guide](https://docs.oracle.com/cd/E37670_01/E41138/html/ol6-loadbal.html)

Direct parent:
[rvben/rpi-keepalived](https://github.com/rvben/rpi-keepalived)

Transitive parent:
[osixia/docker-keepalived](https://github.com/osixia/docker-keepalived)
