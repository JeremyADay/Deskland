#!/bin/sh
# Run the native wallpaper with a staged copy of this checkout's shared theme pages.
# Quit an existing wallpaper first; its single-instance guard prevents duplicate hosts.
set -eu
cd "$(dirname "$0")/.."
app="$PWD/.capture/dist/Deskland Preview.app"
if [ ! -x "$app/Contents/MacOS/Deskland" ]; then
  tools/make-mac.sh
fi
# Import only the project's assets into the app's data folder. The host need not read
# the source checkout, which may live inside macOS's protected Documents folder.
pages="$HOME/Library/Application Support/app.deskland.preview.mac/development-pages"
mkdir -p "$pages"
ditto "$PWD/prototype" "$pages"
exec open -n --env "DESKLAND_PAGES=$pages" "$app"
