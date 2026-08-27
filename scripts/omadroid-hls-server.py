#!/usr/bin/env python3
"""Omadroid HLS server.

Serves the ffmpeg-generated HLS playlist/segments (or a live frame.png) from
LIVE_DIR over HTTP, bound to 127.0.0.1, with the correct MIME types.

Usage: omadroid-hls-server.py <port> <directory>
"""
import sys
import http.server
import socketserver

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8731
DIRECTORY = sys.argv[2] if len(sys.argv) > 2 else "."


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def guess_type(self, path):
        p = path.lower()
        if p.endswith(".m3u8"):
            return "application/vnd.apple.mpegurl"
        if p.endswith(".ts"):
            return "video/mp2t"
        return super().guess_type(path)

    def log_message(self, *args):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    Server(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
