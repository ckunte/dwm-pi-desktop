#!/usr/bin/env bash
#
# setup-pi-desktop.sh
#
# Turns a fresh Raspberry Pi OS Lite (64-bit, Trixie/Debian 13) install on a
# Pi 5 (8GB RAM, NVMe SSD on the official M.2 HAT+) into a minimal dwm/X11
# "pocket desktop": dmenu, slstatus, tuigreet, slock/xss-lock, st, chromium
# (bound to Super+b), plus the CLI toolset requested alongside it. External
# USB drives auto-mount via udiskie, with a Super+u dmenu picker for manual
# mount/unmount. Also enables PCIe Gen 3 for the NVMe HAT (section_firmware)
# and sets the bootloader's boot order to SD card, then USB, then NVMe
# (section_boot_order).
#
# Run as your normal user (NOT root/sudo) — it calls sudo internally only
# where needed. Safe to re-run: every section checks whether its target
# already exists before doing anything.

set -euo pipefail

SRC_DIR="$HOME/src"
LOCAL_BIN="$HOME/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEED_REBOOT=0

log()  { printf '\n==> %s\n' "$1"; }
warn() { printf '\n!!  %s\n' "$1" >&2; }

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
  # xauth: startx (invoked by tuigreet's xsession-wrapper below) shells
  # out to it to set up the X session's magic-cookie auth — not optional here.
  # brightnessctl: handy if you're on an official Pi touchscreen/DSI display,
  # harmless otherwise. greetd/tuigreet: the login manager — prebuilt packages,
  # no compiler needed, see section_login_manager below. rpi-eeprom: ships
  # rpi-eeprom-config/rpi-eeprom-update, used in section_firmware to set the
  # bootloader boot order — normally preinstalled on Raspberry Pi OS, listed
  # here so the script doesn't assume that. chromium: the browser bound to
  # dwm's Super+b — a prebuilt apt package (surf, the original suckless-built
  # browser, was dropped earlier for the same pkg-config build headaches that
  # made qutebrowser, then chromium, the simpler prebuilt choice). No vim
  # keybindings — plain Chromium, no extensions force-installed. The
  # --no-first-run/--no-default-browser-check flags on dwm's browser[]
  # command are just there to skip the setup-wizard/default-browser nag on
  # every launch; Chromium has no config file to hide its tab strip/toolbar
  # the way qutebrowser did, so that's the extent of the "sparse" chrome
  # available here. scrot: bound to
  # Print/Super+Print (see the `screenshot` wrapper in section_dotfiles) —
  # a prebuilt package, no compositor or GL-based selection tool (slop, as
  # maim would need) required, so it works on plain X11/dwm with no extras.
  # xdg-utils: ships xdg-mime, used in section_dotfiles to set zathura as
  # the default PDF handler — not guaranteed present on a minimal Xorg/dwm
  # install the way it would be pulled in by a full desktop-environment
  # metapackage, so it's listed explicitly rather than assumed. udisks2:
  # the mount/unmount backend (udisksctl) — dwm itself has no idea a drive
  # was plugged in, this is what actually does the mounting; Debian's
  # default udisks2 polkit policy lets the local active user mount/unmount
  # removable media without a password, so no polkit agent is needed on top
  # of it. udiskie: a tiny udisks2 frontend, started in start-dwm
  # (section_login_manager) with --no-tray since dwm's bar has no systray —
  # it auto-mounts a USB drive the moment it's plugged in. The Super+u
  # dmenu picker (see the `usbmenu` script in section_dotfiles) is there for
  # manual mount/unmount/eject on top of that, mainly for safely detaching a
  # drive before pulling it. pipewire/pipewire-pulse/pipewire-alsa/
  # wireplumber: the sound server — a bare Raspberry Pi OS Lite install has
  # none at all (unlike the official Desktop image, which pulls this in via
  # its desktop metapackage), so without it apps like chromium/vlc have no
  # audio backend to talk to and just play silently, on HDMI or the 3.5mm
  # jack alike. Debian's pipewire packages enable their own systemd --user
  # socket units on install, so this needs no extra start-dwm wiring beyond
  # a normal PAM-backed login (which greetd provides) setting up the user's
  # systemd/D-Bus session. alsa-utils: aplay/amixer/alsamixer/speaker-test,
  # for confirming ALSA sees your output device(s) independent of pipewire
  # when troubleshooting.

  # Debian renames these two to avoid clashes; symlink the names you asked for.
  [ -e "$LOCAL_BIN/bat" ] || ln -s /usr/bin/batcat "$LOCAL_BIN/bat"
  [ -e "$LOCAL_BIN/fd" ]  || ln -s /usr/bin/fdfind "$LOCAL_BIN/fd"
}

# ---------------------------------------------------------------------------
section_firmware() {
  log "firmware: checking full-KMS (vc4-kms-v3d) is enabled"
  local cfg=""
  if [ -f /boot/firmware/config.txt ]; then cfg=/boot/firmware/config.txt
  elif [ -f /boot/config.txt ]; then cfg=/boot/config.txt
  fi

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

  log "firmware: checking the analog audio jack (dtparam=audio=on) is enabled"
  # dtparam=audio=on enables the Pi's onboard audio codec that feeds the
  # 3.5mm jack (an aux speaker plugged in there needs this) — separate from
  # HDMI audio to a monitor, which rides on vc4-kms-v3d above and needs no
  # extra flag. Normally on by default on Raspberry Pi OS images, so this
  # is just belt-and-suspenders in case it was ever turned off by hand.
  if grep -q '^dtparam=audio=on$' "$cfg"; then
    log "Analog audio jack already enabled in $cfg"
  elif grep -q '^dtparam=audio=' "$cfg"; then
    sudo sed -i 's/^dtparam=audio=.*/dtparam=audio=on/' "$cfg"
    NEED_REBOOT=1
    log "Enabled the analog audio jack in $cfg"
  else
    echo 'dtparam=audio=on' | sudo tee -a "$cfg" >/dev/null
    NEED_REBOOT=1
    log "Enabled the analog audio jack in $cfg"
  fi

  log "firmware: enabling PCIe Gen 3 for the NVMe M.2 HAT+"
  # dtparam=pciex1 turns on the Pi 5's external PCIe x1 connector (what the
  # M.2 HAT+'s FPC ribbon plugs into) at the kernel/device-tree level — this
  # is what lets Linux see the NVMe drive at all, separate from whether the
  # bootloader itself can boot from it (that's the EEPROM/BOOT_ORDER side,
  # handled in section_boot_order below). dtparam=pciex1_gen=3 then raises
  # the link from the Gen 2 default to Gen 3 (roughly double the bandwidth).
  # Raspberry Pi's own M.2 HAT+ documentation notes the Pi 5 isn't certified
  # for Gen 3 and that some adapters see occasional link errors at that
  # speed — if the NVMe drive looks flaky after this, drop pciex1_gen back
  # to 2 (or delete the line, which defaults to Gen 2) rather than assuming
  # the drive itself is bad.
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
  log "bootloader: setting boot order to SD card, then USB, then NVMe"
  # Out of the box the Pi 5's BOOT_ORDER is 0xf41: try the SD card, then
  # USB, then stop — NVMe is never tried at all. Since this Pi's OS lives on
  # the NVMe drive, we add NVMe as the final fallback: insert a rescue or
  # alternate SD card or USB stick and it boots that instead; leave both out
  # (normal operation) and it boots NVMe as before.
  #
  # BOOT_ORDER is a hex string read right to left, one digit per device
  # tried, in order: 1=SD card, 4=USB-MSD, 6=NVMe, f=restart the sequence
  # if nothing bootable was found. So 0xf641, read right to left, is
  # 1 (SD) -> 4 (USB) -> 6 (NVMe) -> f (restart): SD, then USB, then NVMe.
  if ! command -v rpi-eeprom-config >/dev/null 2>&1; then
    warn "rpi-eeprom-config not found (rpi-eeprom package missing?) — skipping boot-order setup. Install rpi-eeprom and re-run, or set it yourself with 'sudo -E rpi-eeprom-config --edit' (BOOT_ORDER=0xf641)."
    return
  fi

  local wanted="0xf641"
  local current=""
  # `|| true`: same pipefail hazard as install_github_release_binary above —
  # sed finding no BOOT_ORDER= line (shouldn't happen, but be defensive)
  # would otherwise abort the whole script under set -e.
  current=$(sudo rpi-eeprom-config 2>/dev/null | sed -n 's/^BOOT_ORDER=//p' | tr -d '[:space:]') || true

  if [ "$current" = "$wanted" ]; then
    log "Boot order is already $wanted (SD, USB, NVMe)"
    return
  fi

  local tmp
  tmp=$(mktemp)
  if ! sudo rpi-eeprom-config --out "$tmp"; then
    warn "Couldn't read the current EEPROM config — skipping boot-order setup. Set it yourself with 'sudo -E rpi-eeprom-config --edit' (BOOT_ORDER=0xf641)."
    sudo rm -f "$tmp"
    return
  fi

  if grep -q '^BOOT_ORDER=' "$tmp"; then
    sudo sed -i "s/^BOOT_ORDER=.*/BOOT_ORDER=$wanted/" "$tmp"
  else
    echo "BOOT_ORDER=$wanted" | sudo tee -a "$tmp" >/dev/null
  fi

  if sudo rpi-eeprom-config --apply "$tmp"; then
    NEED_REBOOT=1
    log "Boot order set to $wanted (SD, USB, NVMe) — takes effect after reboot"
  else
    warn "Failed to apply the new boot order — check the 'rpi-eeprom-config --apply' output above and set it yourself with 'sudo -E rpi-eeprom-config --edit' (BOOT_ORDER=0xf641)."
  fi
  sudo rm -f "$tmp"
}

# ---------------------------------------------------------------------------
section_xorg() {
  log "Xorg: pinning the display GPU (vc4) as primary via OutputClass"
  # Under full KMS the Pi exposes two DRM devices: one owned by the vc4
  # driver (does scanout — actual video output) and one owned by v3d
  # (3D/compute only, no scanout). Which one lands on /dev/dri/card0 isn't
  # fixed. Without a hint, Xorg's "no primary bus or device found" fallback
  # can pick whichever device it enumerated first — if that happens to be
  # v3d, Xorg then tries to bring up the *other* device (the one that can
  # actually display anything) through the legacy fbdev driver as a second,
  # separate framebuffer screen, and fbdev refuses to start without an
  # explicit busID. The whole server then dies with "Cannot run in
  # framebuffer mode. Please specify busIDs for all framebuffer devices.",
  # X exits, and greetd/tuigreet just drops you back to the login prompt —
  # nothing in the dwm/build steps is at fault; this never reaches dwm.
  #
  # This OutputClass rule sidesteps the ambiguous autoprobe entirely: it
  # tells Xorg, unconditionally, to bind the modesetting driver to whichever
  # device the kernel's vc4 driver owns and treat it as the primary GPU —
  # so fbdev never gets pulled in as a second competing screen.
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
    # Self-heal: an earlier run of this script (before systemd.show_status=0
    # was added below) left quiet/loglevel=0 in place without it. quiet on
    # its own only sets systemd's status output to "auto" (suppressed,
    # until a unit takes >1.5s or hits a hiccup) — not fully off — which is
    # exactly why routine things like the root filesystem's fsck summary
    # ("/dev/... clean, N/M files...") still print on a re-run's first
    # boots. Patch it in now rather than requiring cmdline.txt by hand.
    if ! grep -q 'systemd.show_status=0' "$cmdline"; then
      sudo sed -i 's/$/ systemd.show_status=0/' "$cmdline"
      NEED_REBOOT=1
      log "Patched existing $cmdline to add systemd.show_status=0 (silences systemd's own status/fsck lines)."
    fi
  else
    # cmdline.txt must stay a single line — append to it, never write a new
    # line. quiet+loglevel=0 belt-and-suspenders silence kernel messages,
    # vt.global_cursor_default=0 hides the blinking text-console cursor,
    # logo.nologo hides the boot-time penguin logos. systemd.show_status=0
    # goes further than quiet alone: quiet only sets systemd's own status
    # output to "auto" (still shown if a unit takes >1.5s or errors), which
    # is why things like the routine fsck summary on the root filesystem
    # otherwise slip through — that's systemd/fsck writing to the console
    # directly, not something the kernel's loglevel controls. Deliberately
    # NOT removing the existing console=tty1 entry: a genuine boot failure
    # (fsck error, kernel panic) still drops you into an emergency shell on
    # the console regardless of show_status, so this doesn't trade away
    # that safety net — it only quiets the routine "everything's fine" noise.
    sudo sed -i 's/$/ quiet loglevel=0 vt.global_cursor_default=0 logo.nologo systemd.show_status=0/' "$cmdline"
    NEED_REBOOT=1
    log "Added quiet-boot kernel params to $cmdline"
  fi

  local cfg=""
  if [ -f /boot/firmware/config.txt ]; then cfg=/boot/firmware/config.txt
  elif [ -f /boot/config.txt ]; then cfg=/boot/config.txt
  fi

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
clone_or_update() {
  # clone_or_update <url> <dir>
  # Only clones if missing — deliberately does NOT git-pull on rerun.
  # Several of these trees get source patches applied on first build (see
  # try_patch below), and pulling would conflict with those local,
  # uncommitted changes. Delete the directory under ~/src yourself if you
  # want a clean re-clone against latest upstream.
  if [ -d "$2" ]; then
    log "$(basename "$2") source already present, leaving as-is"
  else
    git clone --depth 1 "$1" "$2"
  fi
}

# Best-effort patching: dry-run first, only apply if it applies cleanly,
# otherwise warn and leave the source untouched (vanilla). A patch that
# fails to apply should never abort the build — these are enhancements,
# not requirements. Returns 0 if applied, 1 if skipped.
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

# build_and_install <dir> [extra make-install args...]
# A failed build/install here must never take the rest of the script down
# with it (set -e would otherwise abort everything on the very first
# compile error) — warn clearly and let the caller move on to the next tool.
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
  # NOTE: patches only ever touch a freshly-cloned tree, before config.h
  # exists, so a failed/skipped patch never leaves a half-patched build.
  clone_or_update https://git.suckless.org/dwm "$SRC_DIR/dwm"
  if [ ! -f "$SRC_DIR/dwm/config.h" ]; then
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
/* refresh rate (per second) for client move/resize throttling — added to
 * dwm.c upstream in August 2025 (commit 74edc27); movemouse()/resizemouse()
 * reference this directly, so it must be declared even though it's new. */
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
/* -i = case-insensitive matching, built into vanilla dmenu (always safe).
 * If the fuzzymatch patch applied (see build log), dmenu also understands
 * -F for fuzzy matching — add it here yourself once you've confirmed that,
 * or just type `dmenu_run -F` by hand to try it first. */
static const char *dmenucmd[] = { "dmenu_run", "-i", "-m", dmenumon, "-fn", dmenufont, "-nb", col_gray1, "-nf", col_gray3, "-sb", col_cyan, "-sf", col_gray4, NULL };
static const char *termcmd[]  = { "st", NULL };
static const char *browser[]  = { "chromium", "--no-first-run", "--no-default-browser-check", "https://lite.cnn.com/en", NULL };
static const char *lockcmd[]  = { "slock", NULL };
static const char *imgview[]  = { "imgview", NULL };
static const char *usbmenu[]  = { "usbmenu", NULL };

static const Key keys[] = {
	/* modifier                     key        function        argument */
	{ MODKEY,                       XK_p,      spawn,          {.v = dmenucmd } },
	{ MODKEY|ShiftMask,             XK_Return, spawn,          {.v = termcmd } },
	{ MODKEY,                       XK_b,      spawn,          {.v = browser } },
	{ MODKEY|ControlMask,           XK_l,      spawn,          {.v = lockcmd } },
	{ MODKEY,                       XK_v,      spawn,          {.v = imgview } },
	{ MODKEY,                       XK_u,      spawn,          {.v = usbmenu } },
	{ 0,                             XK_Print,  spawn,          SHCMD("screenshot") },
	{ MODKEY,                        XK_Print,  spawn,          SHCMD("screenshot select") },
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
    # If the fullscreen patch applied, wire up a keybind for it — Super+Shift+f,
    # since Super+f is already taken by the floating-layout binding above.
    if [ "$dwm_fullscreen_applied" = "yes" ]; then
      sed -i '/spawn,          {.v = lockcmd } },/a\	{ MODKEY|ShiftMask,             XK_f,      fullscreen,     {0} },' "$SRC_DIR/dwm/config.h"
    fi
  fi
  # Self-heal: if config.h already existed from an older run of this script
  # (from before dwm.c started requiring `refreshrate`, upstream commit
  # 74edc27, Aug 2025), patch it in now rather than requiring you to delete
  # ~/src/dwm and start over.
  if [ -f "$SRC_DIR/dwm/config.h" ] && ! grep -q 'refreshrate' "$SRC_DIR/dwm/config.h"; then
    echo 'static const int refreshrate = 120; /* added by setup-pi-desktop.sh: dwm.c has required this since Aug 2025 */' >> "$SRC_DIR/dwm/config.h"
    log "Patched existing dwm/config.h to add the now-required refreshrate declaration."
  fi
  build_and_install "$SRC_DIR/dwm" || true

  # --- dmenu: fuzzymatch patch, then customized config.h ---
  clone_or_update https://git.suckless.org/dmenu "$SRC_DIR/dmenu"
  if [ ! -f "$SRC_DIR/dmenu/config.h" ]; then
    try_patch "$SRC_DIR/dmenu" \
      "https://tools.suckless.org/dmenu/patches/fuzzymatch/dmenu-fuzzymatch-5.3.diff" \
      "dmenu fuzzymatch" || true
    # `fuzzy`/`-F` below come from the fuzzymatch patch above. If that patch
    # didn't apply (see build log), vanilla dmenu.c never reads `fuzzy` at
    # all, so this just sits as an unused variable (a harmless compiler
    # warning, not a build failure) rather than breaking the build.
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

  # --- slock: message patch (lock screen shows a message instead of just
  #     blanking), then vanilla auto-generated config.h ---
  clone_or_update https://git.suckless.org/slock "$SRC_DIR/slock"
  if [ ! -f "$SRC_DIR/slock/config.h" ]; then
    try_patch "$SRC_DIR/slock" \
      "https://tools.suckless.org/slock/patches/message/slock-message-20191002-b46028b.diff" \
      "slock message" || true
  fi
  build_and_install "$SRC_DIR/slock" || true

  # --- st: scrollback + scrollback-mouse patches, then vanilla
  #     auto-generated config.h with two targeted tweaks ---
  clone_or_update https://git.suckless.org/st "$SRC_DIR/st"
  if [ ! -f "$SRC_DIR/st/config.h" ]; then
    if try_patch "$SRC_DIR/st" \
      "https://st.suckless.org/patches/scrollback/st-scrollback-0.9.2.diff" \
      "st scrollback"; then
      try_patch "$SRC_DIR/st" \
        "https://st.suckless.org/patches/scrollback/st-scrollback-mouse-0.9.2.diff" \
        "st scrollback-mouse" || true
    fi
    # Materialize config.h from the (maybe-patched) config.def.h ourselves,
    # rather than leaving it to `make`'s auto-copy rule, so we can tweak just
    # the font/shell lines below without hand-duplicating the rest of the
    # file (colors, shortcuts, whatever the scrollback patches added, etc.).
    cp "$SRC_DIR/st/config.def.h" "$SRC_DIR/st/config.h"
    sed -i 's#^static char \*font = .*#static char *font = "Cascadia Code:size=14:antialias=true:autohint=true";#' "$SRC_DIR/st/config.h"
    # config.h's `shell` is st's last-resort fallback (see the precedence
    # comment already in the file: -e flag, then SHELL env var, then
    # /etc/passwd, then this) — set to fish so st launches it directly even
    # before you've run `chsh -s /usr/bin/fish` (still manual, on purpose;
    # see section_summary).
    sed -i 's#^static char \*shell = .*#static char *shell = "/usr/bin/fish";#' "$SRC_DIR/st/config.h"
  fi
  build_and_install "$SRC_DIR/st" || true

  # --- slstatus (customized config.h: date/time only, e.g. "Thu Jul 9 20:20") ---
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
# install_dotfile <src> <dest>
# Backs up an existing, DIFFERENT dest before overwriting it — never clobbers
# customization silently, but still lets a rerun pick up an updated dotfile.
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
# dwm keybind (Super+v) launches this. Opens ~/Pictures in nsxiv's thumbnail
# mode (press t to toggle it, hjkl/arrows to navigate, Return to view full
# size) -- or pass a file/dir yourself: imgview ~/some/other/folder
exec nsxiv -t "${1:-$HOME/Pictures}"
EOF
  chmod +x "$LOCAL_BIN/imgview"

  cat > "$LOCAL_BIN/screenshot" <<'EOF'
#!/bin/sh
# dwm keybinds: Print = full screen, Super+Print = select a region or
# window (scrot's own -s: click-drag an area, or click a window to grab
# just that -- no extra dependency like slop needed). Saves under
# ~/Pictures/Screenshots and copies the image to the clipboard so you can
# paste it straight into whatever you're working on.
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
# dwm keybind (Super+u): dmenu-driven mount/unmount for removable USB
# drives. udiskie (started in start-dwm) already auto-mounts a drive the
# moment it's plugged in -- this is for the cases automount doesn't cover:
# mounting something you unplugged and replugged after saying "unmount", or
# safely detaching a drive (unmount + power-off, so it's OK to physically
# pull) before removing it.
#
# udisksctl needs no root/password here -- Debian's default udisks2 polkit
# policy allows the local active user to mount/unmount removable media
# unprompted.
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

  log "pdf: zathura set as the default PDF reader"
  # xdg-mime just writes an entry into ~/.config/mimeapps.list -- safe to
  # call every run, it overwrites the same line rather than duplicating it.
  if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default org.pwmt.zathura.desktop application/pdf
  else
    warn "xdg-mime not found (xdg-utils missing?) — set zathura as your PDF handler manually: xdg-mime default org.pwmt.zathura.desktop application/pdf"
  fi
}

# ---------------------------------------------------------------------------
section_chromium() {
  # No vim keybindings anymore (Vimium was tried and then removed by
  # request) — this only cleans up the leftover force-install policy from
  # an earlier run of this script, so a re-run actually reflects that and
  # Chromium stops force-installing it on next launch. Nothing to do here
  # on a fresh install where that file was never created.
  if [ -f /etc/chromium/policies/managed/vimium.json ]; then
    log "chromium: removing the old Vimium force-install policy"
    sudo rm -f /etc/chromium/policies/managed/vimium.json
  fi
}

# ---------------------------------------------------------------------------
section_login_manager() {
  log "login manager: greetd + tuigreet"
  # Originally ly, built from source. Dropped it: ly has been a Zig rewrite
  # since v1.0, and while a Pi 5 compiles Zig without much drama, greetd +
  # tuigreet do the exact same job for zero build effort — greetd is a
  # minimal daemon that just execs a "greeter", tuigreet is a small
  # ncurses-style greeter for it, visually and functionally close to what ly
  # gave you — and both are prebuilt packages in Trixie's apt. No compiler,
  # no build step, no reboot-to-find-out-if-it-worked. See PLAN.md for the
  # fuller story (ly is still documented there — useful context on why this
  # changed, even though it's no longer installed).
  # (Package install happens in section_packages, above — greetd/tuigreet are
  # in that list. Nothing to install here, just configuration.)

  # If an earlier run of this script got as far as building ly, it may still
  # be sitting on tty1 — disable it so it doesn't fight greetd for the VT.
  if systemctl is-enabled --quiet ly@tty1.service 2>/dev/null; then
    sudo systemctl disable --now ly@tty1.service 2>/dev/null || true
    log "Disabled the previously-enabled ly@tty1.service (replaced by greetd)."
  fi

  sudo tee /usr/local/bin/start-dwm >/dev/null <<'EOF'
#!/bin/sh
# Autostart wrapper for dwm, invoked via /usr/share/xsessions/dwm.desktop
# (tuigreet's xsession-wrapper, set up below, runs this through `startx`).
# dwm itself doesn't source anything like .xinitrc, so this is where the
# status bar, wallpaper, and idle-lock get started before dwm takes over.
#
# greetd doesn't source your shell rc files, so PATH here is whatever the
# system default is — export this explicitly or anything in ~/.local/bin
# (uv, ruff, typst, imgview, pbcopy/pbpaste) won't resolve when dwm spawns
# it by name.
export PATH="$HOME/.local/bin:$PATH"
for f in "$HOME/.config/wallpaper.jpg" "$HOME/.config/wallpaper.jpeg" "$HOME/.config/wallpaper.png"; do
  if [ -f "$f" ]; then
    xwallpaper --zoom "$f" &
    break
  fi
done
slstatus &
# Auto-mounts USB drives on insert (see the udisks2/udiskie comment in
# section_packages). --no-tray: dwm's bar has no systray to put an icon in;
# automount and the notification-free eject-on-remove behavior don't need
# one. Manual mount/unmount is Super+u (usbmenu).
udiskie --no-tray &
xset s 600
# slock is non-forking and doesn't handle the --transfer-sleep-lock
# protocol, so pair it with plain xss-lock (same pattern as xss-lock(1)'s
# own "xlock after ten minutes" example) rather than that flag.
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

  # Xorg prints its startup banner (server/protocol version, kernel
  # cmdline, log-file path, etc.) to stderr before it takes over the VT —
  # since that's the same tty tuigreet is drawing on, the banner flashes
  # on screen for the ~1s between Xorg starting and it grabbing the
  # display, right after login. Nothing in section_quiet_boot touches
  # this: that silences the kernel/systemd/firmware boot sequence, not
  # Xorg's own startup log. Wrapping the session command ourselves and
  # redirecting Xorg's stderr away is the only way to suppress it —
  # nothing is lost, since the banner's own "Log file:" line names where
  # Xorg writes the identical text regardless of this redirect.
  sudo tee /usr/local/bin/xsession-wrapper >/dev/null <<'EOF'
#!/bin/sh
# tuigreet's --xsession-wrapper, below: identical to its built-in default
# ("startx /usr/bin/env"), just with Xorg's own console output silenced.
exec startx /usr/bin/env "$@" >/dev/null 2>&1
EOF
  sudo chmod +x /usr/local/bin/xsession-wrapper

  # dpkg check, not `command -v` — greetd's binary lives in /usr/bin but a
  # daemon like this isn't something you'd normally expect on a user's PATH
  # anyway; dpkg is the correct "did the package actually install" check.
  if dpkg -s greetd >/dev/null 2>&1 && dpkg -s tuigreet >/dev/null 2>&1; then
    # tuigreet auto-discovers dwm.desktop from /usr/share/xsessions (its
    # built-in default search path — no --xsessions flag needed), so this
    # config needs nothing dwm-specific beyond the xsession-wrapper above
    # (see its own comment for why that's there). --remember (username)
    # and --remember-session are just convenience for a single-user, single-
    # session device.
    # Debian's greetd package does NOT create the "greeter" system user its
    # own default config.toml (and ours, below) depends on — confirmed on a
    # real run: greetd crash-loops with "configured default session user
    # 'greeter' not found" and hits systemd's restart limit within seconds.
    # Create it ourselves, idempotently. -M: no home dir needed for a
    # service account. -G video: console/framebuffer access.
    if ! id greeter >/dev/null 2>&1; then
      sudo useradd --system --no-create-home --shell /usr/sbin/nologin -G video greeter
      log "Created the 'greeter' system user (Debian's greetd package doesn't do this itself)."
    fi
    # --remember/--remember-session (in config.toml below) need a cache dir
    # owned by that user — tuigreet's own docs call this out explicitly.
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

    # Debian's packaged greetd.service unit hardcodes tty7 in its
    # After=/Conflicts= (Debian's own default config.toml assumes tty7;
    # ours above sets vt=1 instead, to land on-screen immediately at boot
    # with no VT-switching needed). Override the unit to match — without
    # this, nothing stops a getty@tty1 from racing greetd for the same VT.
    # Also add cloud-init.target to After=: tty1 is also where the kernel
    # and systemd send all console output (console=tty1 in cmdline.txt), so
    # without this, tuigreet draws its full-screen prompt and then cloud-init's
    # remaining first-boot messages print straight over it — confirmed on a
    # real run (garbled tuigreet display right after "[OK] Reached target
    # cloud-init.target"). Waiting for cloud-init to actually finish avoids
    # the race regardless of how long first boot takes.
    # Systemd drop-ins append to list directives by default, so each is
    # cleared with a bare assignment before being re-set.
    sudo mkdir -p /etc/systemd/system/greetd.service.d
    sudo tee /etc/systemd/system/greetd.service.d/override.conf >/dev/null <<'EOF'
[Unit]
After=
After=systemd-user-sessions.service plymouth-quit-wait.service getty@tty1.service cloud-init.target
Conflicts=
Conflicts=getty@tty1.service
EOF
    sudo systemctl daemon-reload

    # Debian's greetd.service is aliased to display-manager.service, which
    # is only started by graphical.target — not multi-user.target, which is
    # what Raspberry Pi OS Lite boots to by default. Enabling greetd.service
    # on its own is not enough; without this, greetd stays "enabled" but
    # never actually runs at boot ("Active: inactive (dead)" forever), and
    # you'd only ever reach a login prompt by manually switching to a VT
    # that still has a getty running (e.g. Ctrl+Alt+F2) and running `startx`
    # by hand — confirmed on a real run.
    sudo systemctl set-default graphical.target

    sudo systemctl disable getty@tty1.service 2>/dev/null || true
    # Clears any "start-limit-hit" failure left over from the missing-user
    # crash loop above (on a re-run of this script) — enable alone doesn't
    # reset that state, and a still-failed unit won't start on next boot.
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
  uv tool install ruff --quiet || warn "ruff install via uv failed — retry manually with 'uv tool install ruff'"
}

# ---------------------------------------------------------------------------
install_github_release_binary() {
  # install_github_release_binary <owner/repo> <asset-substring> <binary-name>
  local repo="$1" pattern="$2" binname="$3"
  if command -v "$binname" >/dev/null 2>&1 || [ -x "$LOCAL_BIN/$binname" ]; then
    log "$binname already installed"
    return
  fi
  log "Fetching latest $binname release for $pattern"
  local url
  # The `|| true` matters: under `set -o pipefail`, this pipeline reports
  # failure whenever grep finds no matching asset (its normal, expected
  # "nothing found" exit status of 1) even though curl/head/sed all
  # succeeded — without the guard, `set -e` would treat that as a hard
  # error and kill the whole script instead of falling through to the
  # empty-$url warning below.
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
  # zellij deliberately skipped: dwm's tags already give you multiple
  # workspaces, so a terminal multiplexer's workspace features are mostly
  # redundant here — you can still install it later if you want its
  # pane-splitting inside a single st window.
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
   Print                screenshot -> full screen, saved to ~/Pictures/Screenshots + clipboard
   Super+Print          screenshot -> click-drag a region, or click a window
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
 bootloader's BOOT_ORDER set to try the SD card, then USB, then the NVMe
 drive last (0xf641) — normal day-to-day boot is from NVMe; insert a
 rescue SD card or USB stick to override it. Check both after reboot with
 'cat /boot/firmware/config.txt' and 'sudo rpi-eeprom-config'.

 Audio: pipewire/wireplumber installed (a bare Lite install ships no sound
 server at all, unlike the official Desktop image) and the analog jack
 enabled (dtparam=audio=on) for an aux speaker, alongside HDMI audio to a
 monitor. After rebooting, check output devices with 'wpctl status' or
 'aplay -l', and switch the default sink with 'wpctl set-default <id>' if
 sound comes out the wrong one.

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
