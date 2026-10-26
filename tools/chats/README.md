# Chat history from the Mac

Turns chat exports into `.jsonl` for the app (More → Developer Options → Import Chat History).
Format: `docs/design/people-zip-import/DESIGN.md` → Conversations. One-to-one chats only; groups are skipped.
Standard library only, no venv needed. Output goes to `tools/chats/work/<source>.jsonl` (gitignored).

## Run
```
python3 tools/chats/run.py imessage                          # ~/Library/Messages/chat.db
python3 tools/chats/run.py whatsapp                          # newest iPhone backup on this Mac
python3 tools/chats/run.py whatsapp --exports <dir|zip|txt>  # per-chat "Export Chat" files
python3 tools/chats/run.py messenger <zip|dir>... [--me "Name"]
python3 tools/chats/run.py instagram <zip|dir>... [--me "Name"]
```
`--out <file>` overrides the output path.

## Sources
- **iMessage**: the terminal needs Full Disk Access (Privacy & Security). Names come from Contacts by
  phone/email; numbers not in Contacts are kept as the number. SMS/RCS threads become source `sms`.
- **WhatsApp**: backup via Finder, **unencrypted**. Exports: file name `WhatsApp Chat - <Name>` names
  the person; date order (day/month) is guessed per file.
- **Messenger / Instagram**: Accounts Center → Download your information → Messages, JSON, all time.
  Pass every part zip; threads split across them are merged. Meta's Latin-1 mojibake is repaired.
  "You" is the name in the most threads unless `--me` is given. E2EE Messenger chats are often missing
  from this download.
