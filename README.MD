# nginx-echo: nginx 1.25.5 rebuilt from source, with two CVE remediations

This repo builds a backported nginx 1.25.5 `.deb` from upstream source inside `debian:bookworm-slim`, packages a patched `libpcre2-8-0` next to it, and installs both into a final image.

## CVE's I chose

I took my time to search for meaningfull CVE's that has real risk in them. Took some time because a lot of the CVE's were either not fixed or not really related to version 1.25 according to the official websites.

1. **CVE-2026-95101-nginx** - Medium severity
2. **CVE-2026-86145-libpcre2** - High severity (NOTE: this CVE is not effecting nginx because nginx does not use the functions specified)


## Build instructions

Requirements: Docker, `make`, and about 2 GB of free disk for the builder.

```sh
make deb          # produces the .deb packages
make all          # buildes the final dropin image
make test         # runs test/test_compare.py against nginx:1.25-bookworm
```

Step by step:

1. `make image` builds `nginx-builder` from `build/Dockerfile.builder`.
2. `make build-pcre2` runs `build/build-pcre2.sh` in the builder. It downloads pcre2 10.49, checks the sha256, builds with `--enable-jit`, runs `make check`, and packages `out/libpcre2-8-0_10.49-1~echo1_<arch>.deb`.
3. `make deb` runs `build/build-nginx.sh` in the builder. It downloads nginx 1.25.5, checks the sha256, applies `build/patches/nginx-1.25.5-CVE-2026-95101.patch` with `git apply`, configures with the same arguments as the official image (`nginx -V`), builds, strips the binary, and packages `out/nginx_1.25.5-1~echo1_<arch>.deb`. `Depends` is fixed to the library versions the binary links against.
4. `make final-image` builds `Containerfile` (debian:bookworm-slim) and installs both `.deb` files.
5. `make test` starts the final image and the reference image and compares HTTP responses case by case.

Output for the final image: `nginx-echo`.

## What "working correctly" means

The patched image works correctly when It behaves like the reference image over HTTP. For each test case, `nginx-echo` and `nginx:1.25-bookworm` return the same status line, the same headers, and the same body.

## What the test covers

`test/test_compare.py` starts each image in a container, sends the same raw HTTP requests to both, and compares the responses. Exit codes: 0 = all match, 1 = a mismatch, 2 = a setup error (for example a container that does not start within 30 seconds).

Default config cases (`False`):

| Case | Request | Expected | What it checks |
|---|---|---|---|
| root | `GET /` | 200 | The default page is served at all. |
| head root | `HEAD /` | 200 | HEAD returns the same status and headers without a body. |
| not found | `GET /does-not-exist` | 404 | Missing files get the same 404 response. |
| small POST | `POST /` with body `hello` | 405 | The static server rejects POST with the same status. |
| 2 MiB POST | `POST /` with a 2 MiB body | 413 | The body-size limit is enforced the same way. |
| garbage request line | `\x01GARBAGE` | 400 | Invalid request lines are rejected the same way. |
| HTTP/1.1 without Host | `GET /` with no `Host` header | 400 | A missing `Host` header on HTTP/1.1 is rejected. |
| NUL in URI | `GET /a\x00b` | 400 | A NUL byte in the path is rejected. |
| path traversal | `GET /../../etc/passwd` | 400 | Path traversal is blocked the same way. |

Custom config cases (`True`, the same `nginx-test.conf` mounted into both images):

| Case | Request | Expected | What it checks |
|---|---|---|---|
| regex location | `GET /regex/12345` | 200 | A regex `location` block matches and is served. |
| return 204 | `GET /no-content` | 204 | A `return` directive produces the status with no body. |
| rewrite | `GET /old/page` | 301 | A `rewrite` rule produces a redirect. |


## Image size: original vs. new

Measured with `docker images` (Docker Desktop, arm64):

| Image | Disk usage | Content size (compressed) |
|---|---|---|
| `nginx:1.25-bookworm` (original) | 278 MB | 70.6 MB |
| `nginx-echo` (new) | 160 MB | 35.3 MB |

Change: disk usage down about 42%, content size down about 50%.

## CVE results

Scanner totals, from the attached reports (Trivy totals line, which is authoritative for Trivy; Grype counts are rows by severity):

| | Before (`nginx:1.25-bookworm`) | After (`nginx-echo`) |
|---|---|---|
| Trivy total | 833 (C 21, H 189, M 321, L 263, U 39) | 347 (C 1, H 70, M 122, L 152, U 2) |
| Grype rows (approx.) | about 540 (H 274, M 183, C 50, N 28, L 21, U 22) | about 210 (H 91, M 53, C 17, N 25, L 3, U 22) |

The before/after comparison mixes two things: the libraries we patched, and the base OS packages we did not touch (curl, glibc, perl, ncurses and others, many marked "won't fix" by Debian). Most of the drop is the base image, not my work. The table below covers only the CVEs my changes are about, plus the nginx ones we had to decide on.

### Per-CVE table

| ID | Severity | Component | Fix method | Evidence |
|---|---|---|---|---|
| CVE-2026-95101 | Medium (Grype), in Trivy as Medium | nginx 1.25.5 (HTTP/3 request data injection) | **backport** | `https://my.f5.com/manage/s/article/K000162613` |
| CVE-2026-103111 | High | libpcre2-8-0 10.42 (JIT stack out-of-bounds write) | **bump** to 10.49 | `https://github.com/PCRE2Project/pcre2/security/advisories/GHSA-r9hj-j2rw-4q3m` |
| CVE-2026-89156 | Medium | libpcre2 (JIT fallback read) | **bump** to 10.49 (fixed in 10.48) | `https://github.com/PCRE2Project/pcre2/security/advisories/GHSA-2p8c-ff85-vh9x` |
| CVE-2026-89160, -89161, -89157, -89158, and other libpcre2 rows in Grype | Medium / High | libpcre2 | **bump** to 10.49 | `https://github.com/PCRE2Project/pcre2/security/advisories/GHSA-9qww-pwc4-77qq` |


## Residual risk assessment

1. **nginx code we have not reviewed.** The scanner still reports several nginx CVEs (Critical and High) that i have not read or checked because of limited time. Next: review each advisory against the affected module in `src/`, then backport, bump, or document it as not affected in the VEX file.
2. **Base image packages.** Most of the remaining scanner count comes from Debian bookworm packages (curl, glibc, zlib, perl, and others), many marked "won't fix" by Debian. Why: they belong to the base image, and we did not rebuild them. Next: decide whether to rebuild them too, or move to a base image that Debian patches faster.

## What I would do differently

If i had more time i would improve the ways to verify that the two images are exactly the same. maybe make the code more fittible for other nginx images versions and not just 1.25-bookworm