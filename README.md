# AirPi receiver

A Raspberry Pi 4 that turns a USB DAC into a lossless AirPlay speaker, with a
now-playing screen on the TV.

- **Audio:** classic AirPlay via [Shairport Sync](https://github.com/mikebrady/shairport-sync), so every sender (iPhone, Mac, Apple Music, Spotify) has to send lossless ALAC 16-bit/44.1 kHz. It goes straight to the DAC through ALSA (`hw:`), with no resampling, and the AirPlay volume slider drives the DAC's own hardware volume.
- **Screen:** full-screen cover art, title and artist over HDMI. It's drawn straight into the Linux framebuffer, so no desktop or GPU stack is needed. Covers are upgraded to high resolution from Apple's catalogue when the album matches.
- **TV control (HDMI-CEC):** the TV turns on and switches to the Pi when music starts, and goes into standby 5 minutes after it stops. The TV remote's **OK** button opens a debug overlay.

```
iPhone / Mac ──AirPlay (classic, ALAC 44.1/16)──► shairport-sync ──► USB DAC ──► speaker
                                                       │
                                                       │ metadata pipe (track, cover, device)
                                                       ▼
                                                 airpi-display ──► /dev/fb0 ──► HDMI ──► TV
                                                       ▲                                 │
                                                       └──────── HDMI-CEC (cec-ctl) ─────┘
                                                          remote keys in, TV on/standby out
```

## Hardware

- Raspberry Pi 4 Model B (1 GB is plenty: about 60–80 MB in use)
- USB DAC on a **USB-A** port. The Pi's USB-C port is power only. Built and tested with a FiiO QX11.
- TV on **HDMI0** (the port next to USB-C), with HDMI-CEC enabled. Tested with an LG C3, where CEC is called SIMPLINK and the TV needs "Turn on via Wi-Fi" for wake-up (see below).

## Install

On Raspberry Pi OS Lite (64-bit, Trixie):

```bash
git clone https://github.com/standy66/airpi-receiver.git && cd airpi-receiver
DAC_CARD=QX11 TV_MAC=aa:bb:cc:dd:ee:ff ./install.sh   # card name from `aplay -l`; TV_MAC optional
sudo reboot
```

`install.sh` installs the packages, builds Shairport Sync at a pinned commit, installs the config and the two services, turns off onboard and HDMI audio, sets the HDMI mode, and turns off Wi-Fi power saving. `HDMI_MODE=1920x1080-32@60` gives 1080p instead of 4K.

## Files

| Path | Installed to | What it is |
|---|---|---|
| `config/shairport-sync.conf` | `/etc/shairport-sync.conf` | Classic AirPlay, bit-perfect output, metadata pipe |
| `bin/airpi-display` | `/usr/local/bin/airpi-display` | Now-playing screen, CEC control, debug overlay (Python + Pillow) |
| `systemd/airpi-display.service` | `/etc/systemd/system/` | Runs the screen at low priority; detaches the text console; sets full-range HDMI |
| `systemd/airpi-cec.service` | `/etc/systemd/system/` | Registers the Pi on HDMI-CEC as playback device "AirPi" at boot |

Boot settings changed by the installer:

- `config.txt`: `dtparam=audio=off` and `dtoverlay=vc4-kms-v3d,noaudio`
- `cmdline.txt`: `video=HDMI-A-1:3840x2160-32@30 consoleblank=0 vt.global_cursor_default=0`

## Design notes

### Why classic AirPlay instead of AirPlay 2

Shairport Sync 5.x accepts lossless ALAC over AirPlay 2, but whether it gets used is up to the sender. Results with Shairport's statistics on, macOS 27 and iOS, October 2026:

| Sender | AirPlay 2 mode | Classic mode |
|---|---|---|
| Mac: System Settings → Sound → AirPi (any app) | ALAC 44.1/16 (Realtime) | ALAC 44.1/16 |
| Mac: Music app's own AirPlay button | **AAC 48 kHz** (Buffered) | ALAC 44.1/16 |
| iPhone: Apple Music | **AAC 48 kHz** (Buffered) | ALAC 44.1/16 |
| iPhone: Spotify | ALAC 44.1/16 (Realtime) | ALAC 44.1/16 |

Classic mode is lossless for every sender. You lose multi-room grouping and the Home app. AirPlay can't carry more than 16-bit, so 24-bit sources are reduced to 16-bit by the sender whichever mode you use.

To switch to AirPlay 2 instead, remove `service_type` from the config and build and enable [NQPTP](https://github.com/mikebrady/nqptp).

### Keeping it bit-perfect

- `output_device = "hw:…"` with `output_rate`/`output_format = "auto"`: the DAC runs at the incoming rate, so ALSA does no conversion. 16-bit samples are sent in a 32-bit container padded with zeros.
- `mixer_control_name = "PCM"`: AirPlay volume moves the DAC's hardware volume, so the samples themselves are never scaled.
- AirPlay has no way for the receiver to slow the sender down, so Shairport must occasionally add or drop a sample to stay in sync with the DAC's clock. `interpolation = "basic"` changes **one sample** per correction instead of resampling a whole packet (`soxr`). `drift_tolerance_in_seconds = 0.010` (default 0.002) skips corrections for drift under 10 ms. In a measured 23-minute session that came to about 7.5 ppm, i.e. roughly one changed sample every 3 seconds.

### Now-playing screen

- Shairport writes metadata (track text, `PICT` cover art, device, stream format, play start/end) to a named pipe. `airpi-display` parses it in a thread and redraws only when something visible changes.
- The cover is shown at 64% of the screen height over a blurred, darkened copy of itself. The copy is zoomed 20% so the cover's edges (e.g. white borders) stay off-screen. If the sender gives a title but no picture, the screen shows text only. If it sends no track info at all (the Mac in classic mode), the screen shows an "AirPi — Playing from Mac" card.
- **No banding in dark gradients:** two causes, two fixes.
  - **HDMI range:** for TV resolutions such as 4K, the Pi's HDMI output defaults to *limited-range* RGB (16–235). The Pi squeezes 256 levels into 220 and the TV stretches them back, so some neighbouring levels merge into visible steps. The service sets `Broadcast RGB = Full` with `modetest` at every start; with the TV's Black Level on Auto, it follows.
  - **Dithering:** the background is also dithered with a repeated 256 px noise tile (σ = 1.5 levels), which is invisible as grain but breaks up any remaining steps.
- **High-res art:** each new album is looked up on the iTunes Search API (`gb`, then `us` storefront). The result is used only if the artist and album match exactly, ignoring "(Deluxe Edition)"-style suffixes and punctuation, and it's downloaded at exactly the on-screen size. Otherwise the sender's 512 px JPEG is kept. Up to 30 albums are cached in memory, and nothing is written to disk.
- **Framebuffer instead of SDL/KMSDRM:** SDL's drawing path on the Pi produced a plane in the `AR24` format, which showed only black on the TV. Writing raw 32-bit pixels to `/dev/fb0` works, needs only Pillow, and costs 0% CPU between redraws: the display hardware keeps scanning out the last frame by itself.
- **Memory:** a 4K redraw briefly needs about 170 MB, so the program calls `malloc_trim` after every redraw. At rest it uses about 60–80 MB.

### TV control over HDMI-CEC

The program follows CEC traffic with `cec-ctl --wait-for-msgs`:

- **Audio starts** (the DAC's ALSA status becomes `RUNNING`, so this also works for senders without metadata): it first sends *Image View On*, which has to be the first message because some TVs stay asleep if anything comes before it. Then it asks for the TV's power status:
  - **The TV answers "on":** it was already on, so its input is left alone.
  - **The TV doesn't answer:** it's in deep standby with CEC switched off. If `AIRPI_TV_MAC` is set, AirPi sends **Wake-on-LAN** and waits for the TV to come up.
  - Then it sends *Active Source* to switch the TV to AirPi's input.

  **LG C3:** in standby the TV doesn't acknowledge any CEC message, even with SIMPLINK and Quick Start+ on and on any HDMI port, so CEC alone can't wake it. Enable **All Settings → General → Devices → External Devices → TV On With Mobile → Turn on via Wi-Fi**, then set the TV's MAC (`TV_MAC=` for `install.sh`, or `AIRPI_TV_MAC` in `airpi-display.service`). From music starting to the TV showing AirPi takes about 6 seconds. CEC *Standby* does work on the C3, so the auto-off needs nothing extra.
- **No audio for 5 minutes** (`INACTIVE_TIMEOUT`): the screen goes black, and the TV is sent *Standby* **only if** it's still on AirPi's input. That's known from routing messages, and from remote key presses, which the TV forwards only to the active input.
- **Remote keys:** **OK** toggles the debug overlay and **Back** hides it.

The debug overlay refreshes every 2 seconds and redraws only its own corner of the screen. It shows the device and User-Agent, the incoming stream format, what the DAC is actually running (from `/proc/asound/…/hw_params`), AirPlay volume, the inactivity timer, TV power and input, Wi-Fi signal, temperature and free memory.

## Debugging

```bash
journalctl -u airpi-display -f        # TV control (tv:), artwork lookups (art:), CEC traffic (cec)
journalctl -u shairport-sync -f
cat /proc/asound/QX11/pcm0p/sub0/hw_params   # what the DAC is running right now
cec-ctl -d /dev/cec0 --to 0 --give-device-power-status
```

To log the format of every session, add to `/etc/shairport-sync.conf`:

```
diagnostics = { statistics = "yes"; };
```

## Known limitations

- **The Mac sends no track info or artwork in classic mode** (all fields blank), so it gets the "Playing from Mac" card. The iPhone sends everything.
- **Stale covers when switching apps:** the iPhone sometimes re-sends the previous app's cover with the new app's first track. This is left as is; the next track corrects it.
- **Device, Agent and Stream are sent only when a session starts.** If `airpi-display` restarts mid-session, those overlay lines show `-` until the next pause/play.
- The DAC's card name (`QX11`) appears in the config and in `bin/airpi-display`. `install.sh` substitutes `DAC_CARD`.
- If the speaker after the DAC (e.g. a powered speaker with DSP) converts its input back to digital, bit-perfect delivery ends at the DAC's output.
