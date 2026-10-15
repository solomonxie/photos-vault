#!/bin/sh
# Fails if any demo secret from .env.demo is compiled into a Release app.
# A release never gets demo defines; this catches it if one ever does.
#
# Usage: scripts/check-no-demo-secrets.sh <Runner.app>
set -e
cd "$(dirname "$0")/.."

APP_BIN="$1/Frameworks/App.framework/App"
[ -f .env.demo ] || exit 0
[ -f "$APP_BIN" ] || { echo "check-no-demo-secrets: no $APP_BIN" >&2; exit 1; }

for key in DEMO_S3_ACCESS_KEY_ID DEMO_S3_SECRET_ACCESS_KEY DEMO_S3_BUCKET DEMO_AI_API_KEY; do
  value=$(sed -n "s/^$key=//p" .env.demo | tail -n 1)
  [ -n "$value" ] || continue
  if grep -aqF -- "$value" "$APP_BIN"; then
    echo "" >&2
    echo "!!! $key from .env.demo is inside this Release build. Do not ship it." >&2
    echo "!!! Expire the build in App Store Connect if uploaded, and rotate the key." >&2
    exit 1
  fi
done
