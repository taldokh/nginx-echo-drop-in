FROM debian:bookworm-slim

# Build tools and the -dev headers for the libraries nginx links dynamically.
# The apt lists are kept: build-nginx.sh uses apt-cache to check the Depends names.
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

COPY build/build-nginx.sh build/build-pcre2.sh /build/
COPY build/patches/ /build/patches/
COPY build/conf/ /build/conf/
COPY build/html/ /build/html/

WORKDIR /build

CMD ["bash", "/build/build-nginx.sh"]
