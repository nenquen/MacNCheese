#!/usr/bin/env bash
# Builds wordmark-light.png / wordmark-dark.png: the square logo on the left
# and "Mac'n Cheese" in Comfortaa Bold (source/, SIL OFL). Needs rsvg-convert
# and ImageMagick; the font is used from source/ without installing it.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT
LOGO=$(base64 -w0 "$HERE/logo_1024.png")
cat > "$TEMP/fonts.conf" <<FONTS
<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig><dir>$HERE/source</dir><include ignore_missing="yes">/etc/fonts/fonts.conf</include><cachedir>$TEMP/cache</cachedir></fontconfig>
FONTS
export FONTCONFIG_FILE="$TEMP/fonts.conf"
for theme in light dark; do
  case $theme in
    light) color='#1f2328' ;;
    dark) color='#f0f6fc' ;;
  esac
  cat > "$TEMP/$theme.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="2400" height="600"><image x="40" y="40" width="520" height="520" href="data:image/png;base64,$LOGO"/><text x="620" y="385" font-family="Comfortaa" font-weight="700" font-size="250" fill="$color">Mac'n Cheese</text></svg>
SVG
  rsvg-convert "$TEMP/$theme.svg" -o "$TEMP/$theme.png"
done
mv -- "$TEMP/light.png" "$HERE/wordmark-light.png"
mv -- "$TEMP/dark.png" "$HERE/wordmark-dark.png"
printf 'Wrote %s\n' "$HERE/wordmark-light.png" "$HERE/wordmark-dark.png"
