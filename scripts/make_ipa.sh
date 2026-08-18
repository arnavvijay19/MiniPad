#!/usr/bin/env bash
#
# make_ipa.sh — package a built .app into an .ipa, and say what is inside it.
#
# An .ipa is a zip with the app under `Payload/`. That is the whole format, and
# it is why an unsigned .ipa is a perfectly good CI artifact: the signature is
# applied later, on the machine that has the Apple ID. Sideloadly and AltStore
# both re-sign from scratch, so nothing this script produces needs a
# certificate.
#
# Usage:
#   scripts/make_ipa.sh <path/to/Minis.app> <output.ipa> [--strip-extensions]
#
# --strip-extensions removes `PlugIns/` (the share extension, the widget and
# the File Provider) and the corresponding Info.plist references. That is what
# the PersonalFree route needs: each extension is a separate App ID, every one
# of them wants an App Group that free provisioning cannot issue, and the app
# itself does not need any of them. See
# docs/design/unified-agent/FREE_DEVELOPER_CAPABILITIES.md.
#
# The script refuses to produce an .ipa that is missing something the app needs
# at runtime, because "it installed and then the terminal did not work" is a
# much worse outcome than a failed build.
#
set -euo pipefail

APP="${1:?usage: make_ipa.sh <app> <output.ipa> [--strip-extensions]}"
OUT="${2:?usage: make_ipa.sh <app> <output.ipa> [--strip-extensions]}"
STRIP=0
[ "${3:-}" = "--strip-extensions" ] && STRIP=1

[ -d "$APP" ] || { echo "not a bundle: $APP" >&2; exit 1; }

# `zip` runs with the staging directory as its cwd, so resolve the output now.
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
NAME="$(basename "$APP")"
BUNDLE="$STAGE/Payload/$NAME"

if [ "$STRIP" -eq 1 ]; then
    if [ -d "$BUNDLE/PlugIns" ]; then
        echo "== removing extensions =="
        for ext in "$BUNDLE/PlugIns"/*; do
            [ -e "$ext" ] || continue
            echo "   $(basename "$ext")"
        done
        rm -rf "$BUNDLE/PlugIns"
    fi
    # A widget also leaves a copy under Watch/ or Extensions/ in some layouts.
    rm -rf "$BUNDLE/Extensions"
fi

echo "== bundle contents =="
plist="$BUNDLE/Info.plist"
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion; do
    printf '%-28s ' "$key"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || echo "(absent)"
done

# ---------------------------------------------------------------------------
# Runtime completeness. Each of these is something the app cannot do without,
# and each has been silently missing from a build at least once.
# ---------------------------------------------------------------------------
problems=()

[ -f "$BUNDLE/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" ] \
    || problems+=("main executable missing")

# The Alpine rootfs the iSH sandbox unpacks on first launch.
if [ ! -f "$BUNDLE/alpine-rootfs.zip" ]; then
    found=$(find "$BUNDLE" -maxdepth 2 -name 'alpine-rootfs*' -print -quit)
    [ -n "$found" ] || problems+=("alpine rootfs missing — the terminal will not start")
fi

# FFmpeg ships as embedded frameworks.
if [ -d "$BUNDLE/Frameworks" ]; then
    fw=$(ls "$BUNDLE/Frameworks" | wc -l | tr -d ' ')
    echo "Frameworks: $fw"
    ls "$BUNDLE/Frameworks" | sed 's/^/   /'
else
    problems+=("no Frameworks directory")
fi

if [ "$STRIP" -eq 0 ] && [ -d "$BUNDLE/PlugIns" ]; then
    echo "Extensions:"
    ls "$BUNDLE/PlugIns" | sed 's/^/   /'
fi

if [ "$STRIP" -eq 1 ] && [ -d "$BUNDLE/PlugIns" ]; then
    problems+=("PlugIns survived --strip-extensions")
fi

# Architecture. A simulator build would install nowhere.
exe="$BUNDLE/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
if [ -f "$exe" ]; then
    arch_line=$(lipo -info "$exe" 2>/dev/null || file "$exe")
    echo "Architecture: $arch_line"
    case "$arch_line" in
        *arm64*) ;;
        *) problems+=("executable is not arm64: $arch_line") ;;
    esac
fi

if [ "${#problems[@]}" -gt 0 ]; then
    echo "== INCOMPLETE BUNDLE ==" >&2
    printf '   %s\n' "${problems[@]}" >&2
    exit 2
fi

rm -f "$OUT"
( cd "$STAGE" && zip -qry "$OUT" Payload )

size=$(du -h "$OUT" | cut -f1)
sum=$(shasum -a 256 "$OUT" | cut -d' ' -f1)
echo "== $OUT =="
echo "size    $size"
echo "sha256  $sum"
echo "$sum  $(basename "$OUT")" > "$OUT.sha256"
