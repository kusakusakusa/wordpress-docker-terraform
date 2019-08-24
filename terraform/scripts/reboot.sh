#!/usr/bin/env bash

# set swap and ebs mount config on reboot
# will only run once on successful terraform deploy

AUTOMOUNT_CONFIG="/dev/xvdf /wordpress-docker-terraform ext4 defaults,nofail 0 0"
SWAP_CONFIG="/swapfile swap swap defaults 0 0"

sudo cp /etc/fstab /etc/fstab.bak
echo "fstab backup created."

echo $AUTOMOUNT_CONFIG | sudo tee -a /etc/fstab
echo $SWAP_CONFIG | sudo tee -a /etc/fstab
sudo mount -a