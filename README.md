# dwm-pi-desktop

Turns a fresh Raspberry Pi OS Lite (64-bit, Trixie) install on a Pi 5
(NVMe via the M.2 HAT+) into a minimal dwm/X11 desktop. Pi OS defaults are
kept wherever they work.

## What you get

- **dwm 6.8, dmenu 5.4, st 0.9.3, slock 1.7, slstatus 1.1** built from pinned
  suckless release tags. Patches (vendored in `patches/`): dwm pertag,
  fullscreen and gaps, st scrollback. The gaps patch is our own, small:
  `gappin` (3 px, between tiles) and `gappout` (6 px, around the screen edge)
  in `files/dwm/config.h`, applied in tile and monocle layouts.
- **greetd + tuigreet** login, starting dwm through `/usr/local/bin/start-dwm`.
- **chromium** (`Super+b`), **zathura** (PDF), **nsxiv** (`Super+v`), **vlc-bin**
  internet radio (`Super+r`), **scrot** screenshots, **udiskie** USB automount
  plus a `Super+u` mount/unmount picker, **pipewire** audio.
- **Bar:** weather (icon and temperature from wttr.in, location by IP, cached
  15 minutes by `~/.local/bin/weather`) followed by the date and time.
- **Idle lock** after 10 minutes (`xset` + `xss-lock` + slock).
- **Tools:** fish (login shell, with an Omarchy-style starship prompt from
  `files/starship/starship.toml`), bat, fd, ripgrep, rsync, entr, fzf, pass, uv, typst, yazi (`y` in fish cds to where you quit),
  `pbcopy`/`pbpaste`.
- **ufw:** deny incoming; SSH (22/tcp) and mDNS (5353/udp, for `hostname.local`) allowed.
- **Firmware:** PCIe x1 at Gen 3 for NVMe, quiet boot. The bootloader/EEPROM
  is left alone.

## Layout

```
install.sh     # the installer
files/         # configs and helper scripts, copied into place
patches/       # suckless patches, verified against the pinned tags
```

## Usage

Run as your normal user, not root:

```sh
./install.sh
```

Reboot when it says so, then log in at the tuigreet prompt. Re-running is
safe: a suckless tool only rebuilds when its tag, patches, or
`files/<tool>/config.h` change.

- `--upgrade` also refreshes uv, typst, starship and yazi to the latest release. apt packages
  are upgraded on every run.
- `--xorg-legacy` installs `xserver-xorg-legacy` and lets any user start X as
  root. Only needed if rootless Xorg fails.
- To change a suckless version, edit the `*_REF` values at the top of
  `install.sh` and check the patches still apply.
- Optional: put `wallpaper.jpg`/`.png` next to `install.sh` to have it set as
  the wallpaper.
- Output is logged to `~/install.log`.

## Key bindings (MODKEY = Super)

| Binding | Action |
|---|---|
| `Super+Shift+Return` | st |
| `Super+p` | dmenu_run |
| `Super+b` | chromium |
| `Super+Ctrl+l` | lock |
| `Super+Shift+f` | fullscreen |
| `Super+v` | nsxiv thumbnails of `~/Pictures` |
| `Super+u` | USB mount / unmount + eject |
| `Super+r` | radio station picker (`~/.config/radiomenu/stations`) |
| `Print` / `Super+Print` | screenshot full / selection (saved + clipboard) |
| `F10` / `F11` / `F12` | mute / volume down / volume up |
| `Super+j` / `k` | focus next / previous |
| `Super+h` / `l` | shrink / grow master |
| `Super+i` / `d` | more / fewer masters |
| `Super+t` / `f` / `m` | tile / floating / monocle |
| `Super+w` | close window |
| `Super+1..5`, `+Shift` | view tag, move window to tag |
| `Super+Shift+q` | quit dwm |

## Still manual

```sh
gpg --full-generate-key
pass init <key-id>
```

## Troubleshooting

- **X doesn't start after login:** read `~/.cache/xsession.log` and
  `~/.cache/start-dwm.log`. Then try `./install.sh --xorg-legacy`.
- **Recovery:** `Ctrl+Alt+F2` gives a getty. `sudo systemctl set-default
  multi-user.target` backs out of greetd.
- **NVMe flaky:** the M.2 HAT+ isn't certified for Gen 3. Set
  `dtparam=pciex1_gen=2` in `/boot/firmware/config.txt`.
- **Audio:** the Pi 5 has no analog jack; output is HDMI or USB. Use
  `wpctl status` and `wpctl set-default <id>`.
- **`pass`:** uses `pinentry-curses`, so run it from a terminal.
