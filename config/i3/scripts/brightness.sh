#!/usr/bin/env bash
# Usage: brightness.sh up|down

case "$1" in
    up)   brightnessctl -q set 5%+ ;;
    down) brightnessctl -q -n set 5%- ;;   # -n keeps a minimum so the screen never goes fully black
    *) echo "Usage: $0 up|down"; exit 1 ;;
esac

pct=$(( $(brightnessctl get) * 100 / $(brightnessctl max) ))

notify-send -t 1500 \
    -h int:value:"$pct" \
    -h string:x-dunst-stack-tag:brightness \
    "Brightness: ${pct}%"
