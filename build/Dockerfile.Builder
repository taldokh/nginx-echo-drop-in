FROM debian:bookworm-slim

# Build tools and the -dev headers for the libraries nginx links dynamically.
# The apt lists are kept: build.sh uses apt-cache to check the Depends names.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        libcrypt-dev \
        libpcre2-dev \
        libssl-dev \
        zlib1g-dev

COPY Build/build.sh Build/nginx-1.25.5-CVE-2026-95101.patch /build/

WORKDIR /build

CMD ["bash", "/build/build.sh"]
