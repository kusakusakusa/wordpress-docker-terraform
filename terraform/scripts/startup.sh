#!/usr/bin/env bash

# will only run once on successful terraform deploy

echo Installing necessary packages
sudo yum -y update
sudo yum -y install docker git
sudo service docker start
sudo chmod 666 /var/run/docker.sock

echo Create swapfile
sudo dd if=/dev/zero of=/swapfile bs=1M count=1024
sudo mkswap /swapfile
sudo chmod +x /swapfile
sudo swapon /swapfile

echo Mounting EBS volume and creating necessary folders
# with reference to https://devopscube.com/mount-ebs-volume-ec2-instance/
# reformat empty volume to desired ext4 file system
if [[ $(sudo file -s /dev/xvdf) == "/dev/xvdf: data" ]]
then
  echo "EBS volume mounted on /dev/xvdf is empty. Formatting to ext4 format now..."
  sudo mkfs -t ext4 /dev/xvdf
else
  echo "EBS volume already contains content. Nothing to do here."
fi

echo "Creating /wordpress-docker-terraform, changing permissions and mounting EBS volume"
sudo mkdir -p /wordpress-docker-terraform
sudo mount /dev/xvdf /wordpress-docker-terraform/
sudo chmod -R 775 /wordpress-docker-terraform
sudo chown -R $(whoami) /wordpress-docker-terraform
sudo chgrp -R $(whoami) /wordpress-docker-terraform