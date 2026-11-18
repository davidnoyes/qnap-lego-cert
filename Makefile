IMAGE := qnap-lego-cert-qdk

.PHONY: build fetch image lint test lego-flags e2e clean

## build: fetch lego, then run qbuild in a container -> qpkg/build/*.qpkg
build: fetch image
	docker run --rm -v "$(CURDIR)/qpkg:/src" $(IMAGE)
	@ls -l qpkg/build/

## fetch: download + verify the pinned lego binaries (version from tools/go.mod)
fetch:
	scripts/fetch-lego.sh

image:
	docker build -t $(IMAGE) build-env

## lint: shellcheck everything (QTS scripts as POSIX sh)
lint:
	shellcheck -S warning -s sh -x -P qpkg/shared qpkg/shared/*.sh qpkg/shared/ui/index.cgi
	shellcheck -S warning scripts/*.sh tests/e2e/run.sh
	shellcheck -S warning -s sh tests/lego-flags.sh

clean:
	rm -rf qpkg/build qpkg/x86_64/lego qpkg/arm_64/lego

## test: run the scripts under busybox ash with QTS stubbed (tests/harness.sh)
test:
	docker run --rm -v "$(CURDIR):/src:ro" docker.io/library/alpine:3.22 sh /src/tests/harness.sh

## lego-flags: check the REAL lego binary has every flag and variable renew.sh uses
lego-flags: fetch
	docker run --rm -v "$(CURDIR):/src:ro" docker.io/library/alpine:3.22 sh /src/tests/lego-flags.sh

## e2e: LegoCert with the REAL lego against Pebble, Let's Encrypt's test ACME server
e2e: fetch
	tests/e2e/run.sh
