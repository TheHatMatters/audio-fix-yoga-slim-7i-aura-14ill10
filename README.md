# Speaker Audio Fix for Linux on Lenovo Yoga Slim 7i Aura Edition 14ILL10 (83JX)

Speakers don't play sound after you installed Linux on this Lenovo model? This fixes it.

## Symptoms

- No audio output from speakers (GNOME shows "Dummy Output" or silent devices), although bluetooth may function
- GNOME Sound Settings shows devices but "Test Sound" does nothing or crashes audio entirely

## Affected hardware

| Field | Value |
|---|---|
| Model | Lenovo Yoga Slim 7i Aura Edition 14ILL10|
| DMI product name | 83JX |
| Board | LNVNB161216 |
| Audio chip | Intel Lunar Lake SOF (`sof-audio-pci-intel-lnl`) |
| Codec | Cirrus Logic cs42l43 (SoundWire) |
| Speaker amp | Cirrus Logic cs35l56-bridge (SPI, ×2) |

Tested on: **Linux Mint 22.3 (Zena)**, kernel **6.17.0-20-generic**, WirePlumber **0.4.17**

## Root cause

The SOF (Sound Open Firmware) topology shipped with this kernel is compiled for ABI version **3:29:1**, but the running kernel's SOF expects ABI **3:23:1**. This mismatch causes two DRC (Dynamic Range Compression) modules to fail with error 104 at init time:

- `drc.21.1` — Speaker pipeline → **pcm2** (cs35l56-bridge SmartAmp)
- `drc.100.1` — DMIC pipeline → **pcm10** (internal microphone array)

**The critical part:** opening either of these PCM devices crashes the SOF DSP, which takes down *all* audio — including headphones. PipeWire's pro-audio profile tries to open all PCMs at startup, so the DSP crashes on every boot before you can hear anything.

A secondary issue is a SoundWire race condition: the cs42l43 codec shows as `UNATTACHED` when WirePlumber first starts, so the HiFi profile is marked unavailable and PipeWire falls back to pro-audio — triggering the crash.

## What this fix does

1. **WirePlumber rule** — prevents pcm2 and pcm10 from ever being opened, stopping the DSP crash
2. **systemd user service** — forces the card to `pro-audio` profile after a short delay on login (works around the cs42l43 SoundWire race)
3. **UCM override** — removes the broken devices from the HiFi profile definition (belt-and-suspenders)

## What works after the fix

| Output | Status |
|---|---|
| Headphones (3.5mm) | ✅ Works |
| HDMI audio | ✅ Works |
| Built-in speakers | ⚠️ Requires additional fix (see below)|
| Internal microphone | ⚠️ Requires additional fix (see below)|

Built-in speakers: Function broken (cs35l56-bridge requires DRC — upstream kernel/firmware issue) 
Internal microphone: Function Broken (DMIC requires DRC — same issue)
Both, speakers and the internal mic require the DRC pipeline which is broken by the ABI mismatch. This is an upstream issue that needs a fix in the SOF firmware or kernel topology — nothing we can do locally for those.

## Install

```bash
git clone https://github.com/TheHatMatters/audio-fix-yoga-slim-7i-aura-14ill10.git
cd audio-fix-yoga-slim-7i-aura-14ill10
bash install.sh
```

The script will ask for `sudo` once (to write UCM files to `/usr/share/alsa/`). Everything else is user-level.

## Manual steps (if you prefer not to run a script)

<details>
<summary>Click to expand</summary>

### 1. WirePlumber rule

```bash
mkdir -p ~/.config/wireplumber/main.lua.d
```

Create `~/.config/wireplumber/main.lua.d/51-disable-drc-pcm.lua`:

```lua
table.insert(alsa_monitor.rules, {
  matches = {
    { { "node.name", "matches", "alsa_output.*sof_sdw*pro-output-2" } },
  },
  apply_properties = { ["node.disabled"] = true },
})

table.insert(alsa_monitor.rules, {
  matches = {
    { { "node.name", "matches", "alsa_input.*sof_sdw*pro-input-10" } },
  },
  apply_properties = { ["node.disabled"] = true },
})
```

### 2. systemd user service

Create `~/.config/systemd/user/audio-profile.service`:

```ini
[Unit]
Description=Set audio card to pro-audio profile
After=wireplumber.service pipewire-pulse.service
Wants=wireplumber.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 4
ExecStart=/usr/bin/pactl set-card-profile alsa_card.pci-0000_00_1f.3-platform-sof_sdw pro-audio
RemainAfterExit=yes

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now audio-profile.service
```

### 3. UCM override files

See `install.sh` for the full file contents — these go in `/usr/share/alsa/ucm2/` and require sudo.

### 4. Restart audio (or just reboot)

```bash
systemctl --user stop wireplumber pipewire-pulse pipewire
sudo bash -c 'echo 0000:00:1f.3 > /sys/bus/pci/drivers/sof-audio-pci-intel-lnl/unbind && sleep 2 && echo 0000:00:1f.3 > /sys/bus/pci/drivers/sof-audio-pci-intel-lnl/bind'
systemctl --user start pipewire wireplumber pipewire-pulse
```

</details>

## Recovery (if audio breaks again)

If the DSP crashes (e.g. after a WirePlumber update removes the rule):

```bash
systemctl --user stop wireplumber pipewire-pulse pipewire
sudo bash -c 'echo 0000:00:1f.3 > /sys/bus/pci/drivers/sof-audio-pci-intel-lnl/unbind && sleep 2 && echo 0000:00:1f.3 > /sys/bus/pci/drivers/sof-audio-pci-intel-lnl/bind'
systemctl --user start pipewire wireplumber pipewire-pulse
sleep 4
pactl set-card-profile alsa_card.pci-0000_00_1f.3-platform-sof_sdw pro-audio
```

Then re-run `install.sh` to make sure all fix files are in place.

## Contributing

If this works (or doesn't) on a different kernel or distro, please open an issue — would be good to know the range of affected configurations.

The real fix is an updated SOF topology matching the kernel ABI. If you want to help upstream: the mismatch is between `intel/sof-ipc4-tplg/sof-lnl-cs42l43-l0-4ch.tplg` (ABI 3:29:1) and the kernel's expected ABI 3:23:1.

Disclaimer: Both, troubleshooting and documentation was done mostly by Claude Code with user supervision.
