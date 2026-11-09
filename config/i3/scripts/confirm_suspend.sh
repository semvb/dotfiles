#!/bin/bash
# confirm_suspend.sh

zenity --question --text="Are you sure you want to suspend?" --title="Confirm"
if [ $? -eq 0 ]; then
    systemctl suspend
fi
