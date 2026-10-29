# Build the patched nginx 1.25.5 .deb inside the Debian builder container.
#
#   make          build the builder image and the .deb into out/
#   make image    build only the builder image
#   make clean    remove out/

DOCKER       ?= docker
BUILDER_TAG  ?= nginx-builder
OUT_DIR      := $(CURDIR)/out

.PHONY: all deb image clean

all: deb

image:
	$(DOCKER) build -f Build/Dockerfile.Builder -t $(BUILDER_TAG) .

deb: image
	mkdir -p "$(OUT_DIR)"
	$(DOCKER) run --rm -v "$(OUT_DIR):/out" $(BUILDER_TAG)
	@ls -1 "$(OUT_DIR)"/*.deb

clean:
	rm -rf "$(OUT_DIR)"
