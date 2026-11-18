IMAGE := qnap-lego-cert-qdk

.PHONY: build fetch image lint test clean

## build: fetch lego, then run qbuild in a container -> qpkg/build/*.qpkg
build: fetch image
	docker run --rm -v "$(CURDIR)/qpkg:/src" $(IMAGE)
	@ls -l qpkg/build/

## fetch: download + verify the pinned lego binaries (see LEGO_VERSION)
fetch:
	scripts/fetch-lego.sh

image:
	docker build -t $(IMAGE) build-env

## lint: shellcheck everything (QTS scripts as POSIX sh)
lint:
	shellcheck -S warning -s sh -x -P qpkg/shared qpkg/shared/*.sh qpkg/shared/ui/index.cgi
	shellcheck -S warning scripts/*.sh

clean:
	rm -rf qpkg/build qpkg/x86_64/lego qpkg/arm_64/lego

## test: run the scripts under busybox ash with QTS stubbed (tests/harness.sh)
test:
	docker run --rm -v "$(CURDIR):/src:ro" docker.io/library/alpine:3.22 sh /src/tests/harness.sh
