#!/usr/bin/env bash
#
# Build nginx 1.25.5 with the CVE-2026-95101 fix (upstream 90b30edff) and
# the official nginx:1.25-bookworm configure arguments, packaged as a .deb.
# Runs in the builder image; writes to /out if present, else <repo>/out.

set -euo pipefail

NGINX_VERSION="1.25.5"
NGINX_TARBALL="nginx-$NGINX_VERSION.tar.gz"
NGINX_URL="https://nginx.org/download/$NGINX_TARBALL"
NGINX_SHA256="2fe2294f8af4144e7e842eaea884182a84ee7970e11046ba98194400902bbec0"
PKG_VERSION="1.25.5-1~echo1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="$SCRIPT_DIR/$NGINX_TARBALL"
SRC_DIR="$SCRIPT_DIR/nginx-$NGINX_VERSION"
PATCH_FILE="$SCRIPT_DIR/patches/nginx-1.25.5-CVE-2026-95101.patch"

die() { echo "build-nginx.sh: error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }


# 1. Download and verify the release tarball, then extract a fresh tree.

log "Fetching and extracting $NGINX_TARBALL"
if [ ! -f "$TARBALL" ] || [ "$(sha256_of "$TARBALL")" != "$NGINX_SHA256" ]; then
    curl -fsSL -o "$TARBALL.part" "$NGINX_URL"
    actual="$(sha256_of "$TARBALL.part")"
    if [ "$actual" != "$NGINX_SHA256" ]; then
        rm -f "$TARBALL.part"
        die "SHA-256 mismatch for $NGINX_TARBALL: expected $NGINX_SHA256, got $actual"
    fi
    mv "$TARBALL.part" "$TARBALL"
fi

rm -rf "$SRC_DIR"
tar -xzf "$TARBALL" -C "$SCRIPT_DIR"
cd "$SRC_DIR"


# 2. Backport the CVE-2026-95101 fix.

PARSE_C="src/http/v3/ngx_http_v3_parse.c"
PARSE_H="src/http/v3/ngx_http_v3_parse.h"

log "Applying $(basename "$PATCH_FILE")"

# Refuse to patch code that differs from what the fix was written against.
awk '/^ngx_http_v3_parse_data\(/,/^}/' "$PARSE_C" \
    | grep -qF 'rc = ngx_http_v3_parse_skip(b, &st->length);' \
    || die "vulnerable sw_skip code not found in ngx_http_v3_parse_data(); stopping"

git apply "$PATCH_FILE"

grep -qF 'rc = ngx_http_v3_parse_skip(b, &st->skip);' "$PARSE_C" \
    || die "fix not present in $PARSE_C after applying patch"


# 3. Configure with the official image's `nginx -V` arguments.

CC_OPT="-g -O2 -ffile-prefix-map=$SRC_DIR=. -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC"
LD_OPT="-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie"

configure_args=(
    --prefix=/etc/nginx
    --sbin-path=/usr/sbin/nginx
    --modules-path=/usr/lib/nginx/modules
    --conf-path=/etc/nginx/nginx.conf
    --error-log-path=/var/log/nginx/error.log
    --http-log-path=/var/log/nginx/access.log
    --pid-path=/var/run/nginx.pid
    --lock-path=/var/run/nginx.lock
    --http-client-body-temp-path=/var/cache/nginx/client_temp
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp
    --user=nginx
    --group=nginx
    --with-compat
    --with-file-aio
    --with-threads
    --with-http_addition_module
    --with-http_auth_request_module
    --with-http_dav_module
    --with-http_flv_module
    --with-http_gunzip_module
    --with-http_gzip_static_module
    --with-http_mp4_module
    --with-http_random_index_module
    --with-http_realip_module
    --with-http_secure_link_module
    --with-http_slice_module
    --with-http_ssl_module
    --with-http_stub_status_module
    --with-http_sub_module
    --with-http_v2_module
    --with-http_v3_module
    --with-mail
    --with-mail_ssl_module
    --with-stream
    --with-stream_realip_module
    --with-stream_ssl_module
    --with-stream_ssl_preread_module
    --with-cc-opt="$CC_OPT"
    --with-ld-opt="$LD_OPT"
)

log "Configuring"
CONFIGURE_LOG="$SRC_DIR/configure.log"
./configure "${configure_args[@]}" 2>&1 | tee "$CONFIGURE_LOG" \
    || die "configure failed (see $SRC_DIR/objs/autoconf.err)"

# --with-http_v3_module needs QUIC from the TLS library. Debian's OpenSSL 3.0
# has no native QUIC API, so nginx must fall back to its compatibility layer,
# as the official image does. Don't build an HTTP/3 binary without either.
grep -Eq 'checking for OpenSSL QUIC (support|compatibility) \.\.\. found' "$CONFIGURE_LOG" \
    || die "--with-http_v3_module: OpenSSL provides neither QUIC support nor the compatibility layer"


# 4. Build and install into a temporary staging directory.

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
chmod 0755 "$STAGE_DIR"

log "Building and installing into $STAGE_DIR"
make -j"$(nproc)" || die "make failed"
make install DESTDIR="$STAGE_DIR" || die "make install failed"

NGINX_BIN="$STAGE_DIR/usr/sbin/nginx"
nginx_version="$("$NGINX_BIN" -v 2>&1)"
[ "$nginx_version" = "nginx version: nginx/$NGINX_VERSION" ] \
    || die "built binary reports '$nginx_version', expected nginx/$NGINX_VERSION"


# 5. Replace make install's upstream samples with the official package layout.
#    The config and pages in conf/ and html/ are copied from nginx:1.25-bookworm.

log "Applying the official package layout"
ETC="$STAGE_DIR/etc/nginx"
rm -rf "$ETC/nginx.conf" "$ETC/conf.d" "$ETC/html" "$ETC"/*.default \
    "$ETC/koi-utf" "$ETC/koi-win" "$ETC/win-utf" "$ETC/fastcgi.conf"
install -D -m 0644 "$SCRIPT_DIR/conf/nginx.conf" "$ETC/nginx.conf"
install -D -m 0644 "$SCRIPT_DIR/conf/conf.d/default.conf" "$ETC/conf.d/default.conf"
install -D -m 0644 -t "$STAGE_DIR/usr/share/nginx/html" \
    "$SCRIPT_DIR/html/index.html" "$SCRIPT_DIR/html/50x.html"
install -d -m 0755 "$STAGE_DIR/usr/lib/nginx/modules"

# The official binary ships stripped; CC_OPT's -g would otherwise stay in it.
size_before="$(stat -c %s "$NGINX_BIN")"
strip --strip-unneeded "$NGINX_BIN"
log "Stripped $NGINX_BIN: $size_before -> $(stat -c %s "$NGINX_BIN") bytes"


# 6. Write the package control file.

ARCH="$(dpkg --print-architecture)"

mkdir -p "$STAGE_DIR/DEBIAN"
cat > "$STAGE_DIR/DEBIAN/control" <<EOF
Package: nginx
Version: $PKG_VERSION
Architecture: $ARCH
Maintainer: nginx-echo-drop-in build <root@localhost>
Depends: libc6 (>= 2.34), libcrypt1 (>= 1:4.1.0), libpcre2-8-0 (>= 10.22), libssl3 (>= 3.0.0), zlib1g (>= 1:1.1.4)
Section: httpd
Priority: optional
Homepage: https://nginx.org
Description: nginx $NGINX_VERSION with the CVE-2026-95101 HTTP/3 fix backported
 Built from the official nginx-$NGINX_VERSION release tarball with the same
 configure arguments as the nginx:1.25-bookworm image.
EOF


# 7. Build the .deb into the output directory.

OUT_DIR="/out"
if [ ! -d "$OUT_DIR" ]; then
    OUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/out"
    mkdir -p "$OUT_DIR"
fi

DEB_FILE="$OUT_DIR/nginx_${PKG_VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$STAGE_DIR" "$DEB_FILE" || die "dpkg-deb failed"
log "Package ready: $DEB_FILE"
