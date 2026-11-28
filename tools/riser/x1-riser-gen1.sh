#!/bin/bash
# Keep NVIDIA cards that sit on a PCIe x1 link (a USB-cable mining riser, for example) at 2.5 GT/s, before the NVIDIA
# driver loads. Such a riser may not carry the 8 GT/s the driver switches to when it starts the card: the card then
# falls off the bus (Xid 79) a few seconds after the driver loads. The cards come up at 2.5 GT/s; this sets the Target
# Link Speed (Link Control 2) of the port above each such card to 2.5 GT/s, the upper limit for that link, and retrains
# the link. Run by x1-riser-gen1.service, before udev starts loading drivers. Undo: disable the service.
# X1_RISER_SPEED=2 (set in the service: Environment=X1_RISER_SPEED=2) caps at 5 GT/s instead; check the link's
# correctable errors under load before keeping it (docs/troubleshooting.md).
S=${X1_RISER_SPEED:-1}; case "$S" in 1|2|3) ;; *) echo "X1_RISER_SPEED must be 1, 2 or 3"; exit 0 ;; esac
for d in /sys/bus/pci/devices/*; do
  [ -r "$d/vendor" ] && [ "$(cat "$d/vendor")" = 0x10de ] || continue
  case "$(cat "$d/class")" in 0x0300*|0x0302*) ;; *) continue ;; esac
  [ "$(cat "$d/current_link_width" 2>/dev/null)" = 1 ] || continue
  port=$(basename "$(dirname "$(readlink -f "$d")")"); p=${port#0000:}
  old=$(setpci -s "$p" CAP_EXP+30.w) || { echo "$(basename "$d"): port $p unreadable"; continue; }
  setpci -s "$p" CAP_EXP+30.w=000$S:000f && setpci -s "$p" CAP_EXP+10.w=0020:0020
  sleep 0.3
  echo "$(basename "$d") on port $p: target link speed $old -> $(setpci -s "$p" CAP_EXP+30.w), link now $(cat "$d/current_link_speed") x$(cat "$d/current_link_width")"
done
exit 0
