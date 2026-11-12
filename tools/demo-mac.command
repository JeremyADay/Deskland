#!/bin/sh
# Double-click in Finder, or run tools/demo-mac.command [meadow|beach].
set -eu
cd "$(dirname "$0")/.."
theme=${1:-meadow}
case "$theme" in meadow|beach) ;; *) echo "usage: $0 [meadow|beach]" >&2; exit 2 ;; esac
app=".capture/dist/Deskland Preview.app"
if [ ! -x "$app/Contents/MacOS/Deskland" ]; then
  tools/make-mac.sh
fi
exec open -n "$app" --args --demo "$theme"
