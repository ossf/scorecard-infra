SHELL := /bin/bash
GIT_HASH := $(shell git rev-parse HEAD)
GIT_VERSION ?= $(shell git describe --tags --always --dirty)
GIT_TREESTATE = $(shell if git diff --quiet; then echo "clean"; else echo "dirty"; fi)
SOURCE_DATE_EPOCH = $(shell git log --date=iso8601-strict -1 --pretty=%ct)
IMAGE_NAME = scorecard
PLATFORM = "linux/amd64,linux/arm64,linux/386,linux/arm"

# Injected into sigs.k8s.io/release-utils/version. Upstream ossf/scorecard keeps
# this in scripts/version-ldflags because .goreleaser.yml shares it; there is no
# goreleaser here, so it is inlined.
VERSION_PKG = sigs.k8s.io/release-utils/version
LDFLAGS = -X $(VERSION_PKG).gitVersion=$(GIT_VERSION) \
          -X $(VERSION_PKG).gitCommit=$(GIT_HASH) \
          -X $(VERSION_PKG).gitTreeState=$(GIT_TREESTATE) \
          -X $(VERSION_PKG).buildDate=$(SOURCE_DATE_EPOCH) \
          -w -extldflags "-static"

############################### make help #####################################
.PHONY: help
help:  ## Display this help
	@awk 'BEGIN {FS = ":.*##"; \
			printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ \
			{ printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2 } \
			/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Tools
###############################################################################
# Build tools are expected on PATH rather than vendored in a tools module.
#
# Upstream pins ko and protoc-gen-go in tools/go.mod, but that module carries a
# 519-line known-good dependency graph to make them resolve. Reproducing it here
# to vendor two binaries costs more than it returns, and a fresh tools module
# does not resolve cleanly (ko v0.18.1 wants gopkg.in/yaml.v3 where MVS picks
# go.yaml.in/yaml/v4; ko v0.19.1 requires a newer Go than this module targets).
# Upstream already treats protoc this way. Pinning belongs in CI, where the
# published images are actually built.
KO ?= $(shell which ko)
PROTOC ?= $(shell which protoc)
PROTOC_GEN_GO ?= $(shell which protoc-gen-go)
KOCACHE_PATH = /tmp/ko

# go-swagger is the one tool here pinned to an exact version, because it is the
# one whose output is committed. A ko or protoc version difference shows up in
# an artifact CI rebuilds anyway; a go-swagger difference shows up as hundreds
# of spurious lines in api/app/generated/, indistinguishable from an intended
# change. The swagger-verify presubmit regenerates and diffs, so CI and a
# developer's machine have to agree on the version or the job cannot be
# reproduced locally.
#
# Bumping it is deliberate: change this, run `make api-swagger`, and commit the
# regenerated tree in the same commit.
SWAGGER_VERSION ?= v0.36.5
SWAGGER ?= $(shell which swagger)

.PHONY: check-ko check-protoc check-swagger
check-ko:
	@if [ -z "$(KO)" ]; then \
		echo "ko not found on PATH - install from https://ko.build/install/"; exit 1; \
	fi
check-protoc:
	@if [ -z "$(PROTOC)" ]; then \
		echo "protoc not found on PATH - https://protobuf.dev/installation/"; exit 1; \
	fi
	@if [ -z "$(PROTOC_GEN_GO)" ]; then \
		echo "protoc-gen-go not found on PATH - go install google.golang.org/protobuf/cmd/protoc-gen-go@latest"; exit 1; \
	fi

# Unlike check-ko and check-protoc, this asserts the version and not just
# presence -- see the SWAGGER_VERSION comment above.
check-swagger:
	@if [ -z "$(SWAGGER)" ]; then \
		echo "swagger not found on PATH"; \
		echo "  go install github.com/go-swagger/go-swagger/cmd/swagger@$(SWAGGER_VERSION)"; \
		exit 1; \
	fi
	@have=$$($(SWAGGER) version 2>/dev/null | awk '/^version:/ {print $$2}'); \
	if [ "$$have" != "$(SWAGGER_VERSION)" ]; then \
		echo "swagger $$have is on PATH, but this repository generates with $(SWAGGER_VERSION)"; \
		echo "  go install github.com/go-swagger/go-swagger/cmd/swagger@$(SWAGGER_VERSION)"; \
		exit 1; \
	fi

# Consumed by .github/workflows/presubmits.yml so the pinned version has one
# home. Intentionally undocumented in `make help`.
.PHONY: print-swagger-version
print-swagger-version:
	@echo $(SWAGGER_VERSION)

$(KOCACHE_PATH):
	mkdir -p $(KOCACHE_PATH)

##@ Verify
###############################################################################
.PHONY: build test lint
build: ## Build all packages
	go build ./...
test: ## Run all tests with the race detector
	go test ./... -race
lint: ## Run golangci-lint
	golangci-lint run ./...

##@ Results API
###############################################################################
# The imported API keeps its own Makefile with upstream's recipes, whose paths
# are relative to api/ (design W5: upstream layout intact). These delegate to it
# so the repository root stays the single entry point.
.PHONY: api-build api-swagger api-docker
api-build: ## Build the results API binary (api/scorecard-webapp)
	$(MAKE) -C api scorecard-webapp

api-swagger: ## Regenerate the API server and client from api/openapi.yaml
api-swagger: check-swagger
	$(MAKE) -C api swagger

# Context is the repository root because go.mod lives here, matching the
# pipeline image targets below.
api-docker: ## Build the results API image
	DOCKER_BUILDKIT=1 docker build . --file api/Dockerfile \
		--tag $(IMAGE_NAME)-api

##@ Protobuf
###############################################################################
# Deliberately NOT expressed as file rules (.pb.go depending on .proto), which is
# how upstream does it. A file rule regenerates whenever the .proto is newer,
# which drags protoc into ordinary `go build` paths -- and fails confusingly when
# it is absent, because the generated sources are also inputs to several binary
# targets. Regeneration here is explicit: run `make build-proto` deliberately,
# and commit the result.
.PHONY: build-proto
build-proto: ## Regenerate the pipeline protobufs (requires protoc)
build-proto: check-protoc
	$(PROTOC) --plugin=$(PROTOC_GEN_GO) --go_out=. --go_opt=paths=source_relative cron/data/request.proto
	$(PROTOC) --plugin=$(PROTOC_GEN_GO) --go_out=. --go_opt=paths=source_relative cron/data/metadata.proto

##@ Pipeline binaries
###############################################################################
CRON_CONTROLLER_DEPS = $(shell find cron/internal/ -iname "*.go")
build-controller: ## Build the cron PubSub controller
build-controller: cron/internal/controller/controller
cron/internal/controller/controller: $(CRON_CONTROLLER_DEPS)
	cd cron/internal/controller && CGO_ENABLED=0 go build -trimpath -a -ldflags '$(LDFLAGS)' -o controller

build-worker: ## Build the cron PubSub worker
	cd cron/internal/worker && CGO_ENABLED=0 go build -trimpath -a -ldflags '$(LDFLAGS)' -o worker

CRON_CII_DEPS = $(shell find cron/internal/ -iname "*.go")
build-cii-worker: ## Build the cron CII worker
build-cii-worker: cron/internal/cii/cii-worker
cron/internal/cii/cii-worker: $(CRON_CII_DEPS)
	cd cron/internal/cii && CGO_ENABLED=0 go build -trimpath -a -ldflags '$(LDFLAGS)' -o cii-worker

CRON_SHUFFLER_DEPS = $(shell find cron/data/ cron/internal/shuffle/ -iname "*.go")
build-shuffler: ## Build the cron shuffle script
build-shuffler: cron/internal/shuffle/shuffle
cron/internal/shuffle/shuffle: $(CRON_SHUFFLER_DEPS)
	cd cron/internal/shuffle && CGO_ENABLED=0 go build -trimpath -a -ldflags '$(LDFLAGS)' -o shuffle

CRON_TRANSFER_DEPS = $(shell find cron/data/ cron/config/ cron/internal/bq/ -iname "*.go")
build-bq-transfer: ## Build the cron BigQuery transfer worker
build-bq-transfer: cron/internal/bq/data-transfer
cron/internal/bq/data-transfer: $(CRON_TRANSFER_DEPS)
	cd cron/internal/bq && CGO_ENABLED=0 go build -trimpath -a -ldflags '$(LDFLAGS)' -o data-transfer

CRON_WEBHOOK_DEPS = $(shell find cron/internal/webhook/ cron/data/ -iname "*.go")
build-webhook: ## Build the cron webhook server
build-webhook: cron/internal/webhook/webhook
cron/internal/webhook/webhook: $(CRON_WEBHOOK_DEPS)
	cd cron/internal/webhook && CGO_ENABLED=0 go build -trimpath -a -ldflags '$(LDFLAGS)' -o webhook

# Relocated from clients/githubrepo/roundtripper/tokens/server/ during the
# migration (C6). Its parent tokens/ package stays in ossf/scorecard.
TOKEN_SERVER_DEPS = $(shell find cron/internal/githubserver/ -iname "*.go")
build-github-server: ## Build the GitHub token-pool server
build-github-server: cron/internal/githubserver/github-auth-server
cron/internal/githubserver/github-auth-server: $(TOKEN_SERVER_DEPS)
	cd cron/internal/githubserver && CGO_ENABLED=0 go build -trimpath -a -ldflags '$(LDFLAGS)' -o github-auth-server

build-add-script: ## Build the projects.csv add script
build-add-script: cron/internal/data/add/add
cron/internal/data/add/add: cron/internal/data/add/*.go cron/data/*.go cron/internal/data/projects.csv
	cd cron/internal/data/add && CGO_ENABLED=0 go build -trimpath -a -ldflags '$(LDFLAGS)' -o add

build-validate-script: ## Build the projects.csv validate script
build-validate-script: cron/internal/data/validate/validate
cron/internal/data/validate/validate: cron/internal/data/validate/*.go cron/data/*.go cron/internal/data/projects.csv
	cd cron/internal/data/validate && CGO_ENABLED=0 go build -trimpath -a -ldflags '$(LDFLAGS)' -o validate

##@ Container images
###############################################################################
docker-targets = cron-controller-docker cron-worker-docker cron-cii-worker-docker \
                 cron-bq-transfer-docker cron-webhook-docker cron-github-server-docker
.PHONY: dockerbuild $(docker-targets)
dockerbuild: ## Build all pipeline container images
dockerbuild: $(docker-targets)

cron-controller-docker: ## Build the cron controller image
	DOCKER_BUILDKIT=1 docker build . --file cron/internal/controller/Dockerfile \
		--tag $(IMAGE_NAME)-batch-controller

cron-worker-docker: ## Build the cron worker image
	DOCKER_BUILDKIT=1 docker build . --file cron/internal/worker/Dockerfile \
		--tag $(IMAGE_NAME)-batch-worker

cron-cii-worker-docker: ## Build the cron CII worker image
	DOCKER_BUILDKIT=1 docker build . --file cron/internal/cii/Dockerfile \
		--tag $(IMAGE_NAME)-cii-worker

cron-bq-transfer-docker: ## Build the cron BigQuery transfer image
	DOCKER_BUILDKIT=1 docker build . --file cron/internal/bq/Dockerfile \
		--tag $(IMAGE_NAME)-bq-transfer

cron-webhook-docker: ## Build the cron webhook image
	DOCKER_BUILDKIT=1 docker build . --file cron/internal/webhook/Dockerfile \
		--tag $(IMAGE_NAME)-webhook

cron-github-server-docker: ## Build the GitHub token-pool server image
	DOCKER_BUILDKIT=1 docker build . --file cron/internal/githubserver/Dockerfile \
		--tag $(IMAGE_NAME)-github-server

##@ ko images
###############################################################################
ko-targets = cron-controller-ko cron-worker-ko cron-cii-worker-ko \
             cron-bq-transfer-ko cron-webhook-ko cron-github-server-ko
.PHONY: ko-images $(ko-targets)
ko-images: ## Build all pipeline images with ko
ko-images: $(ko-targets)

# $(1) = image suffix, $(2) = package import path
define ko_build
	KO_DATA_DATE_EPOCH=$(SOURCE_DATE_EPOCH) \
		KO_DOCKER_REPO=$(KO_PREFIX)/$(IMAGE_NAME)-$(1) \
		LDFLAGS="$(LDFLAGS)" \
		KOCACHE=$(KOCACHE_PATH) \
		$(KO) build -B \
		--push=false \
		--sbom=none \
		--platform=$(PLATFORM) \
		--tags latest,$(GIT_VERSION),$(GIT_HASH) \
		github.com/ossf/scorecard-infra/$(2)
endef

cron-controller-ko: ## Build the cron controller image with ko
cron-controller-ko: check-ko | $(KOCACHE_PATH)
	$(call ko_build,batch-controller,cron/internal/controller)

cron-worker-ko: ## Build the cron worker image with ko
cron-worker-ko: check-ko | $(KOCACHE_PATH)
	$(call ko_build,batch-worker,cron/internal/worker)

cron-cii-worker-ko: ## Build the cron CII worker image with ko
cron-cii-worker-ko: check-ko | $(KOCACHE_PATH)
	$(call ko_build,cii-worker,cron/internal/cii)

cron-bq-transfer-ko: ## Build the cron BigQuery transfer image with ko
cron-bq-transfer-ko: check-ko | $(KOCACHE_PATH)
	$(call ko_build,bq-transfer,cron/internal/bq)

cron-webhook-ko: ## Build the cron webhook image with ko
cron-webhook-ko: check-ko | $(KOCACHE_PATH)
	$(call ko_build,webhook,cron/internal/webhook)

cron-github-server-ko: ## Build the GitHub token-pool server image with ko
cron-github-server-ko: check-ko | $(KOCACHE_PATH)
	$(call ko_build,github-server,cron/internal/githubserver)

##@ Scan inventory
###############################################################################
.PHONY: add-projects validate-projects
add-projects: ## Add new projects to the GitHub and GitLab scan inventories
add-projects: ./cron/internal/data/projects.csv | build-add-script
	# GitHub
	./cron/internal/data/add/add ./cron/internal/data/projects.csv ./cron/internal/data/projects.new.csv
	mv ./cron/internal/data/projects.new.csv ./cron/internal/data/projects.csv
	# GitLab
	./cron/internal/data/add/add ./cron/internal/data/gitlab-projects.csv ./cron/internal/data/gitlab-projects.new.csv
	mv ./cron/internal/data/gitlab-projects.new.csv ./cron/internal/data/gitlab-projects.csv

validate-projects: ## Validate the scan inventories
validate-projects: ./cron/internal/data/projects.csv | build-validate-script
	./cron/internal/data/validate/validate ./cron/internal/data/projects.csv
	./cron/internal/data/validate/validate ./cron/internal/data/gitlab-projects.csv
	./cron/internal/data/validate/validate ./cron/internal/data/gitlab-projects-releasetest.csv
