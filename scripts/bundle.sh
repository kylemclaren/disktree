#!/bin/sh
# Assemble disktree.app around a built binary, and sign it.
#
#   scripts/bundle.sh BINARY [APP]     # APP: build/disktree.app by default
#
# `make build` runs this after `swift build -c release`. The bundle is what
# makes disktree an app rather than a command: an icon and a name in the Dock,
# a place in Spotlight and Launchpad, folders dropped on it, and an identity
# that the privacy settings (Full Disk Access) can name.
#
#   Contents/MacOS/disktree            BINARY
#   Contents/Resources/disktree.icns   assets/disktree.icns
#   Contents/Info.plist                packaging/Info.plist, with VERSION
#
# SIGN_IDENTITY picks the signature: ad-hoc ("-") unless it names a
# certificate.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
binary=${1:?usage: scripts/bundle.sh BINARY [APP]}
app=${2:-"$here/build/disktree.app"}
identity=${SIGN_IDENTITY:--}

# The bundle is deleted and rebuilt below, so it had better be one.
case $app in
    *.app) ;;
    *) echo "bundle.sh: $app is not a .app path" >&2; exit 2 ;;
esac

# CFBundleShortVersionString is three integers; a stray "v" or a blank line
# would otherwise go into the bundle unnoticed.
version=$(cat "$here/VERSION")
if ! printf '%s\n' "$version" | grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "bundle.sh: VERSION is '$version', not N.N.N" >&2
    exit 2
fi

# SwiftPM's Bundle.module looks for a target's resources at the top of the
# .app, where codesign refuses anything unsealed, and then at their absolute
# path in .build: an app that works only on the machine that built it. Stop
# here instead of shipping that. Test targets' bundles never go in the app.
for resources in "$(dirname "$binary")"/*.bundle; do
    case $resources in
        *Tests.bundle) continue ;;
    esac
    if [ -e "$resources" ]; then
        echo "bundle.sh: $resources: SwiftPM resources cannot ship in" \
            "disktree.app; keep them in code or teach this script" >&2
        exit 1
    fi
done

# From scratch every time: a file dropped from the bundle must not linger
# from the last build, and the signature seals whatever is there.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/disktree"
chmod 755 "$app/Contents/MacOS/disktree"
cp "$here/assets/disktree.icns" "$app/Contents/Resources/disktree.icns"
chmod 644 "$app/Contents/Resources/disktree.icns"
sed "s/@VERSION@/$version/g" "$here/packaging/Info.plist" \
    > "$app/Contents/Info.plist"
plutil -lint -s "$app/Contents/Info.plist"

# Ad-hoc by default: nothing to buy or configure to run what was built here.
# Apple silicon runs no unsigned code, and the linker's signature covers only
# the binary; signing the bundle seals Info.plist and the icon with it and
# names it io.github.kylemclaren.disktree, so `codesign --verify` vouches for the
# whole app. No hardened runtime for these: what demands it is notarization,
# which needs a Developer ID and cannot take an ad-hoc signature anyway, and
# nothing checks it on a build that never leaves this Mac. Give SIGN_IDENTITY
# a Developer ID and the runtime and the secure timestamp that notarization
# requires come with it.
#
# The cost of ad-hoc: macOS knows the app by the hash of this exact build, so
# a privacy grant such as Full Disk Access does not carry over to the next
# one; grant it again after reinstalling.
set -- --force --sign "$identity" \
    --entitlements "$here/packaging/entitlements.plist"
if [ "$identity" != "-" ]; then
    set -- "$@" --options runtime --timestamp
fi
codesign "$@" "$app"
codesign --verify --strict "$app"

echo "bundled $app ($version, $(lipo -archs "$app/Contents/MacOS/disktree"))"
