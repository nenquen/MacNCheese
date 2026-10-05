#!/usr/bin/env bash
# Installs the Mac O’ Blox launcher for the current user: menu entry, icons
# and a `macoblox` command. Run again after moving the project folder.
set -euo pipefail
launcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_dir=$(dirname -- "$launcher_dir")
data_home=${XDG_DATA_HOME:-$HOME/.local/share}
config_home=${XDG_CONFIG_HOME:-$HOME/.config}

for size in 16 22 24 32 48 64 128 256 512; do
  install -Dm644 "$project_dir/branding/icons/macoblox-$size.png" \
    "$data_home/icons/hicolor/${size}x${size}/apps/macoblox.png"
done

install -d "$HOME/.local/bin"
ln -sf "$launcher_dir/macoblox-launcher" "$HOME/.local/bin/macoblox"

# The launcher's path as a quoted Exec argument (Desktop Entry spec): a
# project folder with a space in its path broke the menu entries.
exec_path=${launcher_dir//\\/\\\\\\\\}
exec_path=${exec_path//\"/\\\\\"}
exec_path=${exec_path//\`/\\\\\`}
exec_path=${exec_path//\$/\\\\\$}
exec_path=\"${exec_path//%/%%}/macoblox-launcher\"

install -d "$data_home/applications"
cat > "$data_home/applications/wtf.aubree.MacOBlox.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Mac O’ Blox
Comment=Run the macOS Roblox client on Linux through Darling
Comment[ru]=Запуск клиента Roblox для macOS на Linux через Darling
GenericName=Roblox launcher
GenericName[ru]=Лаунчер Roblox
Exec=$exec_path
Icon=macoblox
Terminal=false
Categories=Game;
Keywords=roblox;darling;
StartupNotify=true
DESKTOP

# Roblox links are LaunchServices protocol handoffs on macOS.  Keep a
# separate hidden entry for Linux so the complete URI is substituted into one
# launcher argument and can reach RobloxPlayer unchanged.
cat > "$data_home/applications/wtf.aubree.MacOBlox.URI.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Mac O’ Blox Roblox Link Handler
Comment=Open Roblox links in Mac O’ Blox
Exec=$exec_path %u
Icon=macoblox
Terminal=false
NoDisplay=true
MimeType=x-scheme-handler/roblox;x-scheme-handler/roblox-player;
DESKTOP

# Roblox Studio (Windows version through Wine), also the handler of the
# roblox-studio: links and of roblox-studio-auth: that signs Studio in.
cat > "$data_home/applications/wtf.aubree.MacOBlox.Studio.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Roblox Studio (Mac O’ Blox)
Comment=Roblox Studio through Wine
Comment[ru]=Roblox Studio через Wine
Exec=$exec_path --studio %u
Icon=macoblox
Terminal=false
Categories=Development;
MimeType=x-scheme-handler/roblox-studio;x-scheme-handler/roblox-studio-auth;application/x-roblox-place;
StartupWMClass=robloxstudiobeta.exe
DESKTOP
# Place files (.rbxl, .rbxlx) as their own type, so file managers open them
# with Studio: no MIME database defines one.
install -Dm644 "$project_dir/packaging/wtf.aubree.MacOBlox.xml" "$data_home/mime/packages/wtf.aubree.MacOBlox.xml"
update-mime-database "$data_home/mime" 2>/dev/null || true
if command -v xdg-mime >/dev/null; then
  for type in x-scheme-handler/roblox-studio x-scheme-handler/roblox-studio-auth application/x-roblox-place; do
    xdg-mime default wtf.aubree.MacOBlox.Studio.desktop "$type"
  done
  for type in x-scheme-handler/roblox x-scheme-handler/roblox-player; do
    xdg-mime default wtf.aubree.MacOBlox.URI.desktop "$type"
  done
fi

# Old app IDs (org.macoblox.Launcher before 0.10, xyz.narez.MacOBlox before
# 0.15); removed after the new entries exist so menus that rescan on the
# first change (noctalia) do not miss them.
rm -f "$data_home/applications/org.macoblox.Launcher.desktop" \
  "$data_home/applications/xyz.narez.MacOBlox.desktop" \
  "$data_home/applications/xyz.narez.MacOBlox.Studio.desktop" \
  "$data_home/mime/packages/xyz.narez.MacOBlox.xml"
if [ -f "$config_home/mimeapps.list" ]; then
  sed -i -e 's/xyz\.narez\.MacOBlox\.Studio\.desktop;\{0,1\}//g' -e '/^[^=[]*=$/d' "$config_home/mimeapps.list"
fi

# The game window itself (X11 class RobloxPlayer) gets the same icon in docks.
cat > "$data_home/applications/macoblox-roblox-window.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Roblox (Mac O’ Blox)
Exec=$exec_path
Icon=macoblox
NoDisplay=true
StartupWMClass=RobloxPlayer
DESKTOP

update-desktop-database "$data_home/applications" 2>/dev/null || true
# No gtk-update-icon-cache: with -t it wrote a cache into the user's icon
# folder that other apps do not update, which can hide their icons.
echo "Mac O’ Blox installed: find it in the app menu or run: macoblox"
