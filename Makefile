.PHONY: build test test-image test-failover
DOCKER_USER = rmartin16
DOCKER_NAME = rmartin16/keepalived
VERSION := $(shell cat Dockerfile | grep -oP 'KEEPALIVED_VERSION=(.*)' | grep -oP '\d.\d.\d')
build:
	docker build --no-cache -t $(DOCKER_NAME) .

test: build
	$(MAKE) test-image test-failover

test-image:
	bash tests/verify_image.sh

test-failover:
	bash tests/verify_failover.sh

push:
	docker login -u="$(DOCKER_USER)" -p="$(DOCKER_PASS)"
	VERSION=$$(cat Dockerfile | grep -oP 'KEEPALIVED_VERSION=(.*)' | grep -oP '\d.\d.\d')
	docker tag $(DOCKER_NAME) $(DOCKER_NAME):$(VERSION)
	docker push $(DOCKER_NAME):$(VERSION)
	docker push $(DOCKER_NAME)
