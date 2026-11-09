#!/bin/bash
# confirm_poweroff.sh

zenity --question --text="Are you sure you want to poweroff?" --title="Confirm"
if [ $? -eq 0 ]; then
    systemctl poweroff
fi
