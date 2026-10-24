#!/usr/bin/env bash
#
# install.sh
#
# Turns a fresh Raspberry Pi OS Lite (64-bit, Trixie) install on a Pi 5
# (NVMe via the M.2 HAT+) into a minimal dwm/X11 desktop. Pi OS defaults are
# kept wherever they work; see README.md for what is and isn't changed.
#
# Run as your normal user (not root) -- it calls sudo where needed. Safe to
# re-run: suckless tools only rebuild when their pinned version, patches or
# config change.
#
#   --upgrade       also refresh uv, typst, starship and yazi to their latest releases
#   --xorg-legacy   install xserver-xorg-legacy and let any user start X as
#                   root. Fallback if rootless Xorg fails (see
#                   ~/.cache/xsession.log).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$HOME/src"
LOCAL_BIN="$HOME/.local/bin"
NEED_REBOOT=0

# Suckless release tags. Patches in patches/ are verified against these.
DWM_REF=6.8
DMENU_REF=5.4
ST_REF=0.9.3
SLOCK_REF=1.7
SLSTATUS_REF=1.1

UPGRADE=0
XORG_LEGACY=0
for arg in "$@"; do
  case "$arg" in
    --upgrade) UPGRADE=1 ;;
    --xorg-legacy) XORG_LEGACY=1 ;;
    *) echo "Unknown argument: $arg (supported: --upgrade, --xorg-legacy)" >&2; exit 1 ;;
  esac
done

log()  { printf '\n==> %s\n' "$1"; }
warn() { printf '\n!!  %s\n' "$1" >&2; }
die()  { printf '\n!!  %s\n' "$1" >&2; exit 1; }

trap 'warn "install.sh failed at line $LINENO. Fix the cause and re-run; completed steps are skipped."' ERR

# ---------------------------------------------------------------------------
section_preflight() {
  [ "$(id -u)" -ne 0 ] || die "Run as your normal user, not root/sudo."

  . /etc/os-release
  [ "${VERSION_CODENAME:-}" = "trixie" ] || warn "Expected Debian trixie, found '${VERSION_CODENAME:-unknown}'."
  [ "$(dpkg --print-architecture)" = "arm64" ] || warn "Expected arm64, found $(dpkg --print-architecture)."
  if [ -r /proc/device-tree/model ] && ! grep -q 'Raspberry Pi 5' /proc/device-tree/model; then
    warn "This isn't a Raspberry Pi 5; the PCIe/NVMe settings are Pi 5-specific."
  fi

  curl -fsI https://git.suckless.org >/dev/null || die "Can't reach git.suckless.org -- check the network."

  # Keep the sudo timestamp alive: apt upgrade plus compiling can outlast it.
  sudo -v
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true; sleep 50; done ) &
  KEEPALIVE_PID=$!
  trap 'kill "$KEEPALIVE_PID" 2>/dev/null || true' EXIT

  mkdir -p "$SRC_DIR" "$LOCAL_BIN"
}

# ---------------------------------------------------------------------------
section_packages() {
  log "apt: upgrade and install"
  local apt_env=(env DEBIAN_FRONTEND=noninteractive)
  sudo "${apt_env[@]}" apt-get update
  sudo "${apt_env[@]}" apt-get full-upgrade -y

  local pkgs=(
    # X and GPU
    xserver-xorg-core xserver-xorg-input-libinput xinit xauth x11-xserver-utils
    libgl1-mesa-dri
    # build
    build-essential git patch pkg-config
    libx11-dev libxft-dev libxinerama-dev libxrandr-dev libxext-dev
    # login and session
    greetd tuigreet xss-lock xwallpaper dbus-user-session dbus-x11 polkitd
    # apps
    chromium zathura zathura-pdf-poppler nsxiv xclip scrot xdg-utils
    vlc-bin vlc-plugin-base
    # audio and USB
    pipewire pipewire-pulse wireplumber udisks2 udiskie
    # fonts
    fonts-cascadia-code fontconfig fonts-noto-core fonts-noto-color-emoji fonts-liberation
    # tools
    fish bat fd-find ripgrep rsync entr fzf pass gnupg pinentry-curses
    ufw curl ca-certificates unzip file
  )
  [ "$XORG_LEGACY" -eq 1 ] && pkgs+=(xserver-xorg-legacy)
  sudo "${apt_env[@]}" apt-get install -y --no-install-recommends "${pkgs[@]}"

  # Debian renames these two to avoid clashes.
  ln -sfn /usr/bin/batcat "$LOCAL_BIN/bat"
  ln -sfn /usr/bin/fdfind "$LOCAL_BIN/fd"
}

# ---------------------------------------------------------------------------
# cfg_set <line> <regex>: make config.txt contain <line> exactly once,
# replacing any existing line matching ^<regex>.
cfg_set() {
  local line="$1" re="$2"
  if grep -qx "$line" "$CONFIG_TXT"; then
    return
  elif grep -q "^$re" "$CONFIG_TXT"; then
    sudo sed -i "/^$re/c\\$line" "$CONFIG_TXT"
  else
    echo "$line" | sudo tee -a "$CONFIG_TXT" >/dev/null
  fi
  NEED_REBOOT=1
  log "config.txt: set $line"
}

# cmdline_add <token>: append a kernel parameter if missing. The file must
# stay a single line.
cmdline_add() {
  grep -qE "(^| )$1( |\$)" "$CMDLINE_TXT" && return
  sudo sed -i "s/[[:space:]]*\$/ $1/" "$CMDLINE_TXT"
  NEED_REBOOT=1
  log "cmdline.txt: added $1"
}

section_firmware() {
  local boot=/boot/firmware
  [ -d "$boot" ] || boot=/boot
  CONFIG_TXT="$boot/config.txt"
  CMDLINE_TXT="$boot/cmdline.txt"
  [ -f "$CONFIG_TXT" ] && [ -f "$CMDLINE_TXT" ] || die "Couldn't find config.txt / cmdline.txt under $boot."

  log "firmware: PCIe Gen 3 for NVMe, quiet boot"
  grep -q '^dtoverlay=vc4-kms-v3d' "$CONFIG_TXT" || warn "dtoverlay=vc4-kms-v3d is missing from $CONFIG_TXT; Pi OS enables it by default. X needs it."

  # Our lines must land in [all]; a trailing [cm5]/[pi4] section would scope them wrongly.
  local last; last=$(grep -E '^\[.*\]' "$CONFIG_TXT" | tail -n1 || true)
  if [ -n "$last" ] && [ "$last" != "[all]" ]; then
    printf '\n[all]\n' | sudo tee -a "$CONFIG_TXT" >/dev/null
  fi
  cfg_set 'dtparam=pciex1' 'dtparam=pciex1$'
  # The M.2 HAT+ isn't certified for Gen 3; if the drive looks flaky, set =2.
  cfg_set 'dtparam=pciex1_gen=3' 'dtparam=pciex1_gen='
  cfg_set 'disable_splash=1' 'disable_splash='

  # console=tty1 stays on purpose: a real boot failure still shows on screen.
  for tok in quiet loglevel=0 vt.global_cursor_default=0 logo.nologo systemd.show_status=0; do
    cmdline_add "$tok"
  done
}

# ---------------------------------------------------------------------------
section_xorg() {
  log "Xorg: pin vc4 as the primary GPU"
  sudo install -D -m644 "$REPO/files/xorg/99-vc4.conf" /etc/X11/xorg.conf.d/99-vc4.conf

  if [ "$XORG_LEGACY" -eq 1 ]; then
    log "Xorg: --xorg-legacy, allowing any user to start X"
    printf 'allowed_users=anybody\nneeds_root_rights=yes\n' | sudo tee /etc/X11/Xwrapper.config >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# suckless <name> <ref> [patch...]: checkout <ref>, apply patches, install
# files/<name>/config.h (or a tweaked config.def.h), build as the user and
# `make install` as root. Skipped when ref, patches and config are unchanged.
suckless() {
  local name="$1" ref="$2"; shift 2
  local dir="$SRC_DIR/$name" cfg="$REPO/files/$name/config.h" want have=""
  want=$({ echo "$ref"; cat "$@" ${cfg:+"$cfg"} 2>/dev/null; echo "$FONT_STAMP"; } | sha256sum | cut -d' ' -f1)
  [ -f "$dir/.stamp" ] && have=$(cat "$dir/.stamp")
  if [ "$want" = "$have" ] && command -v "$name" >/dev/null 2>&1; then
    log "$name $ref already installed"
    return
  fi

  log "$name $ref: build"
  if [ ! -d "$dir/.git" ]; then
    git clone -q --depth 1 --branch "$ref" "https://git.suckless.org/$name" "$dir"
  else
    git -C "$dir" fetch -q --depth 1 origin tag "$ref"
    git -C "$dir" checkout -q -f "$ref"
  fi
  git -C "$dir" clean -qfdx

  local p
  for p in "$@"; do
    patch -d "$dir" -p1 -s --no-backup-if-mismatch < "$p"
  done

  if [ -f "$cfg" ]; then
    cp "$cfg" "$dir/config.h"
  else
    cp "$dir/config.def.h" "$dir/config.h"
    "config_tweak_$name" "$dir/config.h"
  fi

  make -C "$dir"
  sudo make -C "$dir" install
  echo "$want" > "$dir/.stamp"
}

config_tweak_dmenu() { sed -i "s#\"monospace:size=10\"#\"Cascadia Code:size=13\"#" "$1"; }
config_tweak_st()    { sed -i 's#^static char \*font = .*#static char *font = "Cascadia Code:size=14:antialias=true:autohint=true";#' "$1"; }
config_tweak_slock() { :; }

section_suckless() {
  FONT_STAMP="Cascadia Code 13/14"
  suckless dwm "$DWM_REF" "$REPO/patches/dwm-pertag-20200914-61bb8b2.diff" "$REPO/patches/dwm-fullscreen-20260112-f4fdaff.diff" "$REPO/patches/dwm-gaps-6.8.diff"
  suckless dmenu "$DMENU_REF"
  suckless slock "$SLOCK_REF"
  suckless st "$ST_REF" "$REPO/patches/st-scrollback-0.9.2.diff"
  suckless slstatus "$SLSTATUS_REF"
}

# ---------------------------------------------------------------------------
section_user_files() {
  log "helper scripts, station list, fish config, wallpaper, PDF handler"
  local f
  for f in "$REPO"/files/bin/*; do
    install -D -m755 "$f" "$LOCAL_BIN/$(basename "$f")"
  done
  mkdir -p "$HOME/Pictures" "$HOME/.config/radiomenu"
  # Station list is yours to edit: only created once.
  [ -f "$HOME/.config/radiomenu/stations" ] || install -m644 "$REPO/files/radiomenu/stations" "$HOME/.config/radiomenu/stations"
  install -D -m644 "$REPO/files/fish/pi-desktop.fish" "$HOME/.config/fish/conf.d/pi-desktop.fish"
  # Prompt config is yours to edit: only created once.
  [ -f "$HOME/.config/starship.toml" ] || install -D -m644 "$REPO/files/starship/starship.toml" "$HOME/.config/starship.toml"

  for f in "$REPO"/wallpaper.jpg "$REPO"/wallpaper.jpeg "$REPO"/wallpaper.png; do
    if [ -f "$f" ]; then
      cp "$f" "$HOME/.config/wallpaper.${f##*.}"
      break
    fi
  done

  # File-type defaults (used by xdg-open, e.g. from yazi). Chromium is the
  # HTML/URL default already; there is no text editor to bind here.
  install -D -m644 "$REPO/files/applications/cvlc.desktop" "$HOME/.local/share/applications/cvlc.desktop"
  local mime
  xdg-mime default org.pwmt.zathura.desktop application/pdf
  if [ -f /usr/share/applications/nsxiv.desktop ]; then
    for mime in image/png image/jpeg image/gif image/webp image/bmp image/tiff; do
      xdg-mime default nsxiv.desktop "$mime"
    done
  else
    warn "nsxiv.desktop not found; images won't open with nsxiv via xdg-open."
  fi
  for mime in video/mp4 video/x-matroska video/webm video/quicktime video/x-msvideo video/mpeg \
              audio/mpeg audio/flac audio/ogg audio/x-wav audio/mp4 audio/aac; do
    xdg-mime default cvlc.desktop "$mime"
  done
}

# ---------------------------------------------------------------------------
section_login() {
  log "login: greetd + tuigreet -> dwm"
  sudo install -D -m755 "$REPO/files/session/start-dwm" /usr/local/bin/start-dwm
  sudo install -D -m755 "$REPO/files/session/xsession-wrapper" /usr/local/bin/xsession-wrapper
  sudo install -D -m644 "$REPO/files/session/dwm.desktop" /usr/share/xsessions/dwm.desktop

  # Use the user the greetd package created; make one only if there is none.
  local greeter=""
  for u in _greetd greeter; do
    if getent passwd "$u" >/dev/null; then greeter="$u"; break; fi
  done
  if [ -z "$greeter" ]; then
    greeter=greeter
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$greeter"
    log "Created system user '$greeter' (the greetd package didn't provide one)."
  fi
  sudo install -d -o "$greeter" -g "$greeter" -m755 /var/cache/tuigreet

  sed "s/@GREETER@/$greeter/" "$REPO/files/greetd/config.toml" | sudo tee /etc/greetd/config.toml >/dev/null
  sudo install -D -m644 "$REPO/files/greetd/override.conf" /etc/systemd/system/greetd.service.d/override.conf
  sudo systemctl daemon-reload

  # greetd is display-manager.service, which only graphical.target starts.
  sudo systemctl set-default graphical.target
  sudo systemctl disable getty@tty1.service 2>/dev/null || true
  sudo systemctl reset-failed greetd.service 2>/dev/null || true
  sudo systemctl enable greetd.service
}

# ---------------------------------------------------------------------------
section_tools() {
  log "uv, typst, starship, yazi"
  if [ ! -x "$LOCAL_BIN/uv" ] && ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
  elif [ "$UPGRADE" -eq 1 ] && [ -x "$LOCAL_BIN/uv" ]; then
    "$LOCAL_BIN/uv" self update
  fi

  if [ "$UPGRADE" -eq 1 ] || { [ ! -x "$LOCAL_BIN/typst" ] && ! command -v typst >/dev/null 2>&1; }; then
    local tmp; tmp=$(mktemp -d)
    curl -fsSL "https://github.com/typst/typst/releases/latest/download/typst-aarch64-unknown-linux-musl.tar.xz" -o "$tmp/typst.tar.xz"
    tar -xf "$tmp/typst.tar.xz" -C "$tmp"
    install -m755 "$(find "$tmp" -type f -name typst | head -n1)" "$LOCAL_BIN/typst"
    rm -rf "$tmp"
  fi

  if [ "$UPGRADE" -eq 1 ] || { [ ! -x "$LOCAL_BIN/starship" ] && ! command -v starship >/dev/null 2>&1; }; then
    local tmp; tmp=$(mktemp -d)
    curl -fsSL "https://github.com/starship/starship/releases/latest/download/starship-aarch64-unknown-linux-musl.tar.gz" -o "$tmp/starship.tar.gz"
    tar -xf "$tmp/starship.tar.gz" -C "$tmp"
    install -m755 "$tmp/starship" "$LOCAL_BIN/starship"
    rm -rf "$tmp"
  fi

  if [ "$UPGRADE" -eq 1 ] || { [ ! -x "$LOCAL_BIN/yazi" ] && ! command -v yazi >/dev/null 2>&1; }; then
    local tmp; tmp=$(mktemp -d)
    curl -fsSL "https://github.com/sxyazi/yazi/releases/latest/download/yazi-aarch64-unknown-linux-musl.zip" -o "$tmp/yazi.zip"
    unzip -q "$tmp/yazi.zip" -d "$tmp"
    install -m755 "$(find "$tmp" -type f -name yazi | head -n1)" "$LOCAL_BIN/yazi"
    install -m755 "$(find "$tmp" -type f -name ya | head -n1)" "$LOCAL_BIN/ya"
    rm -rf "$tmp"
  fi
}

# ---------------------------------------------------------------------------
section_shell() {
  log "shell: fish as the login shell"
  local fish=/usr/bin/fish
  if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$fish" ]; then
    sudo chsh -s "$fish" "$USER"
  fi
}

# ---------------------------------------------------------------------------
section_firewall() {
  log "ufw: deny incoming; allow ssh and mDNS (hostname.local)"
  sudo ufw allow 22/tcp
  sudo ufw allow 5353/udp
  sudo ufw --force enable
}

# ---------------------------------------------------------------------------
section_verify() {
  log "verify"
  local bad=0 c
  for c in dwm dmenu st slock slstatus uv typst starship yazi fish pass cvlc udiskie; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$LOCAL_BIN/$c" ]; then
      printf '  ok       %s\n' "$c"
    else
      printf '  MISSING  %s\n' "$c"; bad=1
    fi
  done
  systemctl is-enabled --quiet greetd.service && echo '  ok       greetd enabled' || { echo '  MISSING  greetd not enabled'; bad=1; }
  [ -f /usr/share/xsessions/dwm.desktop ] && echo '  ok       dwm.desktop' || { echo '  MISSING  dwm.desktop'; bad=1; }
  [ "$bad" -eq 0 ] || warn "Some checks failed -- see above."
}

section_summary() {
  cat <<'EOF'

Done. Keys (MODKEY = Super):
  Shift+Return st | p dmenu | b chromium | Ctrl+l lock | Shift+f fullscreen
  v nsxiv ~/Pictures | u USB mount/unmount | r radio | w close | Shift+q quit dwm
  Print / Super+Print screenshot | F10 F11 F12 mute / vol- / vol+

Still manual:
  gpg --full-generate-key  then  pass init <key-id>

If X fails to start after login, read ~/.cache/xsession.log and
~/.cache/start-dwm.log, then try: ./install.sh --xorg-legacy
Recovery: Ctrl+Alt+F2 gives a getty; `sudo systemctl set-default multi-user.target` backs out of greetd.
EOF
  if [ "$NEED_REBOOT" -eq 1 ]; then
    echo; echo "Firmware/boot config changed -- reboot required: sudo reboot"
  else
    echo; echo "Reboot, then log in at the tuigreet prompt -> dwm."
  fi
}

main() {
  exec > >(tee -a "$HOME/install.log") 2>&1
  section_preflight
  section_packages
  section_firmware
  section_xorg
  section_suckless
  section_user_files
  section_login
  section_tools
  section_shell
  section_firewall
  section_verify
  section_summary
}

main
