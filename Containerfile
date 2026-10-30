FROM debian:bookworm-slim

# Image settings below mirror the official nginx:1.25-bookworm image
# (see `docker image inspect nginx:1.25-bookworm` and `docker history`).

ENV NGINX_VERSION=1.25.5
ENV PKG_RELEASE=1~echo1

COPY out/libpcre2-8-0_*.deb out/nginx_*.deb /tmp/

# - Create the nginx user and group with the same uid/gid (101) as the
#   official image; our .deb does not create them.
# - Install both packages in one apt-get call so apt resolves nginx's
#   dependency on libpcre2-8-0 against the local .deb. gettext-base
#   (envsubst, used by the entrypoint templates) and curl match the
#   official image.
# - Create /var/cache/nginx for the temp paths; the official package ships
#   it, our .deb does not.
# - Send the logs to the container's stdout/stderr.
# - Create /docker-entrypoint.d for the entrypoint scripts.
RUN groupadd --system --gid 101 nginx \
    && useradd --system --gid nginx --no-create-home --home /nonexistent \
        --comment "nginx user" --shell /bin/false --uid 101 nginx \
    && apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
        /tmp/libpcre2-8-0_*.deb \
        /tmp/nginx_*.deb \
        gettext-base \
        curl \
    && rm -rf /var/lib/apt/lists/* /tmp/* \
    && mkdir -p /var/cache/nginx \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
    && mkdir /docker-entrypoint.d

# Entrypoint scripts copied unchanged from nginx:1.25-bookworm.
COPY entrypoint/docker-entrypoint.sh /
COPY entrypoint/docker-entrypoint.d/ /docker-entrypoint.d/

ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 80

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
