#!/bin/sh
# Clones the Flutter stable SDK into .tools/ (project-scoped, no system install)
# and runs `flutter pub get`.
set -e
cd "$(dirname "$0")/.."

FLUTTER_BIN=.tools/flutter/bin/flutter

if [ ! -x "$FLUTTER_BIN" ]; then
    echo "Cloning Flutter stable SDK locally..."
    git clone --depth 1 -b stable https://github.com/flutter/flutter.git .tools/flutter
fi

"$FLUTTER_BIN" pub get
echo "Run with: $FLUTTER_BIN run"
