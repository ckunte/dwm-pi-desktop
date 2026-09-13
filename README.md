# dwm-pi-desktop

A single script that turns a fresh Raspberry Pi OS Lite (64-bit, Trixie/Debian 13)
install on a Pi 5 (8GB, NVMe SSD via the official M.2 HAT+) into a minimal
dwm/X11 "pocket desktop."

## What it sets up

- **dwm, dmenu, slock, st, slstatus** — built from suckless sources, each with
  a curated patch applied if it applies cleanly (pertag, fullscreen,
  fuzzymatch, scrollback, scrollback-mouse, message); falls back to vanilla
  otherwise, so a patch conflict never breaks the build.
- **greetd + tuigreet** as the login manager, auto-starting dwm via
  `/usr/local/bin/start-dwm`.
- **chromium** bound to `Super+b`, **st** terminal, **dmenu** launcher,
  **slock** screen lock paired with `xss-lock` for an idle timeout.
- **USB auto-mount** via `udiskie`, plus a `Super+u` dmenu picker for manual
  mount/unmount/eject.
- **NVMe (M.2 HAT+)**: enables PCIe Gen 3 on the external connector and sets
  the bootloader's `BOOT_ORDER` to SD → USB → NVMe, so a rescue SD card or USB
  stick overrides normal NVMe boot when present.
- **Audio**: pipewire + wireplumber (a bare Lite install ships no sound
  server at all). The Pi 5 has no analog 3.5mm jack — audio out is
  HDMI-only on this board; route an aux speaker through your monitor's own
  audio-out passthrough jack, or add a USB audio adapter for direct output.
- **Xorg fix** for a Pi 5 quirk (two DRM devices, vc4 + v3d) that otherwise
  crashes X right after login with "Cannot run in framebuffer mode."
- **Quiet boot** — kernel/systemd console spam and the firmware splash are
  silenced, so tuigreet is the first thing you see.
- **CLI toolset**: fish, neovim (+ vim-plug config), uv/ruff, typst, ripgrep,
  fzf, bat/fd (aliased from Debian's renamed packages), Cascadia Code font,
  ufw firewall (default-deny incoming, SSH allowed).
- **macOS-style helpers**: `pbcopy`/`pbpaste` (xclip wrappers), `imgview`
  (nsxiv wrapper), `screenshot` (scrot wrapper, bound to `Print`/`Super+Print`).

## Requirements

- Fresh Raspberry Pi OS Lite, 64-bit, on a Pi 5.
- Run as your normal user — **not** root/sudo (it escalates internally via
  `sudo` only where needed).
- Optional: drop `wallpaper.jpg`/`.jpeg`/`.png` next to the script before
  running to have it installed and set automatically.
- Optional: drop your own `bashrc`/`bash_functions`/`bash_aliases` next to the
  script to have them installed (an existing, different file is backed up
  with a timestamp suffix before being replaced).

## Usage

```sh
chmod +x setup-pi-desktop.sh
./setup-pi-desktop.sh
```

Reboot when it tells you to — firmware/bootloader changes need one. Then log
in at the tuigreet prompt → dwm.

**Idempotent.** Every section checks whether its target already exists before
touching anything, so it's safe to re-run. A failed build (e.g. from a
hand-edited suckless `config.h`) warns and lets the rest of the script
continue; fix it and re-run.

## Key bindings (MODKEY = Super)

| Binding | Action |
|---|---|
| `Super+Shift+Return` | st (terminal) |
| `Super+p` | dmenu_run |
| `Super+b` | chromium |
| `Super+Ctrl+l` | slock (manual lock) |
| `Super+v` | imgview → nsxiv thumbnails, `~/Pictures` |
| `Super+u` | usbmenu → mount/unmount/eject a USB drive |
| `Print` | screenshot, full screen |
| `Super+Print` | screenshot, select a region or window |
| `Super+Shift+f` | fullscreen toggle (only if that patch applied) |
| `Super+j` / `Super+k` | focus next/previous window |
| `Super+h` / `Super+l` | shrink/grow the master area |
| `Super+i` / `Super+d` | inc/dec number of masters |
| `Super+t` / `Super+f` / `Super+m` | tile / floating / monocle layout |
| `Super+1..5` | view tag |
| `Super+Shift+1..5` | move window to tag |
| `Super+Shift+q` | quit dwm |

Idle lock is 10 minutes via `xset` + `xss-lock` — change the timeout in
`/usr/local/bin/start-dwm`.

## Still manual, on purpose

- `gpg --full-generate-key` then `pass init <key-id>`
- `chsh -s /usr/bin/fish` — only once you've confirmed the session works
- Review `sudo ufw status verbose`

## Notes / gotchas

- The Pi 5's official M.2 HAT+ isn't certified for PCIe Gen 3. If the NVMe
  drive looks flaky after running this, drop `dtparam=pciex1_gen=3` to `=2`
  (or delete the line) in `/boot/firmware/config.txt` rather than assuming
  the drive is bad.
- suckless sources under `~/src` are cloned once and never `git pull`ed on
  a re-run, since patches are applied against a fresh clone and a pull would
  conflict with those local changes. To rebuild against latest upstream,
  delete the relevant `~/src/<tool>` directory yourself first.
- Chromium (prebuilt, no vim keybindings) was chosen after surf and
  qutebrowser both ran into build/config friction on-device — a pragmatic
  choice, not a suckless-purity one.
- Check firmware/boot changes after reboot with `cat /boot/firmware/config.txt`
  and `sudo rpi-eeprom-config`.
- Xorg prints its own startup banner (version, kernel cmdline, log-file path)
  to the console for the brief moment before it takes over the display —
  separate from (and not covered by) the kernel/firmware quiet-boot settings
  above. This script suppresses it via a custom tuigreet `--xsession-wrapper`
  (`/usr/local/bin/xsession-wrapper`) that redirects Xorg's stderr; the same
  content is still available in Xorg's own log file if you ever need it.
- `quiet loglevel=0` on its own only sets systemd's status output to "auto"
  (suppressed until a unit takes more than ~1.5s or errors) — it doesn't
  turn it off outright, which is why routine things like the root
  filesystem's fsck summary ("`/dev/... clean, N/M files...`") can still
  print on some boots. `systemd.show_status=0` in cmdline.txt silences that
  too, without affecting the emergency shell a genuine fsck failure or
  kernel panic still drops you into on the console.
- No audio out of the box was the single biggest gap versus the official
  Desktop image: a Lite install has no sound server at all (no pipewire, no
  pulseaudio), so chromium/vlc silently have nothing to output to. This
  script installs pipewire + wireplumber + alsa-utils to fix that. After a
  reboot, `wpctl status` lists sinks and `wpctl set-default <id>` switches
  the default one; `aplay -l` / `speaker-test -c2` are lower-level ALSA
  checks if pipewire itself looks like the problem.
- The Pi 5 dropped the analog 3.5mm jack earlier Pi boards had — `cat
  /proc/asound/cards` on a Pi 5 shows only `vc4hdmi0`/`vc4hdmi1`, no analog
  card, and `dtparam=audio=on` (the classic fix for that jack on older Pis)
  is a no-op here since the codec it enables doesn't exist on this board.
  Audio out is HDMI-only; `wpctl status` shows one sink per HDMI port that
  actually has a display attached. For an aux speaker, route it through
  your monitor's own audio-out passthrough jack, or add a USB audio
  adapter/DAC if you want output the Pi drives directly.
