#!/bin/sh
# disktree from a terminal, through a link to this file.
#
# Shipped inside the app at Contents/Resources/disktree, for Homebrew's cask
# (and anything else) to link onto PATH. It finds the bundle it lives in by
# following the link back to itself, then runs the app's own binary there.
# Linking to Contents/MacOS/disktree directly would start the app without
# its bundle: no identity, so no settings, no icon and no privacy grants.
self=$0
while [ -L "$self" ]; do
    link=$(readlink "$self")
    case $link in
        /*) self=$link ;;
        *) self=$(dirname "$self")/$link ;;
    esac
done
exec "$(cd "$(dirname "$self")/.." && pwd -P)/MacOS/disktree" "$@"
