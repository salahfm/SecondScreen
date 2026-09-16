# SecondScreen

Turn an old laptop into a **wireless second monitor** for your Windows PC.

Boots a tiny, purpose-built OS (~300 MB) straight from a USB stick — no
Windows, no Linux desktop, no hard drive needed. The laptop powers on,
connects to your Wi-Fi, and instantly becomes an extra display for your PC.

Built and tested for:

| Component | Target hardware |
|---|---|
| CPU | Intel Celeron N4000 (Gemini Lake, x86_64) |
| GPU | Intel UHD Graphics 600 |
| Wi-Fi | Intel Wireless-AC 9560 |
| RAM | 4 GB (runs comfortably in < 1 GB) |
| Boot | USB flash drive, UEFI or legacy BIOS |

## Zero-touch pairing — how it works

The config file (`secondscreen-setup.txt`) carries Wi-Fi credentials and a
one-time shared token. On the PC, a small pairing helper
(`Invoke-PinWaiter.ps1`, run by the `SecondScreenPinWaiter` scheduled task)
listens on port 47991:

1. The laptop's wizard finds the file, joins Wi-Fi, and pings the PC.
2. `moonlight pair` runs on the laptop, which *displays* a PIN.
3. The laptop POSTs `{token, pin}` to the helper; the helper validates the
   token and enters the PIN into Sunshine's REST API (`POST /api/pin`).
4. Pairing completes; the setup file is deleted from the stick.

The token is per-installation (stored in `C:\ProgramData\SecondScreen`),
and the helper only ever forwards PINs — it exposes nothing else. If the
waiter is unwanted, delete the scheduled task; the interactive wizard flow
still works.

> **Note:** the Wi-Fi password is stored **plaintext** on the stick.
> That's inherent to zero-touch (the laptop must be able to read it).
> Treat the stick like a written-down password — don't leave it plugged
> in unattended.

## How it works

```
+------------------+        Wi-Fi         +--------------------+
|  Windows PC      | <------------------> |  Old laptop        |
|  Sunshine host   |   H.264/HEVC stream  |  SecondScreen OS   |
|  Virtual Display |   (low latency)      |  (Alpine + Xorg +  |
|  Driver          |                      |   Moonlight kiosk) |
+------------------+                      +--------------------+
```

- On the **PC**: Sunshine encodes a virtual display and streams it over the
  network. The Virtual Display Driver makes Windows treat the laptop as a
  real second monitor (extend mode, not mirror).
- On the **laptop**: SecondScreen boots straight into a fullscreen Moonlight
  client that renders that stream on the laptop's screen.
- The whole system runs from RAM. Wi-Fi credentials and pairing data are
  saved to a small data partition on the USB stick, so the laptop reconnects
  automatically on every boot.

## Quick start

### 1. On the Windows PC

1. Download or build the SecondScreen ISO (see "Building").
2. In this repo, run `windows/Install-SecondScreenHost.ps1` as Administrator
   (right-click → Run with PowerShell). It installs:
   - **Sunshine** (stream host, starts automatically with Windows)
   - **Virtual Display Driver** (the fake second monitor)
   - Firewall rules for Sunshine's ports
3. Reboot the PC once so the virtual display appears.

### 2. On the laptop

Two ways — pick one:

**Zero-touch (recommended, no typing on the laptop):** in the PC installer
menu, choose **[1] Prepare a USB stick** *after* flashing the SecondScreen
image to it. The stick then carries your Wi-Fi + pairing config; on first
boot the laptop connects, pairs with the PC automatically, and reboots
straight into stream mode. A QR code of the config can be shown as a
backup/alternative.

**Interactive:** boot the laptop from the stick — the first-boot wizard
starts automatically:

1. Pick your Wi-Fi network and enter the password.
2. Enter your PC's IP address (the PC installer prints it at the end).
3. Moonlight shows a **4-digit PIN** — type that PIN into Sunshine's web
   UI on the PC (`https://localhost:47990` → **PIN**).

Either way, the laptop then reboots and comes up as a wireless second
monitor. Done.

### Daily use

- Power on the laptop → it auto-connects and streams. Nothing to click.
- Quit the stream on the laptop: `Ctrl+Alt+Shift+Q` (it auto-reconnects).
- Change Windows display settings (resolution, arrangement, taskbar side)
  as with any second monitor — the laptop shows up as one.
- Press `Ctrl+Alt+F2` on the laptop for the built-in **settings editor**
  (bitrate, resolution, FPS, re-pair, connection check — see below).
  `Ctrl+Alt+F7` returns to the stream.

### Changing stream settings on the laptop (tty2)

Press `Ctrl+Alt+F2` at any time. The menu lets you:

1. Change resolution (720p / 900p / 1080p / 1440p)
2. Change FPS (30 / 60)
3. Change bitrate (2–20 Mbps — lower if the stream stutters)
4. Change which app Sunshine streams (default `Desktop`)
5. Change the PC address
6. **Restart the stream now** — applies your changes immediately
   (the stream also picks up changes on every auto-reconnect)
7. Check Wi-Fi + PC connectivity (ping + Sunshine reachability)
8. Re-pair with a PC (PIN flow)
9. Reset everything and re-run the first-boot wizard

Changes are saved to the USB stick automatically, so they survive reboots.
`Ctrl+Alt+F7` switches back to the stream.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Wizard shows no Wi-Fi networks | Make sure you're not in a metal-walled room; check `rfkill list` on tty2 |
| "Pairing FAILED" | Re-run `moonlight pair <pc-ip>` from tty2; make sure Sunshine is running on the PC |
| Stream connects but shows the wrong monitor | On the PC, in Windows Display Settings, drag the laptop's display tile to match your physical layout |
| Wizard can't find the zero-touch setup file | Check the stick is FAT32/exFAT (not NTFS) and contains `secondscreen-setup.txt` in its root |
| Zero-touch fails at "pairing helper not reachable" | Is the `SecondScreenPinWaiter` task running on the PC? Check `C:\ProgramData\SecondScreen\waiter.log` |
| Stutter / low FPS | Lower bitrate: edit `pairing.conf` on the USB stick (see below) |
| Laptop boots to a shell instead of streaming | Check `/var/log/secondscreen.log` and `/var/log/Xorg.0.log` from tty2 |

### Editing settings after setup

Two ways:

- **On the laptop itself:** `Ctrl+Alt+F2` → settings editor (see above).
- **On any PC:** pull the stick — the data partition (label `SECONDSCREEN`)
  is a normal FAT drive with:

```
wpa_supplicant.conf   # Wi-Fi credentials
pairing.conf          # host, resolution, fps, bitrate, app
```

Edit `pairing.conf` on any PC (the stick is readable as a normal FAT drive)
to change resolution/fps/bitrate, e.g. for smoother video:

```
host=192.168.1.20
resolution=1920x1080
fps=60
bitrate=6000
app=Desktop
```

## Building the ISO

You don't need any local Linux — a GitHub Action builds everything:

1. Push this repo to GitHub.
2. The workflow (`.github/workflows/build.yml`) builds the ISO on every
   push and attaches it as an artifact (`secondscreen-iso`).
3. Download the artifact from the Actions tab.

The build script (`build/mkprofile.sh`) runs inside an Alpine container and:

- Fetches upstream Alpine `mkimage` scripts (v3.20.0)
- Registers the `secondscreen` profile (`build/mkimg.secondscreen.sh`):
  small kernel + only Intel Wi-Fi/GPU firmware + Xorg/Moonlight packages
- Generates the config overlay (`build/secondscreen.apkovl.sh`) with the
  kiosk inittab, Wi-Fi stack, and service wiring
- Runs `mkimage` to produce the ISO, then `build/mkusbimg.sh` appends the
  persistent data partition and outputs a flashable `.img`

## Layout

```
build/
  mkimg.secondscreen.sh      Alpine image profile (packages, firmware)
  secondscreen.apkovl.sh     Config overlay generator (inittab, services)
  mkprofile.sh               Container build entrypoint
  mkusbimg.sh                ISO -> pre-partitioned .img with persist partition
  overlay/                   Static config files shipped inside the image
    etc/init.d/secondscreen-net    Wi-Fi + DHCP service (self-contained)
    etc/init.d/secondscreen-sync   Loads saved settings from USB at boot
    usr/local/bin/secondscreen-autologin Root autologin helper (tty1 wizard)
  usr/local/bin/secondscreen-launch    Boot → X → Moonlight loop
    usr/local/bin/secondscreen-net       wpa_supplicant + dhcpcd bring-up
    usr/local/bin/secondscreen-settings  On-device settings menu (tty2)
    usr/local/bin/secondscreen-wizard    First-boot Wi-Fi + pairing setup
    usr/local/bin/secondscreen-sync      Load/save persisted settings
windows/
  Install-SecondScreenHost.ps1   PC-side installer (Sunshine + VDD + zero-touch)
  Invoke-PinWaiter.ps1           PC-side pairing helper (auto-enters PINs)
.github/workflows/build.yml      CI build (no local Linux needed)
```

## FAQ

**Is this a "real" OS?** It's a real bootable OS image, but purpose-built:
Alpine Linux stripped to a single-app kiosk. Writing drivers from scratch
for your specific Wi-Fi/GPU would take years — reusing the mature Linux
kernel + Moonlight stack gets you a ~300 MB, 10-second-boot appliance that
just works.

**Can the laptop be used as a monitor for a different PC later?** Yes — run
the wizard again (delete `wpa_supplicant.conf` from the stick's data
partition, reboot) and pair with the new PC.

**Does it work without Wi-Fi?** Not for the streaming itself. If both
machines are in the same room, a cheap USB-Ethernet adapter on the laptop
(dhcp on `eth0` works out of the box) gives lower latency than Wi-Fi.

**Can I stream the PC's main screen instead of extending?** Yes — in
Moonlight terms, just change `app=Desktop` to the display you want in
Sunshine's settings, or remove the Virtual Display Driver and stream the
physical display (mirror mode).
