#!/bin/sh
# disktree from a terminal: runs the app `make install` put in @APPDIR@.
#
# The binary inside the bundle, not `open -a disktree`: this way the terminal
# keeps the output and the exit status, `--help` prints here, and a relative
# path means what it says. `open` would start the app from / with no terminal
# attached and return at once. The bundle around the binary still gives the
# window its icon and its name.
app="@APPDIR@/disktree.app"
if [ ! -x "$app/Contents/MacOS/disktree" ]; then
    echo "disktree: $app is gone; run make install again" >&2
    exit 127
fi
exec "$app/Contents/MacOS/disktree" "$@"
