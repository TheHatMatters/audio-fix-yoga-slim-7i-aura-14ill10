#!/usr/bin/env bash
# Audio fix for Lenovo Yoga Slim 7 14ILL10 (83JX)
# Workaround for SOF DSP crash caused by DRC pipeline ABI mismatch.
# See README.md for full explanation.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
abort()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# --- Hardware check ---
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
if [[ "$PRODUCT" != "83JX" ]]; then
    warn "DMI product name is '$PRODUCT', expected '83JX'."
    warn "This fix is designed for the Lenovo Yoga Slim 7 14ILL10 (83JX)."
    read -rp "Continue anyway? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || abort "Aborted."
fi

CARD="alsa_card.pci-0000_00_1f.3-platform-sof_sdw"
UCM_CARD="LENOVO-83JX-YogaSlim714ILL10-LNVNB161216"

echo ""
echo "Lenovo Yoga Slim 7 14ILL10 — audio fix installer"
echo "================================================="
echo ""

# --- Fix 1: WirePlumber rule ---
info "Fix 1: Adding WirePlumber rule to block DRC-crashing PCM devices..."
mkdir -p "$HOME/.config/wireplumber/main.lua.d"
cat > "$HOME/.config/wireplumber/main.lua.d/51-disable-drc-pcm.lua" << 'EOF'
-- Disable ALSA PCM devices that crash the SOF DSP on this machine.
-- Root cause: SOF topology ABI 3:29:1 vs kernel ABI 3:23:1 causes drc.21.1 (pcm2)
-- and drc.100.1 (pcm10) to fail with error 104, leaving the DSP in a broken state.
-- pcm2  = Speaker (cs35l56-bridge SmartAmp path)
-- pcm10 = DMIC (internal microphone array)

table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_output.*sof_sdw*pro-output-2" },
    },
  },
  apply_properties = {
    ["node.disabled"] = true,
  },
})

table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_input.*sof_sdw*pro-input-10" },
    },
  },
  apply_properties = {
    ["node.disabled"] = true,
  },
})
EOF
info "  Written: ~/.config/wireplumber/main.lua.d/51-disable-drc-pcm.lua"

# --- Fix 2: systemd user service ---
info "Fix 2: Installing systemd user service to set pro-audio profile at boot..."
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/audio-profile.service" << EOF
[Unit]
Description=Set audio card to pro-audio profile
After=wireplumber.service pipewire-pulse.service
Wants=wireplumber.service

[Service]
Type=oneshot
# Wait for PipeWire/WirePlumber and cs42l43 SoundWire codec to settle
ExecStartPre=/bin/sleep 4
ExecStart=/usr/bin/pactl set-card-profile ${CARD} pro-audio
RemainAfterExit=yes

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable audio-profile.service
info "  Enabled: ~/.config/systemd/user/audio-profile.service"

# --- Fix 3: UCM overrides (needs sudo) ---
info "Fix 3: Installing UCM overrides (removes broken devices from HiFi profile)..."
warn "  This step requires sudo to write to /usr/share/alsa/ucm2/"
echo ""

UCM_CONFD="/usr/share/alsa/ucm2/conf.d/sof-soundwire"
UCM_DIR="/usr/share/alsa/ucm2/sof-soundwire"

sudo mkdir -p "$UCM_CONFD"

sudo tee "$UCM_CONFD/${UCM_CARD}.conf" > /dev/null << 'EOF'
Syntax 6

# Machine-specific UCM override for Lenovo Yoga Slim 7 14ILL10 (83JX)
# Excludes DMIC (mic:dmic -> pcm10) and Speaker (spk -> pcm2) from HiFi
# to avoid DRC pipeline failure.
# Root cause: SOF topology ABI 3:29:1 vs kernel ABI 3:23:1.

SectionUseCase."HiFi" {
	File "/sof-soundwire/LENOVO-83JX-YogaSlim714ILL10-LNVNB161216-HiFi.conf"
	Comment "Play HiFi quality Music"
}

Include.led.File "/common/ctl/led.conf"
Include.card-init.File "/lib/card-init.conf"
Include.ctl-remap.File "/lib/ctl-remap.conf"

Define {
	SpeakerCodec1 ""
	SpeakerChannels1 "2"
	SpeakerAmps1 "0"
	HeadsetCodec1 ""
	MicCodec1 ""
	Mics1 "0"
	MultiCodec1 ""
}

DefineRegex {
	SpeakerCodec {
		Regex " spk:([a-z0-9]+((-sdca)|(-spk)|(-bridge))?)"
		String "${CardComponents}"
	}
	SpeakerChannels {
		Regex " cfg-spk:([0-9]+)"
		String "${CardComponents}"
	}
	SpeakerAmps {
		Regex " cfg-amp:([0-9]+)"
		String "${CardComponents}"
	}
	HeadsetCodec {
		Regex " hs:([a-z0-9]+(-sdca)?)"
		String "${CardComponents}"
	}
	# MicCodec regex intentionally omitted: mic:dmic -> pcm10 -> DRC fails (ABI mismatch)
	Mics {
		Regex " cfg-mics:([1-9][0-9]*)"
		String "${CardComponents}"
	}
	MultiCodec {
		Regex "(rt712|rt713|rt721|rt722)"
		String "${var:SpeakerCodec1} ${var:HeadsetCodec1} ${var:MicCodec1}"
	}
}

If.spk_init {
	Condition {
		Type RegexMatch
		Regex "(rt1318(-1)?|cs35l56(-bridge)?)"
		String "${var:SpeakerCodec1}"
	}
	True.Include.spk_init.File "/codecs/${var:SpeakerCodec1}/init.conf"
}

If.hs_init {
	Condition {
		Type RegexMatch
		Regex "(cs42l43|cs42l45|rt5682|rt700|rt711|rt713(-sdca)?)"
		String "${var:HeadsetCodec1}"
	}
	True.Include.hs_init.File "/codecs/${var:HeadsetCodec1}/init.conf"
}

If.mics-array {
	Condition {
		Type String
		Empty "${var:Mics1}"
	}
	False.FixedBootSequence [
		exec "-nhlt-dmic-info -o ${var:LibDir}/dmics-nhlt.json"
	]
}
EOF

sudo tee "$UCM_DIR/${UCM_CARD}-HiFi.conf" > /dev/null << 'EOF'
# HiFi verb for Lenovo Yoga Slim 7 14ILL10 (83JX)
# Same as sof-soundwire/HiFi.conf but WITHOUT spkdev or micdev includes.
# spkdev omitted: cs35l56-bridge -> pcm2 -> drc.21.1 fails -> DSP crash
# micdev omitted: dmic -> pcm10 -> drc.100.1 fails -> DSP crash

SectionVerb {
	EnableSequence [
		disdevall ""
	]

	Value.TQ "HiFi"
}

If.multicodec {
	Condition {
		Type String
		Empty "${var:MultiCodec1}"
	}
	False.Include.multicodec.File "/sof-soundwire/${var:MultiCodec1}.conf"
}

If.hsdev {
	Condition {
		Type String
		Empty "${var:HeadsetCodec1}"
	}
	False.Include.hsdev.File "/sof-soundwire/${var:HeadsetCodec1}.conf"
}

<sof-soundwire/Hdmi.conf>
EOF

info "  Written: $UCM_CONFD/${UCM_CARD}.conf"
info "  Written: $UCM_DIR/${UCM_CARD}-HiFi.conf"

# --- Restart audio ---
echo ""
info "Restarting audio stack..."
systemctl --user stop wireplumber pipewire-pulse pipewire 2>/dev/null || true
sudo bash -c 'echo 0000:00:1f.3 > /sys/bus/pci/drivers/sof-audio-pci-intel-lnl/unbind 2>/dev/null && sleep 2 && echo 0000:00:1f.3 > /sys/bus/pci/drivers/sof-audio-pci-intel-lnl/bind 2>/dev/null' || warn "SOF rebind failed — a reboot will also work."
sleep 2
systemctl --user start pipewire
sleep 1
systemctl --user start wireplumber pipewire-pulse
sleep 4
pactl set-card-profile "$CARD" pro-audio 2>/dev/null || true

# --- Summary ---
echo ""
echo "================================================="
info "Done! Checking active sinks..."
echo ""
pactl list sinks short 2>/dev/null || true
echo ""
echo -e "${GREEN}Working:${NC}  Headphones (pcm0), HDMI (pcm5/6/7)"
echo -e "${RED}Broken:${NC}   Built-in speakers, internal microphone"
echo -e "          (cs35l56-bridge + DMIC require DRC which is broken by SOF ABI mismatch)"
echo ""
warn "This fix survives reboots. If audio breaks after a kernel/WirePlumber update,"
warn "re-run this script."
echo ""
warn "Please revoke any GitHub tokens you shared during setup!"
