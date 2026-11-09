#!/bin/bash
# confirm_reboot.sh

zenity --question --text="Are you sure you want to reboot?" --title="Confirm"
if [ $? -eq 0 ]; then
    reboot
fi
