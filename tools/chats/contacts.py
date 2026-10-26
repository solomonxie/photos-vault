"""Phone/email -> name from the Mac's Contacts databases (needs Full Disk Access)."""

import re
import sqlite3
from pathlib import Path

ROOT = Path.home() / "Library/Application Support/AddressBook"


def _cjk(s):
    return any("一" <= c <= "鿿" for c in s)


def display_name(first, last, nick, org):
    first, last = (first or "").strip(), (last or "").strip()
    if first or last:
        if _cjk(first + last):
            return last + first
        return " ".join(x for x in (first, last) if x)
    return (nick or org or "").strip()


def phone_key(s):
    digits = re.sub(r"\D", "", s or "")
    return digits[-10:] if len(digits) >= 10 else digits


def handle_key(handle):
    h = (handle or "").strip().lower()
    return h if "@" in h else phone_key(h)


class Contacts:
    def __init__(self):
        self.by_key = {}
        dbs = sorted(ROOT.glob("Sources/*/AddressBook-v22.abcddb"))
        dbs.append(ROOT / "AddressBook-v22.abcddb")
        for db in dbs:
            try:
                self._load(db)
            except sqlite3.Error:
                pass

    def _load(self, db):
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        names = {
            pk: display_name(*rest)
            for pk, *rest in con.execute(
                "SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZNICKNAME, ZORGANIZATION FROM ZABCDRECORD"
            )
        }
        for owner, number in con.execute("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER"):
            if names.get(owner) and phone_key(number):
                self.by_key.setdefault(phone_key(number), names[owner])
        for owner, address in con.execute("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS"):
            if names.get(owner) and address:
                self.by_key.setdefault(address.strip().lower(), names[owner])
        con.close()

    def name(self, handle):
        return self.by_key.get(handle_key(handle))
