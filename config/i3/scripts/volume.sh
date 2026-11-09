#!/usr/bin/env bash
# Usage: volume.sh up|down|mute|mic-up|mic-down|mic-mute

SINK=@DEFAULT_AUDIO_SINK@
SRC=@DEFAULT_AUDIO_SOURCE@

case "$1" in
    up)       wpctl set-volume -l 1.0 $SINK 5%+ ;;
    down)     wpctl set-volume $SINK 5%- ;;
    mute)     wpctl set-mute $SINK toggle ;;
    mic-up)   wpctl set-volume -l 1.0 $SRC 5%+ ;;
    mic-down) wpctl set-volume $SRC 5%- ;;
    mic-mute) wpctl set-mute $SRC toggle ;;
    *) echo "Usage: $0 up|down|mute|mic-up|mic-down|mic-mute"; exit 1 ;;
esac

# Pick which device to report on
case "$1" in
    mic-*) DEV=$SRC;  LABEL="Microphone" ;;
    *)     DEV=$SINK; LABEL="Volume" ;;
esac

out=$(wpctl get-volume $DEV)              # e.g. "Volume: 0.45 [MUTED]"
vol=$(awk '{print int($2*100)}' <<< "$out")

if [[ $out == *MUTED* ]]; then
    text="$LABEL: muted"
else
    text="$LABEL: ${vol}%"
fi

notify-send -t 1500 \
    -h int:value:"$vol" \
    -h string:x-dunst-stack-tag:"$LABEL" \
    "$text"

# Refresh the matching i3blocks block
case "$1" in
    mic-*) pkill -RTMIN+11 i3blocks ;;
    *)     pkill -RTMIN+10 i3blocks ;;
esac
