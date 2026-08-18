#!/usr/bin/env python3
"""Build committed macOS .icns and Windows .ico files from the master PNG."""

from __future__ import annotations

import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "assets" / "agent-halo-app-icon.png"
ICNS = ROOT / "assets" / "agent-halo-app-icon.icns"
ICO = ROOT / "assets" / "agent-halo-app-icon.ico"

ICONSET_SIZES = (
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
)
ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)


def require_master() -> None:
    if not MASTER.is_file():
        raise SystemExit(f"Missing master icon: {MASTER}")


def resize_png(src: Path, dest: Path, size: int) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if src.resolve() != dest.resolve():
        shutil.copy2(src, dest)
    subprocess.run(
        ["sips", "-z", str(size), str(size), str(dest)],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def write_icns() -> None:
    sips = shutil.which("sips")
    iconutil = shutil.which("iconutil")
    if not sips or not iconutil:
        raise SystemExit("sips and iconutil are required to build AppIcon.icns")

    with tempfile.TemporaryDirectory(prefix="agent-halo-iconset-") as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for size, name in ICONSET_SIZES:
            resize_png(MASTER, iconset / name, size)
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)],
            check=True,
        )
    print(f"Wrote {ICNS.relative_to(ROOT)}")


def write_ico() -> None:
    sips = shutil.which("sips")
    if not sips:
        raise SystemExit("sips is required to resize PNG frames for the .ico")

    with tempfile.TemporaryDirectory(prefix="agent-halo-ico-") as tmp:
        frames: list[bytes] = []
        tmp_root = Path(tmp)
        for size in ICO_SIZES:
            frame = tmp_root / f"icon-{size}.png"
            resize_png(MASTER, frame, size)
            frames.append(frame.read_bytes())

    count = len(frames)
    offset = 6 + 16 * count
    chunks = [struct.pack("<HHH", 0, 1, count)]
    data = bytearray()
    for size, payload in zip(ICO_SIZES, frames):
        width = 0 if size >= 256 else size
        height = 0 if size >= 256 else size
        chunks.append(struct.pack("<BBBBHHII", width, height, 0, 0, 1, 32, len(payload), offset))
        data.extend(payload)
        offset += len(payload)
    ICO.write_bytes(b"".join(chunks) + data)
    print(f"Wrote {ICO.relative_to(ROOT)}")


def main() -> int:
    require_master()
    write_icns()
    write_ico()
    return 0


if __name__ == "__main__":
    sys.exit(main())
