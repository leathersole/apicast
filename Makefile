.DEFAULT_GOAL := help

DOCKER_COMPOSE = docker-compose
S2I = s2i
REGISTRY ?= quay.io/3scale
export TEST_NGINX_BINARY ?= openresty
NGINX = $(shell which $(TEST_NGINX_BINARY))
SHELL=/bin/bash -o pipefail
SEPARATOR="\n=============================================\n"

IMAGE_NAME ?= apicast-test
OPENRESTY_VERSION ?= 1.11.2.2-5
BUILDER_IMAGE ?= quay.io/3scale/s2i-openresty-centos7:$(OPENRESTY_VERSION)
RUNTIME_IMAGE ?= $(BUILDER_IMAGE)-runtime

test: ## Run all tests
	$(MAKE) --keep-going busted prove builder-image test-builder-image prove-docker runtime-image test-runtime-image

danger: TEMPFILE := $(shell mktemp)
danger:
	env | grep -E 'CIRCLE|TRAVIS|DANGER|SEAL' > $(TEMPFILE)
	docker run --rm -v $(PWD):/src/ -w /src/ --env-file=$(TEMPFILE) -u $(shell id -u) quay.io/3scale/danger danger

busted: dependencies ## Test Lua.
	@bin/busted
	@- luacov

nginx:
	@ ($(NGINX) -V 2>&1 | grep -e '--with-ipv6' > /dev/null) || (>&2 echo "$(NGINX) `$(NGINX) -v 2>&1` does not have ipv6 support" && exit 1)

# TODO: implement check to verify carton is there
carton:
	@carton install > /dev/null

prove: carton nginx ## Test nginx
	@carton exec prove 2>&1 | awk '/found ONLY/ { print "FAIL: because found ONLY in test"; print; exit 1 }; { print }'

prove-docker: export IMAGE_NAME = apicast-test
prove-docker: ## Test nginx inside docker
	$(DOCKER_COMPOSE) run --rm prove

builder-image: ## Build builder image
	$(S2I) build . $(BUILDER_IMAGE) $(IMAGE_NAME) --context-dir=apicast --copy --incremental

runtime-image: PULL_POLICY ?= always
runtime-image: IMAGE_NAME = apicast-runtime-test
runtime-image: ## Build runtime image
	$(S2I) build . $(BUILDER_IMAGE) $(IMAGE_NAME) --context-dir=apicast --runtime-image=$(RUNTIME_IMAGE) --pull-policy=$(PULL_POLICY)

push: ## Push image to the registry
	docker tag $(IMAGE_NAME) $(REGISTRY)/$(IMAGE_NAME)
	docker push $(REGISTRY)/$(IMAGE_NAME)

bash: export IMAGE_NAME = apicast-test
bash: export SERVICE = gateway
bash: ## Run bash inside the builder image
	$(DOCKER_COMPOSE) run --user=root --rm --entrypoint=bash $(SERVICE)

dev: export IMAGE_NAME = apicast-test
dev: export SERVICE = dev
dev: USER = root
dev: ## Run APIcast inside the container mounted to local volume
	$(DOCKER_COMPOSE) run --user=$(USER) --service-ports --rm --entrypoint=bash $(SERVICE) -i
test-builder-image: export IMAGE_NAME = apicast-test
test-builder-image: builder-image clean-containers ## Smoke test the builder image. Pass any docker image in IMAGE_NAME parameter.
	@echo -e $(SEPARATOR)
	$(DOCKER_COMPOSE) run --rm --user 100001 gateway openresty -p /opt/app -t
	@echo -e $(SEPARATOR)
	$(DOCKER_COMPOSE) run --rm --user 100001 gateway openresty -p /opt/app
	@echo -e $(SEPARATOR)
	$(DOCKER_COMPOSE) run --rm test bash -c 'for i in {1..5}; do curl --fail http://gateway:8090/status/live && break || sleep 1; done'
	$(DOCKER_COMPOSE) logs gateway
	@echo -e $(SEPARATOR)
	$(DOCKER_COMPOSE) run --rm test curl --fail -X PUT http://gateway:8090/config --data '{"services":[{"id":42}]}'
	@echo -e $(SEPARATOR)
	$(DOCKER_COMPOSE) run --rm -e THREESCALE_PORTAL_ENDPOINT=http://gateway:8090/config --user 100001 test bin/entrypoint -d
	@echo -e $(SEPARATOR)
	$(DOCKER_COMPOSE) run --rm test curl --fail http://gateway:8090/status/ready
	@echo -e $(SEPARATOR)
	$(DOCKER_COMPOSE) run --rm test curl --fail -X POST http://gateway:8090/boot
	@echo -e $(SEPARATOR)
	$(DOCKER_COMPOSE) run --rm -e THREESCALE_PORTAL_ENDPOINT=https://echo-api.3scale.net gateway /opt/app/libexec/boot | grep 'APIcast/'

gateway-logs: export IMAGE_NAME = does-not-matter
gateway-logs:
	$(DOCKER_COMPOSE) logs gateway

test-runtime-image: export IMAGE_NAME = apicast-runtime-test
test-runtime-image: clean-containers ## Smoke test the runtime image. Pass any docker image in IMAGE_NAME parameter.
	$(DOCKER_COMPOSE) run --rm --user 100001 gateway apicast -d
	@echo -e $(SEPARATOR)
	$(DOCKER_COMPOSE) run --rm --user 100002 -e APICAST_CONFIGURATION_LOADER=boot -e THREESCALE_PORTAL_ENDPOINT=https://echo-api.3scale.net gateway bin/apicast -d
	@echo -e $(SEPARATOR)
	$(DOCKER_COMPOSE) run --rm test sh -c 'sleep 5 && curl --fail http://gateway:8090/status/live'

dependencies:
	luarocks make apicast/*.rockspec
	luarocks make rockspec

clean-containers:
	$(DOCKER_COMPOSE) down --volumes --remove-orphans

clean: clean-containers ## Remove all running docker containers and images
	- docker rmi apicast-test apicast-runtime-test --force

doc: dependencies ## Generate documentation
	ldoc -c doc/config.ld .

node_modules/.bin/markdown-link-check:
	yarn install

test-doc: node_modules/.bin/markdown-link-check
	@find . \( -name node_modules -o -name .git -o -name t \) -prune -o -name "*.md" -print0 | xargs -0 -n1  -I % sh -c 'echo; echo ====================; echo Checking: %; node_modules/.bin/markdown-link-check  %' \;

# Check http://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
help: ## Print this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
