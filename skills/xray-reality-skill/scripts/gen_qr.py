#!/usr/bin/env python3
"""Render a share link as a QR code (PNG + terminal ASCII).

Usage:
    gen_qr.py --link-file node.link [-o out.png]
    gen_qr.py "vless://..." [-o out.png]
    gen_qr.py --link-file node.link --ascii-only

Needs: pip install "qrcode[pil]"
"""

import argparse
import re
import sys
from pathlib import Path

LINK_RE = re.compile(r"(?:vless|vmess|trojan|ss)://[^\s`\"']+")


def read_link(args) -> str:
    if args.link_file:
        text = Path(args.link_file).read_text(encoding="utf-8")
        match = LINK_RE.search(text)
        if not match:
            raise SystemExit(f"no share link found in {args.link_file}")
        return match.group(0)
    if args.link:
        return args.link.strip()
    raise SystemExit("provide a link or --link-file")


def main() -> int:
    p = argparse.ArgumentParser(description="Share link -> QR code")
    p.add_argument("link", nargs="?", help="share link")
    p.add_argument("--link-file", type=Path, help="file containing the link")
    p.add_argument("-o", "--output", type=Path, default=Path("qr.png"))
    p.add_argument("--ascii-only", action="store_true", help="do not write a PNG")
    args = p.parse_args()

    link = read_link(args)

    try:
        import qrcode
    except ImportError:
        raise SystemExit('missing dependency - run: pip install "qrcode[pil]"')

    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=10, border=3)
    qr.add_data(link)
    qr.make(fit=True)

    qr.print_ascii(invert=True)

    if not args.ascii_only:
        qr.make_image(fill_color="black", back_color="white").save(args.output)
        print(f"\nwrote {args.output}")

    print(f"link: {link}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
