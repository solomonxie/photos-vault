"""python3 tools/chats/run.py <imessage|whatsapp|messenger|instagram> ... -> work/<source>.jsonl"""

import argparse
from pathlib import Path

import rows

WORK = Path(__file__).parent / "work"


def main():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--out", type=Path)
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("imessage", parents=[common])
    w = sub.add_parser("whatsapp", parents=[common])
    w.add_argument("--backup", nargs="?", const="latest", help="iPhone backup folder (default: newest)")
    w.add_argument("--exports", type=Path, help="Export Chat .txt/.zip, or a folder of them")
    w.add_argument("--me", help="your name as WhatsApp shows it")
    for name in ("messenger", "instagram"):
        m = sub.add_parser(name, parents=[common])
        m.add_argument("paths", nargs="+", type=Path, help="download zips or unzipped folders")
        m.add_argument("--me", help="your name as it appears in the export")
    a = p.parse_args()

    if a.cmd == "imessage":
        import imessage
        out = imessage.extract()
    elif a.cmd == "whatsapp":
        import whatsapp
        if a.exports:
            out = whatsapp.from_exports(a.exports, a.me)
        else:
            out = whatsapp.from_backup(None if a.backup in (None, "latest") else Path(a.backup))
    else:
        import meta
        out = meta.extract(a.paths, a.cmd, a.me)
    rows.write(out, a.out or WORK / f"{a.cmd}.jsonl")


if __name__ == "__main__":
    main()
