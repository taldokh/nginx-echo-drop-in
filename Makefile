# Build the patched nginx 1.25.5 and PCRE2 10.49 .debs inside the Debian
# builder container, and the final image that installs them.
#
#   make              build the builder image and both .debs into out/
#   make image        build only the builder image
#   make build-pcre2  build only the libpcre2-8-0 .deb
#   make final-image  build the final image from Containerfile
#   make test         build the final image and compare it with nginx:1.25-bookworm
#   make clean        remove out/

PYTHON       ?= python3
BUILDER_TAG  ?= nginx-builder
FINAL_TAG    ?= nginx-echo
ORIGINAL_TAG ?= nginx:1.25-bookworm
OUT_DIR      := $(CURDIR)/out

.PHONY: all deb build-pcre2 final-image image test clean

all: deb

image:
	docker build -f build/Dockerfile.Builder -t $(BUILDER_TAG) .

build-pcre2: image
	mkdir -p "$(OUT_DIR)"
	docker run --rm -v "$(OUT_DIR):/out" $(BUILDER_TAG) bash /build/build-pcre2.sh

deb: image build-pcre2
	mkdir -p "$(OUT_DIR)"
	docker run --rm -v "$(OUT_DIR):/out" $(BUILDER_TAG)
	@ls -1 "$(OUT_DIR)"/*.deb

final-image: deb
	docker build -f Containerfile -t $(FINAL_TAG) .

test: final-image
	$(PYTHON) test/test_compare.py --original $(ORIGINAL_TAG) --candidate $(FINAL_TAG)

clean:
	rm -rf "$(OUT_DIR)"
