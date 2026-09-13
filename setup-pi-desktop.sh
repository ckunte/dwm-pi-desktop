#!/usr/bin/env bash
#
# setup-pi-desktop.sh
#
# Turns a fresh Raspberry Pi OS Lite (64-bit, Trixie/Debian 13) install on a
# Pi 5 (8GB RAM, NVMe SSD on the official M.2 HAT+) into a minimal dwm/X11
# "pocket desktop": dmenu, slstatus, tuigreet, slock/xss-lock, st, chromium
# (bound to Super+b), plus a CLI toolset. USB drives auto-mount via udiskie
# (Super+u for manual mount/unmount). Also configures NVMe PCIe Gen 3 and
# the bootloader's boot order/diagnostics screen (section_boot_order).
#
# Run as your normal user (NOT root/sudo) — it calls sudo internally only
# where needed. Safe to re-run: every section checks whether its target
# already exists before doing anything.
#
# Pass --upgrade to instead refresh already-installed software: suckless
# tools are reset to latest upstream and their patches reapplied (your
# config.h is untouched either way), uv-managed tools and typst are
# updated to their latest release, and vim-plug runs :PlugUpdate. Without
# --upgrade, all of that is left alone once installed — a plain re-run
# only ever fixes/completes configuration, never churns working software.

set -euo pipefail

SRC_DIR="$HOME/src"
LOCAL_BIN="$HOME/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEED_REBOOT=0

UPGRADE=0
for arg in "$@"; do
  case "$arg" in
    --upgrade) UPGRADE=1 ;;
    *)
      echo "Unknown argument: $arg (only --upgrade is supported)" >&2
      exit 1
      ;;
  esac
done

log()  { printf '\n==> %s\n' "$1"; }
warn() { printf '\n!!  %s\n' "$1" >&2; }

# find_config_txt: prints the path to firmware config.txt, or nothing if
# not found. Shared by section_firmware and section_quiet_boot.
find_config_txt() {
  if [ -f /boot/firmware/config.txt ]; then echo /boot/firmware/config.txt
  elif [ -f /boot/config.txt ]; then echo /boot/config.txt
  fi
}

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not root/sudo. It escalates internally only where needed." >&2
  exit 1
fi

if [ "$(uname -m)" != "aarch64" ]; then
  warn "Detected $(uname -m), not aarch64. This script assumes 64-bit Raspberry Pi OS."
fi

if [ -r /proc/device-tree/model ] && ! grep -q 'Raspberry Pi 5' /proc/device-tree/model 2>/dev/null; then
  warn "This doesn't look like a Raspberry Pi 5 ($(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)). The PCIe/NVMe steps (section_firmware, section_boot_order) are Pi 5-specific and may be no-ops or wrong on other boards."
fi

mkdir -p "$SRC_DIR" "$LOCAL_BIN"

# ---------------------------------------------------------------------------
section_packages() {
  log "apt: updating and installing packages"
  sudo apt update
  sudo apt full-upgrade -y

  sudo apt install -y \
    xserver-xorg xserver-xorg-legacy xinit x11-xserver-utils \
    xserver-xorg-input-libinput xserver-xorg-input-all \
    libx11-dev libxft-dev libxinerama-dev libxrandr-dev \
    build-essential patch git pkg-config libpam0g-dev \
    fonts-cascadia-code fontconfig \
    bat detox entr fd-find fish fzf gnumeric gnupg gparted pass \
    pngquant python3-numpy python3-pandas python3-matplotlib \
    rename ripgrep rsync ufw vlc neovim xss-lock xwallpaper \
    nsxiv xclip scrot \
    xauth brightnessctl xdg-utils \
    greetd tuigreet \
    zathura zathura-pdf-poppler \
    rpi-eeprom \
    chromium \
    udisks2 udiskie \
    pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils \
    curl ca-certificates
  # Notes on less-obvious picks:
  # - chromium: prebuilt, no vim keybindings (surf/qutebrowser both hit
  #   build/config friction here — see README).
  # - udisks2/udiskie: udisksctl does the actual mount/unmount; udiskie
  #   auto-mounts on insert (started in start-dwm, --no-tray — dwm's bar
  #   has none); Super+u (usbmenu) is for manual mount/unmount/eject.
  # - pipewire stack: a bare Lite install has no sound server at all. The
  #   Pi 5 has no analog jack — audio is HDMI-only; route an aux speaker
  #   via your monitor's own audio passthrough, or a USB DAC.

  # Debian renames these two to avoid clashes; symlink the names you asked for.
  [ -e "$LOCAL_BIN/bat" ] || ln -s /usr/bin/batcat "$LOCAL_BIN/bat"
  [ -e "$LOCAL_BIN/fd" ]  || ln -s /usr/bin/fdfind "$LOCAL_BIN/fd"
}

# ---------------------------------------------------------------------------
section_firmware() {
  log "firmware: checking full-KMS (vc4-kms-v3d) is enabled"
  local cfg; cfg=$(find_config_txt)

  if [ -z "$cfg" ]; then
    warn "Couldn't find config.txt — add 'dtoverlay=vc4-kms-v3d' to it manually."
    return
  fi

  if grep -q '^dtoverlay=vc4-kms-v3d' "$cfg"; then
    log "Full KMS already enabled in $cfg"
  else
    echo "dtoverlay=vc4-kms-v3d" | sudo tee -a "$cfg" >/dev/null
    NEED_REBOOT=1
    log "Enabled full KMS in $cfg — a reboot will be needed"
  fi

  if [ -f /etc/X11/Xwrapper.config ]; then
    sudo sed -i 's/^allowed_users=.*/allowed_users=anybody/' /etc/X11/Xwrapper.config
    grep -q '^needs_root_rights' /etc/X11/Xwrapper.config || \
      echo 'needs_root_rights=yes' | sudo tee -a /etc/X11/Xwrapper.config >/dev/null
  fi

  log "firmware: enabling PCIe Gen 3 for the NVMe M.2 HAT+"
  # dtparam=pciex1 turns on the Pi 5's external PCIe connector (kernel sees
  # the NVMe drive at all); dtparam=pciex1_gen=3 doubles the link speed.
  # Not certified by Raspberry Pi for Gen 3 — if the drive looks flaky,
  # drop this back to =2 (or delete it) before assuming bad hardware.
  if grep -q '^dtparam=pciex1$' "$cfg"; then
    log "PCIe x1 connector already enabled in $cfg"
  else
    echo 'dtparam=pciex1' | sudo tee -a "$cfg" >/dev/null
    NEED_REBOOT=1
    log "Enabled the PCIe x1 connector in $cfg"
  fi

  if grep -q '^dtparam=pciex1_gen=3$' "$cfg"; then
    log "PCIe Gen 3 already set in $cfg"
  elif grep -q '^dtparam=pciex1_gen=' "$cfg"; then
    sudo sed -i 's/^dtparam=pciex1_gen=.*/dtparam=pciex1_gen=3/' "$cfg"
    NEED_REBOOT=1
    log "Changed PCIe link speed to Gen 3 in $cfg"
  else
    echo 'dtparam=pciex1_gen=3' | sudo tee -a "$cfg" >/dev/null
    NEED_REBOOT=1
    log "Set PCIe link speed to Gen 3 in $cfg"
  fi
}

# ---------------------------------------------------------------------------
section_boot_order() {
  log "bootloader: setting boot order to SD card, then NVMe, then USB"
  # BOOT_ORDER is a hex string read right to left, one digit per device:
  # 1=SD, 4=USB-MSD, 6=NVMe, f=restart the sequence if nothing bootable was
  # found. 0xf461 = SD -> NVMe -> USB (matches raspi-config's "B1" preset).
  # DISABLE_HDMI=1 separately silences the bootloader's own pre-Linux
  # "Configure this Raspberry Pi" boot-progress screen (drawn to HDMI
  # before Linux starts) — purely cosmetic, no effect on which device
  # boots. Tradeoff: that screen's "Press ESC for diagnostics" option goes
  # away too, so a total boot failure shows a blank screen instead.
  if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    warn "rpi-eeprom-config not found (rpi-eeprom package missing?) — skipping boot-order setup. Install rpi-eeprom and re-run, or set it yourself with 'sudo -E rpi-eeprom-config --edit' (BOOT_ORDER=0xf461, DISABLE_HDMI=1)."
    return
  fi

  local wanted_order="0xf461" wanted_hdmi="1"
  local current_order="" current_hdmi=""
  # `|| true`: sed finding no matching line shouldn't happen, but be
  # defensive against set -e treating that as a hard error.
  current_order=$(sudo rpi-eeprom-config 2>/dev/null | sed -n 's/^BOOT_ORDER=//p' | tr -d '[:space:]') || true
  current_hdmi=$(sudo rpi-eeprom-config 2>/dev/null | sed -n 's/^DISABLE_HDMI=//p' | tr -d '[:space:]') || true

  if [ "$current_order" = "$wanted_order" ] && [ "$current_hdmi" = "$wanted_hdmi" ]; then
    log "Boot order ($wanted_order) and silenced boot-diagnostics screen (DISABLE_HDMI=$wanted_hdmi) already set"
    return
  fi

  local tmp
  # Created via sudo, not plain mktemp: --out/--apply below run as root,
  # and Debian's fs.protected_regular=2 hardening blocks root from writing
  # into a file it doesn't own inside a sticky world-writable dir (/tmp).
  tmp=$(sudo mktemp)
  if ! sudo rpi-eeprom-config --out "$tmp"; then
    warn "Couldn't read the current EEPROM config — skipping boot-order/DISABLE_HDMI setup. Set it yourself with 'sudo -E rpi-eeprom-config --edit' (BOOT_ORDER=0xf461, DISABLE_HDMI=1)."
    sudo rm -f "$tmp"
    return
  fi

  if sudo grep -q '^BOOT_ORDER=' "$tmp"; then
    sudo sed -i "s/^BOOT_ORDER=.*/BOOT_ORDER=$wanted_order/" "$tmp"
  else
    echo "BOOT_ORDER=$wanted_order" | sudo tee -a "$tmp" >/dev/null
  fi

  if sudo grep -q '^DISABLE_HDMI=' "$tmp"; then
    sudo sed -i "s/^DISABLE_HDMI=.*/DISABLE_HDMI=$wanted_hdmi/" "$tmp"
  else
    echo "DISABLE_HDMI=$wanted_hdmi" | sudo tee -a "$tmp" >/dev/null
  fi

  if sudo rpi-eeprom-config --apply "$tmp"; then
    NEED_REBOOT=1
    log "Boot order set to $wanted_order (SD, NVMe, USB) and DISABLE_HDMI=$wanted_hdmi set — takes effect after reboot"
  else
    warn "Failed to apply the new boot order/DISABLE_HDMI — check the 'rpi-eeprom-config --apply' output above and set it yourself with 'sudo -E rpi-eeprom-config --edit' (BOOT_ORDER=0xf461, DISABLE_HDMI=1)."
  fi
  sudo rm -f "$tmp"
}

# ---------------------------------------------------------------------------
section_xorg() {
  log "Xorg: pinning the display GPU (vc4) as primary via OutputClass"
  # Under full KMS the Pi exposes two DRM devices (vc4 for scanout, v3d for
  # 3D-only). Without a hint, Xorg can pick v3d as primary and then fail to
  # bring up vc4 via legacy fbdev ("Cannot run in framebuffer mode"), which
  # kills the session right after login — nothing to do with dwm itself.
  # This rule unconditionally binds vc4 as primary so that never happens.
  sudo mkdir -p /etc/X11/xorg.conf.d
  sudo tee /etc/X11/xorg.conf.d/99-vc4.conf >/dev/null <<'EOF'
Section "OutputClass"
	Identifier "vc4"
	MatchDriver "vc4"
	Driver "modesetting"
	Option "PrimaryGPU" "true"
EndSection
EOF
}

# ---------------------------------------------------------------------------
section_quiet_boot() {
  log "boot: silencing kernel/systemd console output (tuigreet is the only thing that should show)"
  local cmdline=""
  if [ -f /boot/firmware/cmdline.txt ]; then cmdline=/boot/firmware/cmdline.txt
  elif [ -f /boot/cmdline.txt ]; then cmdline=/boot/cmdline.txt
  fi

  if [ -z "$cmdline" ]; then
    warn "Couldn't find cmdline.txt — add 'quiet loglevel=0 vt.global_cursor_default=0 logo.nologo systemd.show_status=0' to it manually."
  elif grep -q 'loglevel=0' "$cmdline"; then
    log "Quiet-boot kernel params already set in $cmdline"
    # Self-heal: quiet alone only sets systemd's status output to "auto"
    # (shown again once a unit takes >1.5s or errors) — not fully off,
    # which is why things like the fsck summary can still print.
    if ! grep -q 'systemd.show_status=0' "$cmdline"; then
      sudo sed -i 's/$/ systemd.show_status=0/' "$cmdline"
      NEED_REBOOT=1
      log "Patched existing $cmdline to add systemd.show_status=0 (silences systemd's own status/fsck lines)."
    fi
  else
    # cmdline.txt must stay a single line — append, never write a new one.
    # console=tty1 is deliberately left in place: a genuine boot failure
    # (fsck error, kernel panic) still shows on an emergency console.
    sudo sed -i 's/$/ quiet loglevel=0 vt.global_cursor_default=0 logo.nologo systemd.show_status=0/' "$cmdline"
    NEED_REBOOT=1
    log "Added quiet-boot kernel params to $cmdline"
  fi

  local cfg; cfg=$(find_config_txt)
  if [ -z "$cfg" ]; then
    warn "Couldn't find config.txt — add 'disable_splash=1' to it manually."
    return
  fi

  if grep -q '^disable_splash=1' "$cfg"; then
    log "Firmware rainbow-splash already disabled in $cfg"
  else
    echo 'disable_splash=1' | sudo tee -a "$cfg" >/dev/null
    NEED_REBOOT=1
    log "Disabled the firmware rainbow-splash screen in $cfg"
  fi
}

# ---------------------------------------------------------------------------
# clone_or_update <url> <dir>: clones if missing. On a plain run, leaves
# an existing clone untouched — a pull would conflict with the patches
# applied to it. Under --upgrade, resets to the latest upstream commit
# instead (config.h, being untracked, survives either way), so patches can
# be reapplied fresh. Sets CLONE_OR_UPDATE_FRESH=1 when the tree just
# became pristine (new clone, or an --upgrade reset), 0 if left alone.
clone_or_update() {
  CLONE_OR_UPDATE_FRESH=0
  if [ -d "$2" ]; then
    if [ "$UPGRADE" -eq 1 ]; then
      log "$(basename "$2"): fetching latest upstream"
      if (cd "$2" && git fetch --depth 1 origin HEAD && git reset --hard FETCH_HEAD); then
        CLONE_OR_UPDATE_FRESH=1
      else
        warn "Couldn't fetch latest $(basename "$2") — leaving the existing source as-is."
      fi
    else
      log "$(basename "$2") source already present, leaving as-is"
    fi
  else
    git clone --depth 1 "$1" "$2"
    CLONE_OR_UPDATE_FRESH=1
  fi
}

# try_patch <dir> <url> <name>: dry-run first, only apply if clean, else
# warn and leave the source vanilla — a patch is an enhancement, never a
# requirement. Returns 0 if applied, 1 if skipped.
try_patch() {
  local dir="$1" url="$2" name="$3"
  local tmp; tmp=$(mktemp)
  if ! curl -fsSL "$url" -o "$tmp"; then
    warn "Couldn't download the $name patch — skipping, building vanilla instead."
    rm -f "$tmp"
    return 1
  fi
  if (cd "$dir" && patch -p1 --fuzz=3 --dry-run < "$tmp" >/dev/null 2>&1); then
    (cd "$dir" && patch -p1 --fuzz=3 < "$tmp" >/dev/null)
    log "Applied $name patch in $(basename "$dir")"
    rm -f "$tmp"
    return 0
  else
    warn "$name patch didn't apply cleanly against the current $(basename "$dir") source — skipping, building vanilla instead. ($url)"
    rm -f "$tmp"
    return 1
  fi
}

# build_and_install <dir> [extra make-install args...]: a failed build must
# never take the rest of the script down (set -e would abort on the first
# compile error) — warn and let the caller move on to the next tool.
build_and_install() {
  local dir="$1"; shift
  if (cd "$dir" && sudo make clean install "$@"); then
    return 0
  else
    warn "$(basename "$dir") failed to build/install — see the compiler output above."
    warn "Fix $dir/config.h (compare it against the freshly-cloned config.def.h in the same dir), then re-run this script. Continuing with the rest of the setup."
    return 1
  fi
}

section_suckless() {
  log "suckless: building dwm, dmenu, slock, st, slstatus"
  local dwm_fullscreen_applied="no"

  # --- dwm: pertag + fullscreen patches, then customized config.h ---
  # Patches only ever touch a pristine tree (fresh clone, or an --upgrade
  # reset) — never one with config.h already generated on top of it — so a
  # failed/skipped patch never leaves a half-patched build.
  clone_or_update https://git.suckless.org/dwm "$SRC_DIR/dwm"
  if [ "$CLONE_OR_UPDATE_FRESH" -eq 1 ]; then
    try_patch "$SRC_DIR/dwm" \
      "https://dwm.suckless.org/patches/pertag/dwm-pertag-20200914-61bb8b2.diff" \
      "dwm pertag" || true
    if try_patch "$SRC_DIR/dwm" \
      "https://dwm.suckless.org/patches/fullscreen/dwm-fullscreen-20260112-f4fdaff.diff" \
      "dwm fullscreen"; then
      dwm_fullscreen_applied="yes"
    fi
  fi
  if [ ! -f "$SRC_DIR/dwm/config.h" ]; then
    cat > "$SRC_DIR/dwm/config.h" <<'EOF'
/* appearance */
static const unsigned int borderpx  = 1;
static const unsigned int snap      = 32;
static const int showbar            = 1;
static const int topbar             = 1;
static const char *fonts[]          = { "Cascadia Code:size=13:antialias=true:autohint=true" };
static const char dmenufont[]       = "Cascadia Code:size=13:antialias=true:autohint=true";
static const char col_gray1[]       = "#222222";
static const char col_gray2[]       = "#444444";
static const char col_gray3[]       = "#bbbbbb";
static const char col_gray4[]       = "#eeeeee";
static const char col_cyan[]        = "#636C40";
static const char *colors[][3]      = {
	/*               fg         bg         border   */
	[SchemeNorm] = { col_gray3, col_gray1, col_gray2 },
	[SchemeSel]  = { col_gray4, col_cyan,  col_cyan  },
};

/* tagging */
static const char *tags[] = { "1", "2", "3", "4", "5" };

static const Rule rules[] = {
	/* class      instance    title       tags mask     isfloating   monitor */
	{ "Gimp",     NULL,       NULL,       0,            1,           -1 },
};

/* layout(s) */
static const float mfact     = 0.55;
static const int nmaster     = 1;
static const int resizehints = 1;
static const int lockfullscreen = 1;
/* required by dwm.c since upstream commit 74edc27 (Aug 2025) */
static const int refreshrate = 120;

static const Layout layouts[] = {
	{ "[]=",      tile },
	{ "><>",      NULL },
	{ "[M]",      monocle },
};

/* key definitions */
#define MODKEY Mod4Mask /* Super/Win key */
#define TAGKEYS(KEY,TAG) \
	{ MODKEY,                       KEY,      view,           {.ui = 1 << TAG} }, \
	{ MODKEY|ControlMask,           KEY,      toggleview,     {.ui = 1 << TAG} }, \
	{ MODKEY|ShiftMask,             KEY,      tag,            {.ui = 1 << TAG} }, \
	{ MODKEY|ControlMask|ShiftMask, KEY,      toggletag,      {.ui = 1 << TAG} },

#define SHCMD(cmd) { .v = (const char*[]){ "/bin/sh", "-c", cmd, NULL } }

/* commands */
static char dmenumon[2] = "0";
/* -i = case-insensitive (always safe). -F fuzzy also works if the
 * fuzzymatch patch applied — add it here yourself, or run dmenu_run -F. */
static const char *dmenucmd[] = { "dmenu_run", "-i", "-m", dmenumon, "-fn", dmenufont, "-nb", col_gray1, "-nf", col_gray3, "-sb", col_cyan, "-sf", col_gray4, NULL };
static const char *termcmd[]  = { "st", NULL };
static const char *browser[]  = { "chromium", "--no-first-run", "--no-default-browser-check", "https://lite.cnn.com/en", NULL };
static const char *lockcmd[]  = { "slock", NULL };
static const char *imgview[]  = { "imgview", NULL };
static const char *usbmenu[]  = { "usbmenu", NULL };
static const char *radiomenu[] = { "radiomenu", NULL };

static const Key keys[] = {
	/* modifier                     key        function        argument */
	{ MODKEY,                       XK_p,      spawn,          {.v = dmenucmd } },
	{ MODKEY|ShiftMask,             XK_Return, spawn,          {.v = termcmd } },
	{ MODKEY,                       XK_b,      spawn,          {.v = browser } },
	{ MODKEY|ControlMask,           XK_l,      spawn,          {.v = lockcmd } },
	{ MODKEY,                       XK_v,      spawn,          {.v = imgview } },
	{ MODKEY,                       XK_u,      spawn,          {.v = usbmenu } },
	{ MODKEY,                       XK_r,      spawn,          {.v = radiomenu } },
	{ 0,                             XK_Print,  spawn,          SHCMD("screenshot") },
	{ MODKEY,                        XK_Print,  spawn,          SHCMD("screenshot select") },
	/* F10/F11/F12: mute/down/up. -l 1.0 caps the raise at 100%. */
	{ 0,                             XK_F10,    spawn,          SHCMD("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle") },
	{ 0,                             XK_F11,    spawn,          SHCMD("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-") },
	{ 0,                             XK_F12,    spawn,          SHCMD("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+") },
/*	{ MODKEY,                       XK_b,      togglebar,      {0} },
*/	{ MODKEY,                       XK_j,      focusstack,     {.i = +1 } },
	{ MODKEY,                       XK_k,      focusstack,     {.i = -1 } },
	{ MODKEY,                       XK_i,      incnmaster,     {.i = +1 } },
	{ MODKEY,                       XK_d,      incnmaster,     {.i = -1 } },
	{ MODKEY,                       XK_h,      setmfact,       {.f = -0.05} },
	{ MODKEY,                       XK_l,      setmfact,       {.f = +0.05} },
	{ MODKEY,                       XK_Return, zoom,           {0} },
	{ MODKEY,                       XK_Tab,    view,           {0} },
	{ MODKEY,                       XK_w,      killclient,     {0} },
	{ MODKEY,                       XK_t,      setlayout,      {.v = &layouts[0]} },
	{ MODKEY,                       XK_f,      setlayout,      {.v = &layouts[1]} },
	{ MODKEY,                       XK_m,      setlayout,      {.v = &layouts[2]} },
	{ MODKEY,                       XK_space,  setlayout,      {0} },
	{ MODKEY|ShiftMask,             XK_space,  togglefloating, {0} },
	{ MODKEY,                       XK_0,      view,           {.ui = ~0 } },
	{ MODKEY|ShiftMask,             XK_0,      tag,            {.ui = ~0 } },
	{ MODKEY,                       XK_comma,  focusmon,       {.i = -1 } },
	{ MODKEY,                       XK_period, focusmon,       {.i = +1 } },
	{ MODKEY|ShiftMask,             XK_comma,  tagmon,         {.i = -1 } },
	{ MODKEY|ShiftMask,             XK_period, tagmon,         {.i = +1 } },
	TAGKEYS(                        XK_1,                      0)
	TAGKEYS(                        XK_2,                      1)
	TAGKEYS(                        XK_3,                      2)
	TAGKEYS(                        XK_4,                      3)
	TAGKEYS(                        XK_5,                      4)
/*	TAGKEYS(                        XK_6,                      5)
	TAGKEYS(                        XK_7,                      6)
	TAGKEYS(                        XK_8,                      7)
	TAGKEYS(                        XK_9,                      8)
*/	{ MODKEY|ShiftMask,             XK_q,      quit,           {0} },
};

/* button definitions */
static const Button buttons[] = {
	{ ClkLtSymbol,          0,              Button1,        setlayout,      {0} },
	{ ClkLtSymbol,          0,              Button3,        setlayout,      {.v = &layouts[2]} },
	{ ClkWinTitle,          0,              Button2,        zoom,           {0} },
	{ ClkStatusText,        0,              Button2,        spawn,          {.v = termcmd } },
	{ ClkClientWin,         MODKEY,         Button1,        movemouse,      {0} },
	{ ClkClientWin,         MODKEY,         Button2,        togglefloating, {0} },
	{ ClkClientWin,         MODKEY,         Button3,        resizemouse,    {0} },
	{ ClkTagBar,            0,              Button1,        view,           {0} },
	{ ClkTagBar,            0,              Button3,        toggleview,     {0} },
	{ ClkTagBar,            MODKEY,         Button1,        tag,            {0} },
	{ ClkTagBar,            MODKEY,         Button3,        toggletag,      {0} },
};
EOF
    # Wire up Super+Shift+f for fullscreen if that patch applied (Super+f
    # is already the floating-layout binding).
    if [ "$dwm_fullscreen_applied" = "yes" ]; then
      sed -i '/spawn,          {.v = lockcmd } },/a\	{ MODKEY|ShiftMask,             XK_f,      fullscreen,     {0} },' "$SRC_DIR/dwm/config.h"
    fi
  fi
  # Self-heal an older config.h from before dwm.c required `refreshrate`.
  if [ -f "$SRC_DIR/dwm/config.h" ] && ! grep -q 'refreshrate' "$SRC_DIR/dwm/config.h"; then
    echo 'static const int refreshrate = 120; /* added by setup-pi-desktop.sh: dwm.c has required this since Aug 2025 */' >> "$SRC_DIR/dwm/config.h"
    log "Patched existing dwm/config.h to add the now-required refreshrate declaration."
  fi
  # Self-heal an older config.h from before the Super+r radio keybind.
  if [ -f "$SRC_DIR/dwm/config.h" ] && ! grep -q 'radiomenu' "$SRC_DIR/dwm/config.h"; then
    sed -i '/static const char \*usbmenu\[\]/a static const char *radiomenu[] = { "radiomenu", NULL };' "$SRC_DIR/dwm/config.h"
    sed -i '/XK_u,      spawn,          {.v = usbmenu } },/a\	{ MODKEY,                       XK_r,      spawn,          {.v = radiomenu } },' "$SRC_DIR/dwm/config.h"
    log "Patched existing dwm/config.h to add the Super+r radio-station keybinding."
  fi
  build_and_install "$SRC_DIR/dwm" || true

  # --- dmenu: fuzzymatch patch, then customized config.h ---
  clone_or_update https://git.suckless.org/dmenu "$SRC_DIR/dmenu"
  if [ "$CLONE_OR_UPDATE_FRESH" -eq 1 ]; then
    try_patch "$SRC_DIR/dmenu" \
      "https://tools.suckless.org/dmenu/patches/fuzzymatch/dmenu-fuzzymatch-5.3.diff" \
      "dmenu fuzzymatch" || true
  fi
  if [ ! -f "$SRC_DIR/dmenu/config.h" ]; then
    cat > "$SRC_DIR/dmenu/config.h" <<'EOF'
/* See LICENSE file for copyright and license details. */
/* Default settings; can be overriden by command line. */

static int topbar = 1;                      /* -b  option; if 0, dmenu appears at bottom     */
static int fuzzy  = 1;                      /* -F  option; if 0, dmenu doesn't use fuzzy matching */
/* -fn option overrides fonts[0]; default X11 font or font set */
static const char *fonts[] = {
	"monospace:size=10"
};
static const char *prompt      = NULL;      /* -p  option; prompt to the left of input field */
static const char *colors[SchemeLast][2] = {
	/*     fg         bg       */
	[SchemeNorm] = { "#bbbbbb", "#222222" },
	[SchemeSel] = { "#eeeeee", "#005577" },
	[SchemeOut] = { "#000000", "#00ffff" },
};
/* -l option; if nonzero, dmenu uses vertical list with given number of lines */
static unsigned int lines      = 0;

/*
 * Characters not considered part of a word while deleting words
 * for example: " /?\"&[]"
 */
static const char worddelimiters[] = " ";
EOF
  fi
  build_and_install "$SRC_DIR/dmenu" || true

  # --- slock: message patch, then vanilla auto-generated config.h ---
  clone_or_update https://git.suckless.org/slock "$SRC_DIR/slock"
  if [ "$CLONE_OR_UPDATE_FRESH" -eq 1 ]; then
    try_patch "$SRC_DIR/slock" \
      "https://tools.suckless.org/slock/patches/message/slock-message-20191002-b46028b.diff" \
      "slock message" || true
  fi
  build_and_install "$SRC_DIR/slock" || true

  # --- st: scrollback patches, then config.h with font/shell tweaks ---
  clone_or_update https://git.suckless.org/st "$SRC_DIR/st"
  if [ "$CLONE_OR_UPDATE_FRESH" -eq 1 ]; then
    if try_patch "$SRC_DIR/st" \
      "https://st.suckless.org/patches/scrollback/st-scrollback-0.9.2.diff" \
      "st scrollback"; then
      try_patch "$SRC_DIR/st" \
        "https://st.suckless.org/patches/scrollback/st-scrollback-mouse-0.9.2.diff" \
        "st scrollback-mouse" || true
    fi
  fi
  if [ ! -f "$SRC_DIR/st/config.h" ]; then
    cp "$SRC_DIR/st/config.def.h" "$SRC_DIR/st/config.h"
    sed -i 's#^static char \*font = .*#static char *font = "Cascadia Code:size=14:antialias=true:autohint=true";#' "$SRC_DIR/st/config.h"
    # `shell` is st's last-resort fallback (after -e, $SHELL, /etc/passwd)
    # — set to fish so st works before you've run chsh (still manual).
    sed -i 's#^static char \*shell = .*#static char *shell = "/usr/bin/fish";#' "$SRC_DIR/st/config.h"
  fi
  build_and_install "$SRC_DIR/st" || true

  # --- slstatus: date/time only, e.g. "Thu Jul 9 20:20" ---
  clone_or_update https://git.suckless.org/slstatus "$SRC_DIR/slstatus"
  if [ ! -f "$SRC_DIR/slstatus/config.h" ]; then
    cat > "$SRC_DIR/slstatus/config.h" <<'EOF'
/* interval between updates (in ms) */
const unsigned int interval = 1000;

/* text to show if no value can be retrieved */
static const char unknown_str[] = "n/a";

/* maximum output string length */
#define MAXLEN 2048

static const struct arg args[] = {
	/* function format          argument */
	{ datetime,     "%s",       " %a %b %-d %H:%M " },
};
EOF
  fi
  build_and_install "$SRC_DIR/slstatus" || true
}

# ---------------------------------------------------------------------------
section_wallpaper() {
  log "wallpaper"
  local src=""
  for cand in "$SCRIPT_DIR/wallpaper.jpg" "$SCRIPT_DIR/wallpaper.jpeg" "$SCRIPT_DIR/wallpaper.png"; do
    [ -f "$cand" ] && src="$cand" && break
  done
  if [ -z "$src" ]; then
    warn "No wallpaper.jpg/.jpeg/.png found next to this script — skipping."
    warn "Drop one alongside setup-pi-desktop.sh (named wallpaper.jpg/.png) and rerun to pick it up."
    return
  fi
  mkdir -p "$HOME/.config"
  cp "$src" "$HOME/.config/wallpaper${src##*/wallpaper}"
  log "Installed wallpaper to ~/.config/wallpaper${src##*/wallpaper} (set via xwallpaper in start-dwm)"
}

# ---------------------------------------------------------------------------
# install_dotfile <src> <dest>: backs up an existing, DIFFERENT dest before
# overwriting — never clobbers customization silently, but a rerun still
# picks up an updated dotfile.
install_dotfile() {
  local src="$1" dest="$2"
  if [ ! -f "$src" ]; then
    warn "$(basename "$src") not found next to this script — skipping. Drop it alongside setup-pi-desktop.sh and rerun to pick it up."
    return
  fi
  if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
    cp "$dest" "$dest.bak-$(date +%Y%m%d-%H%M%S)"
    log "Backed up existing $(basename "$dest") before replacing it"
  fi
  cp "$src" "$dest"
  log "Installed $(basename "$dest")"
}

section_dotfiles() {
  log "dotfiles: bashrc / bash_functions / bash_aliases"
  install_dotfile "$SCRIPT_DIR/bashrc"         "$HOME/.bashrc"
  install_dotfile "$SCRIPT_DIR/bash_functions" "$HOME/.bash_functions"
  install_dotfile "$SCRIPT_DIR/bash_aliases"   "$HOME/.bash_aliases"

  log "clipboard: pbcopy/pbpaste (xclip wrappers) + imgview (nsxiv wrapper) + screenshot (scrot wrapper)"
  mkdir -p "$LOCAL_BIN" "$HOME/Pictures"

  cat > "$LOCAL_BIN/pbcopy" <<'EOF'
#!/bin/sh
# macOS-style pbcopy: stdin -> X clipboard
exec xclip -selection clipboard -in
EOF
  chmod +x "$LOCAL_BIN/pbcopy"

  cat > "$LOCAL_BIN/pbpaste" <<'EOF'
#!/bin/sh
# macOS-style pbpaste: X clipboard -> stdout
exec xclip -selection clipboard -out
EOF
  chmod +x "$LOCAL_BIN/pbpaste"

  cat > "$LOCAL_BIN/imgview" <<'EOF'
#!/bin/sh
# dwm keybind (Super+v). Opens ~/Pictures in nsxiv thumbnail mode (t to
# toggle, hjkl/arrows to navigate, Return for full size), or pass a path.
exec nsxiv -t "${1:-$HOME/Pictures}"
EOF
  chmod +x "$LOCAL_BIN/imgview"

  cat > "$LOCAL_BIN/screenshot" <<'EOF'
#!/bin/sh
# dwm keybinds: Print = full screen, Super+Print = select region/window.
# Saves under ~/Pictures/Screenshots and copies to the clipboard.
DIR="$HOME/Pictures/Screenshots"
mkdir -p "$DIR"
FILE="$DIR/$(date +%Y-%m-%d-%H%M%S).png"

if [ "$1" = "select" ]; then
	scrot -s "$FILE" || exit 0
else
	scrot "$FILE"
fi

[ -f "$FILE" ] && xclip -selection clipboard -t image/png -i "$FILE"
EOF
  chmod +x "$LOCAL_BIN/screenshot"

  cat > "$LOCAL_BIN/usbmenu" <<'EOF'
#!/bin/sh
# dwm keybind (Super+u): dmenu-driven mount/unmount for USB drives, for
# manual mount after unplugging, or safely detaching before pulling one.
set -eu

list_unmounted() {
	lsblk -rno NAME,RM,TYPE,MOUNTPOINT | awk '$2=="1" && $3=="part" && $4=="" {print "/dev/"$1}'
}
list_mounted() {
	lsblk -rno NAME,RM,TYPE,MOUNTPOINT | awk '$2=="1" && $3=="part" && $4!="" {print "/dev/"$1" -> "$4}'
}

action=$(printf 'mount\numount (+ eject)' | dmenu -i -p "USB drive:")
[ -z "$action" ] && exit 0

case "$action" in
mount)
	dev=$(list_unmounted | dmenu -i -p "Mount which device?")
	[ -z "$dev" ] && exit 0
	udisksctl mount -b "$dev"
	;;
"unmount (+ eject)")
	sel=$(list_mounted | dmenu -i -p "Unmount which device?")
	[ -z "$sel" ] && exit 0
	dev=${sel%% *}
	udisksctl unmount -b "$dev"
	udisksctl power-off -b "$dev" 2>/dev/null || true
	;;
esac
EOF
  chmod +x "$LOCAL_BIN/usbmenu"

  log "radio: dmenu station picker (Super+r)"
  # Station list lives outside $LOCAL_BIN, in ~/.config -- created once
  # with these defaults, then left alone so it's yours to edit freely.
  mkdir -p "$HOME/.config/radiomenu"
  if [ ! -f "$HOME/.config/radiomenu/stations" ]; then
    cat > "$HOME/.config/radiomenu/stations" <<'EOF'
Antenne Vorarlberg|http://web.radio.antennevorarlberg.at/av-2000er/stream/mp3?aggregator=icecastdirectory
Radio Zwickau|http://web.radio.radiozwickau.de/radiozwickau-tophits/stream/mp3?aggregator=icecastdirectory
Kathy Radio|http://kathy.torontocast.com:2980/stream
EOF
    log "Installed default radio station list to ~/.config/radiomenu/stations (edit freely, one 'Name|URL' per line)"
  fi

  cat > "$LOCAL_BIN/radiomenu" <<'EOF'
#!/bin/sh
# dwm keybind (Super+r): dmenu-driven internet radio station picker.
# Reads ~/.config/radiomenu/stations ("Name|URL" per line, edit freely --
# only created once, never overwritten). Only one station plays at a
# time: picking one stops whatever cvlc is already running.
set -eu
STATIONS="$HOME/.config/radiomenu/stations"

if [ ! -s "$STATIONS" ]; then
	printf 'No stations configured (~/.config/radiomenu/stations)' | dmenu -p "Radio:"
	exit 0
fi

choice=$(cut -d'|' -f1 "$STATIONS" | { cat; echo Stop; } | dmenu -i -p "Radio:")
[ -z "$choice" ] && exit 0

# cvlc is a symlink to vlc on some setups, a wrapper script on others --
# either way its own exec'd process shows up as one of these two names.
pkill -x vlc >/dev/null 2>&1 || true
pkill -x cvlc >/dev/null 2>&1 || true
[ "$choice" = "Stop" ] && exit 0

url=$(awk -F'|' -v name="$choice" '$1==name{print $2; exit}' "$STATIONS")
[ -z "$url" ] && exit 0

cvlc "$url" >/dev/null 2>&1 &
EOF
  chmod +x "$LOCAL_BIN/radiomenu"

  log "pdf: zathura set as the default PDF reader"
  if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default org.pwmt.zathura.desktop application/pdf
  else
    warn "xdg-mime not found (xdg-utils missing?) — set zathura as your PDF handler manually: xdg-mime default org.pwmt.zathura.desktop application/pdf"
  fi
}

# ---------------------------------------------------------------------------
section_chromium() {
  # Cleans up a leftover Vimium force-install policy from an earlier run
  # (Vimium was tried, then dropped) — no-op on a fresh install.
  if [ -f /etc/chromium/policies/managed/vimium.json ]; then
    log "chromium: removing the old Vimium force-install policy"
    sudo rm -f /etc/chromium/policies/managed/vimium.json
  fi
}

# ---------------------------------------------------------------------------
section_login_manager() {
  log "login manager: greetd + tuigreet"
  # (Package install happens in section_packages — nothing to install
  # here, just configuration.)

  # Disable a from-source ly install from an even earlier version of this
  # script, if present, so it doesn't fight greetd for the VT.
  if systemctl is-enabled --quiet ly@tty1.service 2>/dev/null; then
    sudo systemctl disable --now ly@tty1.service 2>/dev/null || true
    log "Disabled the previously-enabled ly@tty1.service (replaced by greetd)."
  fi

  sudo tee /usr/local/bin/start-dwm >/dev/null <<'EOF'
#!/bin/sh
# Autostart wrapper for dwm, invoked via /usr/share/xsessions/dwm.desktop
# (tuigreet's xsession-wrapper runs this through startx). dwm doesn't
# source .xinitrc, so this is where the bar/wallpaper/idle-lock start.
#
# greetd doesn't source shell rc files — export PATH explicitly or
# ~/.local/bin tools won't resolve when dwm spawns them by name.
export PATH="$HOME/.local/bin:$PATH"
for f in "$HOME/.config/wallpaper.jpg" "$HOME/.config/wallpaper.jpeg" "$HOME/.config/wallpaper.png"; do
  if [ -f "$f" ]; then
    xwallpaper --zoom "$f" &
    break
  fi
done
slstatus &
udiskie --no-tray &
xset s 600
# slock is non-forking, doesn't handle --transfer-sleep-lock — pair with
# plain xss-lock instead.
xss-lock -- slock &
exec dwm
EOF
  sudo chmod +x /usr/local/bin/start-dwm

  sudo mkdir -p /usr/share/xsessions
  sudo tee /usr/share/xsessions/dwm.desktop >/dev/null <<'EOF'
[Desktop Entry]
Name=dwm
Comment=Dynamic window manager (slstatus + xss-lock via start-dwm)
Exec=/usr/local/bin/start-dwm
Type=Application
EOF

  # Silences Xorg's own startup banner (version/log-file info it prints to
  # stderr before taking over the VT) — same content still lands in
  # Xorg's own log file, just not flashed on screen at login.
  sudo tee /usr/local/bin/xsession-wrapper >/dev/null <<'EOF'
#!/bin/sh
# tuigreet's --xsession-wrapper: same as its default ("startx
# /usr/bin/env"), just with Xorg's console output silenced.
exec startx /usr/bin/env "$@" >/dev/null 2>&1
EOF
  sudo chmod +x /usr/local/bin/xsession-wrapper

  # dpkg check, not `command -v`: confirms the package actually installed.
  if dpkg -s greetd >/dev/null 2>&1 && dpkg -s tuigreet >/dev/null 2>&1; then
    # tuigreet auto-discovers dwm.desktop from /usr/share/xsessions.
    # Debian's greetd package doesn't create the "greeter" user its own
    # default config.toml depends on — create it ourselves, idempotently.
    if ! id greeter >/dev/null 2>&1; then
      sudo useradd --system --no-create-home --shell /usr/sbin/nologin -G video greeter
      log "Created the 'greeter' system user (Debian's greetd package doesn't do this itself)."
    fi
    sudo mkdir -p /var/cache/tuigreet
    sudo chown greeter:greeter /var/cache/tuigreet
    sudo chmod 0755 /var/cache/tuigreet

    sudo mkdir -p /etc/greetd
    sudo tee /etc/greetd/config.toml >/dev/null <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --remember --remember-session --time --xsession-wrapper /usr/local/bin/xsession-wrapper"
user = "greeter"
EOF

    # Debian's greetd.service unit hardcodes tty7; ours uses vt=1 above to
    # land on-screen immediately. Override After=/Conflicts= to match, and
    # wait for cloud-init.target so its first-boot console messages don't
    # garble tuigreet's already-drawn prompt on tty1.
    sudo mkdir -p /etc/systemd/system/greetd.service.d
    sudo tee /etc/systemd/system/greetd.service.d/override.conf >/dev/null <<'EOF'
[Unit]
After=
After=systemd-user-sessions.service plymouth-quit-wait.service getty@tty1.service cloud-init.target
Conflicts=
Conflicts=getty@tty1.service
EOF
    sudo systemctl daemon-reload

    # greetd.service is aliased to display-manager.service, started only
    # by graphical.target — not the multi-user.target Lite boots to by
    # default. Without this, greetd stays enabled but never actually runs.
    sudo systemctl set-default graphical.target

    sudo systemctl disable getty@tty1.service 2>/dev/null || true
    sudo systemctl reset-failed greetd.service 2>/dev/null || true
    sudo systemctl enable greetd.service
    log "greetd enabled on tty1 — will show at next boot. Not starting it now over this session."
  else
    warn "greetd isn't installed, so its login-screen service wasn't enabled. SSH still works — fix the apt install above and re-run this script when ready."
  fi
}

# ---------------------------------------------------------------------------
section_python_tools() {
  log "python/uv/ruff"
  if ! command -v uv >/dev/null 2>&1 && [ ! -x "$LOCAL_BIN/uv" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  export PATH="$LOCAL_BIN:$PATH"
  if [ "$UPGRADE" -eq 1 ] && uv tool list 2>/dev/null | grep -q '^ruff '; then
    uv tool upgrade ruff --quiet || warn "ruff upgrade via uv failed — retry manually with 'uv tool upgrade ruff'"
  else
    uv tool install ruff --quiet || warn "ruff install via uv failed — retry manually with 'uv tool install ruff'"
  fi
}

# ---------------------------------------------------------------------------
# install_github_release_binary <owner/repo> <asset-substring> <binary-name>
# Under --upgrade, always re-fetches the latest release and overwrites
# whatever's on $LOCAL_BIN — otherwise skips if already installed.
install_github_release_binary() {
  local repo="$1" pattern="$2" binname="$3"
  if [ "$UPGRADE" -ne 1 ] && { command -v "$binname" >/dev/null 2>&1 || [ -x "$LOCAL_BIN/$binname" ]; }; then
    log "$binname already installed"
    return
  fi
  log "Fetching latest $binname release for $pattern"
  local url
  # `|| true`: under pipefail, grep finding no matching asset (exit 1) would
  # otherwise be treated as a hard error by set -e instead of falling
  # through to the empty-$url warning below.
  url=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
        | grep -o "\"browser_download_url\": *\"[^\"]*${pattern}[^\"]*\"" \
        | head -n1 | sed -E 's/.*"([^"]+)"/\1/') || true
  if [ -z "$url" ]; then
    warn "Couldn't find a $repo release asset matching '$pattern' — install $binname manually."
    return
  fi
  local tmp; tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/asset"
  tar -xf "$tmp/asset" -C "$tmp"
  local found
  found=$(find "$tmp" -maxdepth 2 -type f -name "$binname" | head -n1)
  if [ -z "$found" ]; then
    warn "Downloaded $repo release but couldn't find a '$binname' binary inside it."
    rm -rf "$tmp"
    return
  fi
  install -m755 "$found" "$LOCAL_BIN/$binname"
  rm -rf "$tmp"
  log "Installed $binname to $LOCAL_BIN"
}

section_extra_binaries() {
  # zellij skipped deliberately: dwm's tags already give multiple
  # workspaces, so a multiplexer's split-pane view is mostly redundant.
  install_github_release_binary "typst/typst" "aarch64-unknown-linux-musl.tar.xz" "typst"
}

# ---------------------------------------------------------------------------
section_neovim() {
  log "neovim: vim-plug + plugins"
  mkdir -p "$HOME/.config/nvim" "$HOME/.local/share/nvim/site/autoload" "$HOME/.config/nvim/UltiSnips"

  if [ ! -f "$HOME/.local/share/nvim/site/autoload/plug.vim" ]; then
    curl -fLo "$HOME/.local/share/nvim/site/autoload/plug.vim" --create-dirs \
      https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  fi

  if [ ! -f "$HOME/.config/nvim/init.vim" ]; then
    cat > "$HOME/.config/nvim/init.vim" <<'EOF'
call plug#begin('~/.local/share/nvim/plugged')
Plug 'jiangmiao/auto-pairs'
Plug 'itchyny/lightline.vim'
Plug 'SirVer/ultisnips'
Plug 'tpope/vim-sensible'
Plug 'tpope/vim-surround'
Plug 'patstockwell/vim-monokai-tasty'
Plug 'kaarmu/typst.vim'
Plug 'ckunte/typst-snippets-vim'
call plug#end()

syntax on
set number
set termguicolors
colorscheme vim-monokai-tasty

let g:lightline = { 'colorscheme': 'monokai_tasty' }

let g:UltiSnipsSnippetsDir = expand('~/.config/nvim/UltiSnips')
let g:UltiSnipsExpandTrigger = '<tab>'
let g:UltiSnipsJumpForwardTrigger = '<c-j>'
let g:UltiSnipsJumpBackwardTrigger = '<c-k>'
EOF
  fi

  nvim --headless "+PlugInstall --sync" +qa || warn "PlugInstall had trouble — run ':PlugInstall' manually inside nvim."

  if [ "$UPGRADE" -eq 1 ]; then
    nvim --headless "+PlugUpdate --sync" +qa || warn "PlugUpdate had trouble — run ':PlugUpdate' manually inside nvim."
  fi
}

# ---------------------------------------------------------------------------
section_shell() {
  log "fish: PATH + quiet greeting (shell NOT switched automatically)"
  mkdir -p "$HOME/.config/fish"
  if ! grep -q 'setup-pi-desktop.sh' "$HOME/.config/fish/config.fish" 2>/dev/null; then
    {
      echo ""
      echo "# added by setup-pi-desktop.sh"
      echo "fish_add_path -m $HOME/.local/bin"
      echo "set -g fish_greeting"
    } >> "$HOME/.config/fish/config.fish"
  fi
}

# ---------------------------------------------------------------------------
section_firewall() {
  log "ufw: default-deny incoming, SSH explicitly allowed first"
  sudo ufw allow OpenSSH
  sudo ufw --force enable
}

# ---------------------------------------------------------------------------
section_summary() {
  cat <<EOF

================================================================
 Done.

 Added dwm keybinds (MODKEY = Super/Win):
   Super+Shift+Return   st (terminal)
   Super+p              dmenu_run (-i case-insensitive; -F fuzzy if patch applied)
   Super+b              chromium -> https://lite.cnn.com/en (--no-first-run --no-default-browser-check)
   Super+Ctrl+l         slock (manual lock)
   Super+v              imgview -> nsxiv, thumbnails ~/Pictures (t to toggle grid)
   Super+u              usbmenu -> dmenu mount/unmount(+eject) for USB drives
   Super+r              radiomenu -> dmenu internet radio picker (~/.config/radiomenu/stations)
   Print                screenshot -> full screen, saved to ~/Pictures/Screenshots + clipboard
   Super+Print          screenshot -> click-drag a region, or click a window
   F10 / F11 / F12      mute / volume down / volume up (wpctl, capped at 100%)
   Super+Shift+f        fullscreen toggle (only if the fullscreen patch applied — check the build log above)
   idle lock            10 min via xset+xss-lock (edit the timeout in /usr/local/bin/start-dwm to change)

 Patches attempted on dwm/dmenu/st/slock — check the log above for which
 ones actually applied (pertag, fullscreen, fuzzymatch, scrollback,
 scrollback-mouse, message). Any that failed were skipped safely; you're
 running vanilla suckless for those, not a broken build.

 Fonts: dwm/dmenu bar = Cascadia Code, st = Cascadia Code.

 Clipboard: pbcopy/pbpaste (xclip wrappers) are on your PATH — pipe into
 pbcopy, read from pbpaste, same as macOS.

 Dotfiles: ~/.bashrc, ~/.bash_aliases, ~/.bash_functions installed (bash
 stays well-configured as a fallback even with fish as your daily driver).
 Any pre-existing versions were backed up alongside with a .bak-<timestamp>
 suffix rather than silently overwritten.

 If any suckless tool failed to build above, the rest of the setup still
 ran — scroll back for the specific warning, fix config.h, and re-run this
 script (it's idempotent; already-working tools won't be touched again).

 NVMe (official M.2 HAT+): PCIe enabled at Gen 3 in config.txt, and the
 bootloader's BOOT_ORDER set to try the SD card, then the NVMe drive, then
 USB last (0xf461, matching raspi-config's "B1" preset) — normal day-to-
 day boot is from NVMe; insert a rescue SD card to override it (a USB
 stick won't, since NVMe is tried first whenever it's present). The
 bootloader's own "Configure this Raspberry Pi" boot-progress screen is
 also silenced (DISABLE_HDMI=1) — it only draws that screen to HDMI, so
 nothing here changes which device actually boots. Check all three after
 reboot with 'cat /boot/firmware/config.txt' and 'sudo rpi-eeprom-config'.

 Audio: pipewire/wireplumber installed (a bare Lite install ships no sound
 server at all, unlike the official Desktop image). The Pi 5 has no analog
 3.5mm jack — audio out is HDMI-only on this board, one sink per connected
 display. For an aux speaker, route it through your monitor's own
 audio-out passthrough jack, or add a USB audio adapter/DAC for output the
 Pi drives directly. Check sinks with 'wpctl status', switch the default
 with 'wpctl set-default <id>'.

 Xorg: /etc/X11/xorg.conf.d/99-vc4.conf pins the vc4 display device as
 primary (fixes a Pi 5 quirk where two DRM devices exist and Xorg can pick
 the wrong one, killing the session with "Cannot run in framebuffer mode"
 right after login). Already applied — no reboot needed for this one, just
 log in normally. Xorg's own startup banner (version/log-file info it
 prints before taking over the display) is also suppressed via a custom
 tuigreet --xsession-wrapper (/usr/local/bin/xsession-wrapper) — it's still
 all in Xorg's own log file, just not flashed on screen at login.

 Quiet boot: kernel/systemd console output and the firmware rainbow splash
 are suppressed (cmdline.txt + config.txt), including systemd's own status
 lines (systemd.show_status=0 — otherwise routine things like the root
 filesystem's fsck summary still print) — tuigreet should be the first
 thing you see. console=tty1 was left in place on purpose, so a genuine
 boot failure still shows up on screen instead of a silent black screen.

 USB drives: udiskie auto-mounts a drive the moment you plug it in (usually
 under /media/$USER/<LABEL>) — no dwm involvement needed, plug and go.
 Super+u opens a dmenu picker to mount something manually, or to unmount +
 power-off a drive before you physically pull it.

 Upgrading: this run only installed/configured what was missing. To
 refresh already-installed software (suckless tools rebuilt against
 latest upstream with patches reapplied, uv-managed tools, typst, vim-plug
 plugins) instead, run: ./setup-pi-desktop.sh --upgrade

 Still manual, on purpose (see PLAN.md):
   - gpg --full-generate-key   then   pass init <key-id>
   - chsh -s /usr/bin/fish     (only once you've confirmed the session works)
   - review: sudo ufw status verbose

EOF
  if [ "$NEED_REBOOT" -eq 1 ]; then
    echo " Firmware/bootloader config changed (full KMS, PCIe Gen 3, boot"
    echo " order, and/or quiet boot) — reboot required before dwm/greetd,"
    echo " the NVMe changes, or the silent boot take effect:"
    echo "   sudo reboot"
    echo "================================================================"
  else
    echo " Reboot, then log in at the greetd/tuigreet prompt -> dwm."
    echo "================================================================"
  fi
}

# ---------------------------------------------------------------------------
main() {
  section_packages
  section_firmware
  section_boot_order
  section_xorg
  section_quiet_boot
  section_suckless
  section_wallpaper
  section_dotfiles
  section_chromium
  section_login_manager
  section_python_tools
  section_extra_binaries
  section_neovim
  section_shell
  section_firewall
  section_summary
}

main "$@"
