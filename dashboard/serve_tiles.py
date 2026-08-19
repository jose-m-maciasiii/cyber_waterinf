"""Serve the local PMTiles archive with byte-range and CORS support."""

from __future__ import annotations

import argparse
import gzip
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from pmtiles.reader import MmapSource, Reader


DEFAULT_TILE_PATH = Path(__file__).resolve().parent / "data" / "water_infrastructure.pmtiles"


class PMTilesHandler(BaseHTTPRequestHandler):
    tile_path: Path = DEFAULT_TILE_PATH
    tile_file = None
    tile_reader: Reader | None = None

    def _send_headers(self, status: int, start: int, end: int, size: int) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/vnd.pmtiles")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Range")
        self.send_header("Access-Control-Expose-Headers", "Content-Range, Accept-Ranges")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Range")
        self.end_headers()

    def do_HEAD(self) -> None:  # noqa: N802
        if self.path != "/water_infrastructure.pmtiles":
            self.send_error(404)
            return
        size = self.tile_path.stat().st_size
        self._send_headers(200, 0, size - 1, size)

    def do_GET(self) -> None:  # noqa: N802
        tile_match = re.fullmatch(r"/tiles/(\d+)/(\d+)/(\d+)\.mvt", self.path)
        if tile_match:
            z, x, y = (int(value) for value in tile_match.groups())
            tile = self.tile_reader.get(z, x, y) if self.tile_reader else None
            if tile is None:
                self.send_error(404)
                return
            tile = gzip.decompress(tile)
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.mapbox-vector-tile")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cache-Control", "public, max-age=3600")
            self.send_header("Content-Length", str(len(tile)))
            self.end_headers()
            self.wfile.write(tile)
            return
        if self.path != "/water_infrastructure.pmtiles":
            self.send_error(404)
            return
        size = self.tile_path.stat().st_size
        start, end, status = 0, size - 1, 200
        range_header = self.headers.get("Range")
        if range_header and range_header.startswith("bytes="):
            requested = range_header.removeprefix("bytes=").split(",", 1)[0]
            start_text, end_text = requested.split("-", 1)
            start = int(start_text) if start_text else 0
            end = int(end_text) if end_text else size - 1
            end = min(end, size - 1)
            if start > end or start >= size:
                self.send_error(416)
                return
            status = 206
        self._send_headers(status, start, end, size)
        with self.tile_path.open("rb") as tile_file:
            tile_file.seek(start)
            remaining = end - start + 1
            while remaining:
                chunk = tile_file.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8001)
    parser.add_argument("--file", type=Path, default=DEFAULT_TILE_PATH)
    args = parser.parse_args()
    tile_path = args.file.resolve()
    if not tile_path.exists():
        raise FileNotFoundError(tile_path)
    PMTilesHandler.tile_path = tile_path
    PMTilesHandler.tile_file = tile_path.open("rb")
    PMTilesHandler.tile_reader = Reader(MmapSource(PMTilesHandler.tile_file))
    server = ThreadingHTTPServer((args.host, args.port), PMTilesHandler)
    print(f"Serving {tile_path} at http://{args.host}:{args.port}/water_infrastructure.pmtiles")
    print(f"Vector tiles: http://{args.host}:{args.port}/tiles/{{z}}/{{x}}/{{y}}.mvt")
    server.serve_forever()


if __name__ == "__main__":
    main()
