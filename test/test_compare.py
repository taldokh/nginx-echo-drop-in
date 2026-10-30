import argparse
import socket
import subprocess
import sys
import time
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
CUSTOM_MOUNTS = [
    "-v", f"{TEST_DIR / 'nginx-test.conf'}:/etc/nginx/nginx.conf:ro",
    "-v", f"{TEST_DIR / 'html'}:/usr/share/nginx/test:ro",
]

# Headers left out of the comparison, each with the reason.
EXCLUDED_HEADERS = {
    "date": "the time of the response",
    "last-modified": "default page mtime comes from each package's build date",
    "etag": "derived from the default page mtime",
}
DEFAULT_PAGE_ONLY = {"last-modified", "etag"}  # still compared for custom config


def req(line, headers="Host: localhost\r\n", body=b""):
    if body:
        headers += f"Content-Length: {len(body)}\r\n"
    return f"{line}\r\n{headers}Connection: close\r\n\r\n".encode() + body


# (name, custom config?, request bytes, expected status)
CASES = [
    ("root", False, req("GET / HTTP/1.1"), 200),
    ("head root", False, req("HEAD / HTTP/1.1"), 200),
    ("not found", False, req("GET /does-not-exist HTTP/1.1"), 404),
    ("small POST", False, req("POST / HTTP/1.1", body=b"hello"), 405),
    ("2 MiB POST", False, req("POST / HTTP/1.1", body=b"x" * 2 * 1024 * 1024), 413),
    ("garbage request line", False, b"\x01GARBAGE\r\n\r\n", 400),
    ("HTTP/1.1 without Host", False, req("GET / HTTP/1.1", headers=""), 400),
    ("NUL in URI", False, req("GET /a\x00b HTTP/1.1"), 400),
    ("path traversal", False, req("GET /../../etc/passwd HTTP/1.1"), 400),
    ("regex location", True, req("GET /regex/12345 HTTP/1.1"), 200),
    ("return 204", True, req("GET /no-content HTTP/1.1"), 204),
    ("rewrite", True, req("GET /old/page HTTP/1.1"), 301),
]


def start(image, custom):
    mounts = CUSTOM_MOUNTS if custom else []
    cid = subprocess.run(["docker", "run", "-d", "-p", "127.0.0.1::80", *mounts, image],
                         capture_output=True, text=True, check=True).stdout.strip()
    port = subprocess.run(["docker", "port", cid, "80/tcp"], capture_output=True,
                          text=True, check=True).stdout.split(":")[-1].strip()
    return cid, int(port)


def send(port, data):
    """Send raw bytes; read until the server closes or 10 seconds pass."""
    chunks = []
    with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
        try:
            sock.sendall(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # nginx may reply (e.g. 413) before reading the whole body
        try:
            while chunk := sock.recv(65536):
                chunks.append(chunk)
        except (socket.timeout, ConnectionResetError):
            pass
    return b"".join(chunks)


def wait_ready(port):
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            if send(port, req("GET / HTTP/1.1")).startswith(b"HTTP/1.1 200"):
                return
        except OSError:
            pass
        time.sleep(0.5)
    raise RuntimeError(f"no 200 for GET / on port {port} within 30 seconds")


def parse(raw, custom):
    head, _, body = raw.partition(b"\r\n\r\n")
    status, *lines = head.decode("latin-1").split("\r\n")
    excluded = set(EXCLUDED_HEADERS) - (DEFAULT_PAGE_ONLY if custom else set())
    headers = [h for h in lines if h.split(":", 1)[0].strip().lower() not in excluded]
    return status, headers, body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--original", required=True)
    ap.add_argument("--candidate", required=True)
    args = ap.parse_args()

    containers, ports = [], {}
    try:
        try:
            for image in (args.original, args.candidate):
                for custom in (False, True):
                    cid, port = start(image, custom)
                    containers.append(cid)
                    wait_ready(port)
                    ports[image, custom] = port
        except (subprocess.CalledProcessError, RuntimeError) as e:
            print(f"ERROR: container failed to start: {getattr(e, 'stderr', None) or e}")
            return 2

        failures = 0
        for name, custom, data, expected in CASES:
            orig = parse(send(ports[args.original, custom], data), custom)
            cand = parse(send(ports[args.candidate, custom], data), custom)
            problems = [f"{part} differs:\n    original:  {o!r}\n    candidate: {c!r}"
                        for part, o, c in zip(("status", "headers", "body"), orig, cand)
                        if o != c]
            if not orig[0].startswith(f"HTTP/1.1 {expected}"):
                problems.append(f"original returned {orig[0]!r}, expected {expected}")
            print(f"{'FAIL' if problems else 'ok  '}  {name}: {cand[0]}")
            for p in problems:
                print("      " + p)
            failures += bool(problems)

        print(f"\n{len(CASES) - failures}/{len(CASES)} cases match")
        return 1 if failures else 0
    finally:
        if containers:
            subprocess.run(["docker", "rm", "-f", *containers], capture_output=True)


if __name__ == "__main__":
    sys.exit(main())
