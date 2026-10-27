.PHONY: build test goss dgoss
DOCKER_USER = rmartin16
DOCKER_NAME = rmartin16/keepalived
VERSION := $(shell cat Dockerfile | grep -oP 'KEEPALIVED_VERSION=(.*)' | grep -oP '\d.\d.\d')
build:
	docker build --no-cache -t $(DOCKER_NAME) .

test:
	bash tests/verify_entrypoint.sh

GOSS_VERSION = 0.4.10
GOSS_SHA256 = 26e365428946294bcec0c61d867bb3c8349f39feb3d0e6f59084e98632785cc7
DGOSS_SHA256 = 3bb3ac9df33eeab8ce71a35763f4a69582eceb7db7bf02b4d0a551e72c7a888d
GOSS_URL = https://github.com/goss-org/goss/releases/download/v$(GOSS_VERSION)
GOSS_DIR = $(CURDIR)/.goss

# install a pinned, checksum-verified goss/dgoss (linux x86_64) into .goss/
goss:
	mkdir -p $(GOSS_DIR)
	curl -fsSL -o $(GOSS_DIR)/goss.tar.gz $(GOSS_URL)/goss_$(GOSS_VERSION)_linux_x86_64.tar.gz
	echo "$(GOSS_SHA256)  $(GOSS_DIR)/goss.tar.gz" | sha256sum -c -
	tar -xzf $(GOSS_DIR)/goss.tar.gz -C $(GOSS_DIR) goss
	rm $(GOSS_DIR)/goss.tar.gz
	curl -fsSL -o $(GOSS_DIR)/dgoss $(GOSS_URL)/dgoss
	echo "$(DGOSS_SHA256)  $(GOSS_DIR)/dgoss" | sha256sum -c -
	chmod +x $(GOSS_DIR)/goss $(GOSS_DIR)/dgoss

dgoss:
	which dgoss || $(MAKE) goss
	PATH="$(GOSS_DIR):$$PATH" dgoss run $(DOCKER_NAME)

push:
	docker login -u="$(DOCKER_USER)" -p="$(DOCKER_PASS)"
	VERSION=$$(cat Dockerfile | grep -oP 'KEEPALIVED_VERSION=(.*)' | grep -oP '\d.\d.\d')
	docker tag $(DOCKER_NAME) $(DOCKER_NAME):$(VERSION)
	docker push $(DOCKER_NAME):$(VERSION)
	docker push $(DOCKER_NAME)
