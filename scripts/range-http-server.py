#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class RangeRequestHandler(SimpleHTTPRequestHandler):
    range_start: int | None = None
    range_end: int | None = None

    def end_headers(self) -> None:
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        if not os.path.exists(path):
            self.send_error(404, "File not found")
            return None

        file_handle = open(path, "rb")
        file_size = os.fstat(file_handle.fileno()).st_size
        start, end = self._parse_range(file_size)
        if start is None or end is None:
            self.send_response(200)
            self.send_header("Content-type", self.guess_type(path))
            self.send_header("Content-Length", str(file_size))
            self.send_header("Last-Modified", self.date_time_string(os.path.getmtime(path)))
            self.end_headers()
            self.range_start = None
            self.range_end = None
            return file_handle

        if start >= file_size or end < start:
            file_handle.close()
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{file_size}")
            self.end_headers()
            return None

        end = min(end, file_size - 1)
        file_handle.seek(start)
        self.range_start = start
        self.range_end = end
        self.send_response(206)
        self.send_header("Content-type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Last-Modified", self.date_time_string(os.path.getmtime(path)))
        self.end_headers()
        return file_handle

    def copyfile(self, source, outputfile) -> None:
        if self.range_start is None or self.range_end is None:
            return super().copyfile(source, outputfile)

        remaining = self.range_end - self.range_start + 1
        while remaining > 0:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)

    def _parse_range(self, file_size: int) -> tuple[int | None, int | None]:
        header = self.headers.get("Range")
        if not header:
            return None, None

        match = re.fullmatch(r"bytes=(\d*)-(\d*)", header.strip())
        if not match:
            return None, None

        start_text, end_text = match.groups()
        if not start_text and not end_text:
            return None, None
        if not start_text:
            suffix_length = int(end_text)
            return max(0, file_size - suffix_length), file_size - 1

        start = int(start_text)
        end = int(end_text) if end_text else file_size - 1
        return start, end


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve files with HTTP Range support.")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--directory", default=os.getcwd())
    args = parser.parse_args()

    handler = partial(RangeRequestHandler, directory=args.directory)
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    print(f"Serving {args.directory} on http://{args.bind}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
