#!/usr/bin/env python3
"""Omadroid I/O helper.

Descriptor-based, bounded file operations used by omadroid.sh:

  write <path>            read stdin (bounded), write atomically with fsync
  write-tmp <path> [--png-check]
                         read stdin (bounded), write to a random 0600 temp in
                         the same directory, fsync; optionally verify a PNG
                         signature before publication. Print the temp path.
  read <path> <maxbytes> open with O_NOFOLLOW, read at most maxbytes, print.
"""
import os
import sys
import tempfile

MAX_READ = 1 << 26  # 64 MiB hard cap on any single read/write


def _write_all(fd, data):
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]


def write_atomic(path, data):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp.", suffix=".tmp")
    try:
        os.chmod(fd, 0o600)
        _write_all(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.rename(tmp, path)


def write_tmp(path, png_check):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".p.", suffix=".tmp")
    try:
        os.chmod(fd, 0o600)
        data = sys.stdin.buffer.read(MAX_READ)
        _write_all(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    if png_check:
        with open(tmp, "rb") as f:
            sig = f.read(8)
        if sig != b"\x89PNG\r\n\x1a\n":
            os.unlink(tmp)
            sys.exit(2)
    sys.stdout.write(tmp)


def read_bounded(path, maxbytes):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        buf = b""
        while len(buf) < maxbytes:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            buf += chunk
        return buf
    finally:
        os.close(fd)


def main():
    if len(sys.argv) < 3:
        sys.exit(1)
    op = sys.argv[1]
    if op == "write":
        path = sys.argv[2]
        data = sys.stdin.buffer.read(MAX_READ)
        write_atomic(path, data)
    elif op == "write-tmp":
        path = sys.argv[2]
        png = "--png-check" in sys.argv[3:]
        write_tmp(path, png)
    elif op == "read":
        path = sys.argv[2]
        maxb = int(sys.argv[3]) if len(sys.argv) > 3 else 65536
        sys.stdout.buffer.write(read_bounded(path, maxb))
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
