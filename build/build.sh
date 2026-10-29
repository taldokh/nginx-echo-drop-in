#!/usr/bin/env bash
#
# Download the nginx 1.25.5 release tarball, verify its SHA-256, backport
# the CVE-2026-95101 fix ("HTTP/3: kept the skipped frame length separate from
# data length", upstream 90b30edff / 1c173a2d8), build it with the same
# configure arguments as the official nginx:1.25-bookworm image, and package
# the result as a .deb.
#
# Meant to run inside the builder image (Build/Dockerfile.Builder). The .deb
# is written to /out if that directory exists, otherwise to <repo>/out.
#
# Requires: curl, tar, sha256sum, git (for git apply), a C toolchain, the
# libssl/pcre2/zlib/libcrypt -dev packages, dpkg-deb, apt-cache, ldd.

set -euo pipefail

NGINX_VERSION="1.25.5"
NGINX_TARBALL="nginx-$NGINX_VERSION.tar.gz"
NGINX_URL="https://nginx.org/download/$NGINX_TARBALL"
NGINX_SHA256="2fe2294f8af4144e7e842eaea884182a84ee7970e11046ba98194400902bbec0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="$SCRIPT_DIR/$NGINX_TARBALL"
SRC_DIR="$SCRIPT_DIR/nginx-$NGINX_VERSION"
PATCH_FILE="$SCRIPT_DIR/nginx-1.25.5-CVE-2026-95101.patch"

die() { echo "build.sh: error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[ -f "$PATCH_FILE" ] || die "patch file not found: $PATCH_FILE"


# 1. Download the release tarball and verify its checksum.

sha256_of() {
    sha256sum "$1" | cut -d' ' -f1
}

if [ -f "$TARBALL" ] && [ "$(sha256_of "$TARBALL")" = "$NGINX_SHA256" ]; then
    log "Reusing verified $TARBALL"
else
    log "Downloading $NGINX_URL"
    curl -fsSL -o "$TARBALL.part" "$NGINX_URL"
    actual="$(sha256_of "$TARBALL.part")"
    if [ "$actual" != "$NGINX_SHA256" ]; then
        rm -f "$TARBALL.part"
        die "SHA-256 mismatch for $NGINX_TARBALL: expected $NGINX_SHA256, got $actual"
    fi
    mv "$TARBALL.part" "$TARBALL"
fi
log "SHA-256 OK: $NGINX_SHA256"

log "Extracting into $SRC_DIR"
rm -rf "$SRC_DIR"
tar -xzf "$TARBALL" -C "$SCRIPT_DIR"
[ -d "$SRC_DIR/src" ] || die "unexpected tarball layout: $SRC_DIR/src missing"

cd "$SRC_DIR"


# 2. Backport the CVE-2026-95101 fix.

PARSE_C="src/http/v3/ngx_http_v3_parse.c"
PARSE_H="src/http/v3/ngx_http_v3_parse.h"

# Confirm the vulnerable code is present: ngx_http_v3_parse_data()'s sw_skip
# must call ngx_http_v3_parse_skip(b, &st->length). Refuse to guess otherwise.
log "Verifying vulnerable code in ngx_http_v3_parse_data()"
parse_data_body="$(awk '/^ngx_http_v3_parse_data\(/,/^}/' "$PARSE_C")"
[ -n "$parse_data_body" ] \
    || die "ngx_http_v3_parse_data() not found in $PARSE_C"
grep -q 'case sw_skip:' <<<"$parse_data_body" \
    || die "sw_skip state not found in ngx_http_v3_parse_data(); code differs, stopping"
grep -q 'rc = ngx_http_v3_parse_skip(b, &st->length);' <<<"$parse_data_body" \
    || die "sw_skip does not call ngx_http_v3_parse_skip(b, &st->length); code differs, stopping"
if grep -q 'st->skip' <<<"$parse_data_body"; then
    die "ngx_http_v3_parse_data() already uses st->skip; fix may already be applied"
fi

# Only the two intended files may be touched by the patch.
patched="$(git apply --numstat "$PATCH_FILE" | cut -f3 | sort | tr '\n' ' ')"
[ "$patched" = "$PARSE_C $PARSE_H " ] \
    || die "patch touches unexpected files: $patched"

log "Applying CVE-2026-95101 fix from $PATCH_FILE"
# --check first so a mismatch aborts without touching the tree.
git apply --check "$PATCH_FILE" \
    || die "patch does not apply cleanly; code differs from expected, stopping"
git apply "$PATCH_FILE"

grep -q 'rc = ngx_http_v3_parse_skip(b, &st->skip);' "$PARSE_C" \
    || die "fix not present in $PARSE_C after applying patch"

log "Backport applied"
git apply --stat "$PATCH_FILE"


# 3. Configure with the arguments of the official nginx:1.25-bookworm image
#    (from `nginx -V`). Libraries are linked dynamically: no --with-openssl=,
#    --with-zlib= or --with-pcre= source options.
#
#    The only change from `nginx -V`: -ffile-prefix-map pointed at the
#    official builder's source path; here it maps our own source path to "."
#    so the binary does not embed /build/nginx-1.25.5.

PKG_VERSION="1.25.5-1~echo1"

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
    || die "configure failed (see $CONFIGURE_LOG and $SRC_DIR/objs/autoconf.err)"

# --with-http_v3_module needs QUIC from the TLS library. The official image
# uses Debian's OpenSSL 3.0, which has no native QUIC API, so nginx falls back
# to its OpenSSL compatibility layer. Make sure one of the two was found.
if grep -q 'checking for OpenSSL QUIC support ... found' "$CONFIGURE_LOG"; then
    log "TLS: OpenSSL with native QUIC support"
elif grep -q 'checking for OpenSSL QUIC compatibility ... found' "$CONFIGURE_LOG"; then
    log "TLS: OpenSSL QUIC compatibility layer (same as the official image)"
else
    die "--with-http_v3_module: the installed OpenSSL provides neither QUIC support nor the compatibility layer"
fi


# 4. Build.

log "Building (make -j$(nproc))"
make -j"$(nproc)" || die "make failed"


# 5. Install into a temporary staging directory.

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
chmod 0755 "$STAGE_DIR"

log "Installing into staging directory $STAGE_DIR"
make install DESTDIR="$STAGE_DIR" || die "make install failed"

NGINX_BIN="$STAGE_DIR/usr/sbin/nginx"
[ -x "$NGINX_BIN" ] || die "nginx binary not found at $NGINX_BIN after make install"

nginx_version="$("$NGINX_BIN" -v 2>&1)"
[ "$nginx_version" = "nginx version: nginx/$NGINX_VERSION" ] \
    || die "built binary reports '$nginx_version', expected nginx/$NGINX_VERSION"
log "Built binary: $nginx_version"


# 6. Work out Depends from the libraries the built binary loads.
#
#    Every library ldd reports must be in this table. An unknown library stops
#    the build so it can be reviewed and added, rather than guessed.

declare -A LIB_PACKAGE=(
    [libc.so.6]=libc6
    [ld-linux-aarch64.so.1]=libc6
    [ld-linux-x86-64.so.2]=libc6
    [libcrypt.so.1]=libcrypt1
    [libpcre2-8.so.0]=libpcre2-8-0
    [libssl.so.3]=libssl3
    [libcrypto.so.3]=libssl3
    [libz.so.1]=zlib1g
)

# Print the Debian package that owns a library file. With merged /usr the
# dpkg database may list the file under /lib or /usr/lib, so try both.
package_owning() {
    local path="$1"
    local resolved
    resolved="$(readlink -f "$path")"

    for candidate in "$path" "/usr$path" "${path#/usr}" "$resolved"; do
        if dpkg -S "$candidate" >/dev/null 2>&1; then
            dpkg -S "$candidate" | head -n1 | cut -d: -f1
            return 0
        fi
    done
    return 1
}

LDD_OUTPUT="$(ldd "$NGINX_BIN")" || die "ldd failed on $NGINX_BIN"
log "ldd $NGINX_BIN:"
echo "$LDD_OUTPUT"

if grep -q 'not found' <<<"$LDD_OUTPUT"; then
    die "built binary has unresolved libraries (see ldd output above)"
fi

depends_list=""
while read -r ldd_line; do
    # Lines look like "libz.so.1 => /lib/.../libz.so.1 (0x...)" or
    # "/lib/ld-linux-aarch64.so.1 (0x...)". The first word names the library.
    first_word="$(awk '{print $1}' <<<"$ldd_line")"
    lib_name="$(basename "$first_word")"

    # The vDSO is provided by the kernel, not a package.
    if [[ "$lib_name" == linux-vdso.so.* ]]; then
        continue
    fi

    package="${LIB_PACKAGE[$lib_name]:-}"
    [ -n "$package" ] \
        || die "ldd shows $lib_name, which has no Depends mapping; add it to LIB_PACKAGE after review"

    # Cross-check the table against the package that actually owns the file.
    if [[ "$ldd_line" == *"=>"* ]]; then
        lib_path="$(awk '{print $3}' <<<"$ldd_line")"
    else
        lib_path="$first_word"
    fi
    owner="$(package_owning "$lib_path")" \
        || die "no installed package owns $lib_path"
    owner="${owner%%:*}"
    [ "$owner" = "$package" ] \
        || die "$lib_name is owned by $owner, but LIB_PACKAGE maps it to $package"

    depends_list="$depends_list$package"$'\n'
done <<<"$LDD_OUTPUT"

depends_list="$(sort -u <<<"$depends_list" | sed '/^$/d')"

# Make sure every package name exists in the Debian archive.
for package in $depends_list; do
    apt-cache show "$package" >/dev/null 2>&1 \
        || die "apt-cache does not know package $package"
done

DEPENDS="$(tr '\n' ',' <<<"$depends_list" | sed 's/,$//; s/,/, /g')"
log "Depends: $DEPENDS"


# 7. Write the package control file.

ARCH="$(dpkg --print-architecture)"

mkdir -p "$STAGE_DIR/DEBIAN"
cat > "$STAGE_DIR/DEBIAN/control" <<EOF
Package: nginx
Version: $PKG_VERSION
Architecture: $ARCH
Maintainer: nginx-echo-drop-in build <root@localhost>
Depends: $DEPENDS
Section: httpd
Priority: optional
Homepage: https://nginx.org
Description: nginx $NGINX_VERSION with the CVE-2026-95101 HTTP/3 fix backported
 Built from the official nginx-$NGINX_VERSION release tarball with the same
 configure arguments as the nginx:1.25-bookworm image.
EOF


# 8. Build the .deb into the output directory.

if [ -d /out ]; then
    OUT_DIR="/out"
else
    repo_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
    OUT_DIR="${repo_dir%/}/out"
    mkdir -p "$OUT_DIR"
fi

DEB_FILE="$OUT_DIR/nginx_${PKG_VERSION}_${ARCH}.deb"

log "Building $DEB_FILE"
dpkg-deb --root-owner-group --build "$STAGE_DIR" "$DEB_FILE" \
    || die "dpkg-deb failed"

log "Package ready: $DEB_FILE"
