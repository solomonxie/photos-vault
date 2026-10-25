"""tools/faces/venv/bin/python tools/faces/run.py <analyse|phone|cluster|review|export> ..."""

import argparse
import sys


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("analyse")
    a.add_argument("--limit", type=int)
    a.add_argument("--refresh", action="store_true", help="fetch the newest snapshot first")
    ph = sub.add_parser("phone", help="names given on the phone, as labels")
    ph.add_argument("--db", required=True, help="copy of the app's ai_analysis.db")
    ph.add_argument("--people", required=True, help="copy of the app's people.db")
    sub.add_parser("cluster")
    r = sub.add_parser("review")
    r.add_argument("--port", type=int, default=8765)
    e = sub.add_parser("export")
    e.add_argument("--out", default="faces.json")
    e.add_argument("--prev", help="the last faces.json imported: its group IDs are kept")
    args = p.parse_args()

    if args.cmd == "analyse":
        import analyse
        import library
        if args.refresh:
            library.snapshot(refresh=True)
        analyse.run(args.limit)
    elif args.cmd == "phone":
        import phone
        phone.run(args.db, args.people)
    elif args.cmd == "cluster":
        import cluster
        cluster.run()
    elif args.cmd == "review":
        import review
        review.serve(args.port)
    elif args.cmd == "export":
        import export
        export.run(args.out, args.prev)


if __name__ == "__main__":
    sys.exit(main())
