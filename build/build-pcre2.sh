#!/usr/bin/env bash
#
# Download the PCRE2 10.49 release tarball, verify its SHA-256, build the
# shared 8-bit library, run its test suite, and package the result as a
# libpcre2-8-0 .deb.
#
# Meant to run inside the builder image (build/Dockerfile.Builder). The .deb
# is written to /out if that directory exists, otherwise to <repo>/out.
#
# Requires: curl, tar, sha256sum, a C toolchain, dpkg-architecture, readelf,
# dpkg-deb.

set -euo pipefail

PCRE2_VERSION="10.49"
PCRE2_TARBALL="pcre2-$PCRE2_VERSION.tar.gz"
PCRE2_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/$PCRE2_TARBALL"

# SHA-256 of pcre2-10.49.tar.gz from the official release page:
#   https://github.com/PCRE2Project/pcre2/releases/tag/pcre2-10.49
PCRE2_SHA256="929f0b20e62879252a15886b06c89f1edef61a363cbd5826fb041080a5e557ae"

PKG_VERSION="10.49-1~echo1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="$SCRIPT_DIR/$PCRE2_TARBALL"
SRC_DIR="$SCRIPT_DIR/pcre2-$PCRE2_VERSION"

die() { echo "build-pcre2.sh: error: $*" >&2; exit 1; }
log() { echo "==> $*"; }


# 1. Download the release tarball and verify its checksum.

sha256_of() {
    sha256sum "$1" | cut -d' ' -f1
}

if [ -f "$TARBALL" ] && [ "$(sha256_of "$TARBALL")" = "$PCRE2_SHA256" ]; then
    log "Reusing verified $TARBALL"
else
    log "Downloading $PCRE2_URL"
    curl -fsSL -o "$TARBALL.part" "$PCRE2_URL" \
        || die "download failed: $PCRE2_URL"
    actual="$(sha256_of "$TARBALL.part")"
    if [ "$actual" != "$PCRE2_SHA256" ]; then
        rm -f "$TARBALL.part"
        die "SHA-256 mismatch for $PCRE2_TARBALL: expected $PCRE2_SHA256, got $actual"
    fi
    mv "$TARBALL.part" "$TARBALL"
fi
log "SHA-256 OK: $PCRE2_SHA256"


# 2. Extract into a fresh directory.

log "Extracting into $SRC_DIR"
rm -rf "$SRC_DIR"
tar -xzf "$TARBALL" -C "$SCRIPT_DIR"

cd "$SRC_DIR"


# 3. Configure the shared 8-bit library with JIT, installed into Debian's
#    multiarch library directory.

MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)" \
    || die "dpkg-architecture failed"
LIBDIR="/usr/lib/$MULTIARCH"

log "Configuring (libdir $LIBDIR)"
./configure \
    --prefix=/usr \
    --libdir="$LIBDIR" \
    --enable-jit \
    --enable-pcre2-8 \
    || die "configure failed (see $SRC_DIR/config.log)"


# 4. Build and run the test suite.

log "Building (make -j$(nproc))"
make -j"$(nproc)" || die "make failed"

log "Running test suite (make check)"
make check || die "make check failed (see $SRC_DIR/test-suite.log)"


# 5. Install into a temporary staging directory.

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
chmod 0755 "$STAGE_DIR"

log "Installing into staging directory $STAGE_DIR"
make install DESTDIR="$STAGE_DIR" || die "make install failed"


# 6. Check the shared library's SONAME.

EXPECTED_SONAME="libpcre2-8.so.0"
LIBRARY="$STAGE_DIR$LIBDIR/$EXPECTED_SONAME"
[ -e "$LIBRARY" ] || die "shared library not found at $LIBRARY"

soname="$(readelf -d "$LIBRARY" | sed -n 's/.*Library soname: \[\(.*\)\].*/\1/p')"
[ "$soname" = "$EXPECTED_SONAME" ] \
    || die "SONAME of $LIBRARY is '$soname', expected $EXPECTED_SONAME"
log "SONAME OK: $soname"


# 7. Write the package control file.

ARCH="$(dpkg --print-architecture)"

mkdir -p "$STAGE_DIR/DEBIAN"
cat > "$STAGE_DIR/DEBIAN/control" <<EOF
Package: libpcre2-8-0
Version: $PKG_VERSION
Architecture: $ARCH
Maintainer: nginx-echo-drop-in build <root@localhost>
Depends: libc6 (>= 2.34)
Section: libs
Priority: optional
Homepage: https://github.com/PCRE2Project/pcre2
Description: PCRE2 $PCRE2_VERSION 8-bit runtime library built from upstream source
EOF


# 8. Build the .deb into the output directory.

if [ -d /out ]; then
    OUT_DIR="/out"
else
    repo_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
    OUT_DIR="${repo_dir%/}/out"
    mkdir -p "$OUT_DIR"
fi

DEB_FILE="$OUT_DIR/libpcre2-8-0_${PKG_VERSION}_${ARCH}.deb"

log "Building $DEB_FILE"
dpkg-deb --root-owner-group --build "$STAGE_DIR" "$DEB_FILE" \
    || die "dpkg-deb failed"

log "Package ready: $DEB_FILE"
