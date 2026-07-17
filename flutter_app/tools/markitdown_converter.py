#!/usr/bin/env python3
"""Convert one trusted local PDF to Markdown for ArxivReader AI."""

from __future__ import annotations

import argparse
import mimetypes
import sys
from pathlib import Path

# macOS app sandboxing can deny reads from system MIME databases such as
# /etc/apache2/mime.types. MarkItDown only needs enough MIME knowledge to route
# a trusted local PDF, so use Python's built-in table and skip external files.
mimetypes.knownfiles = []
mimetypes.init(files=[])

from markitdown import MarkItDown


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_pdf", type=Path)
    parser.add_argument("output_markdown", type=Path)
    args = parser.parse_args()

    if not args.input_pdf.is_file():
        raise FileNotFoundError(f"PDF not found: {args.input_pdf}")

    result = MarkItDown(enable_plugins=False).convert_local(args.input_pdf)
    args.output_markdown.parent.mkdir(parents=True, exist_ok=True)
    args.output_markdown.write_text(result.text_content, encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # Keep Flutter's subprocess error concise.
        print(f"MarkItDown conversion failed: {error}", file=sys.stderr)
        raise SystemExit(1)
