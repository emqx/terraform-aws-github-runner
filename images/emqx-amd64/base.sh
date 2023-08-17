#!/bin/bash -e

export DEBIAN_FRONTEND=noninteractive

# Enable retry logic for apt up to 10 times
echo "APT::Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries

# Configure apt to always assume Y
echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes

echo 'session required pam_limits.so' >> /etc/pam.d/common-session
echo 'session required pam_limits.so' >> /etc/pam.d/common-session-noninteractive
echo 'DefaultLimitNOFILE=65536' >> /etc/systemd/system.conf
echo 'DefaultLimitSTACK=16M:infinity' >> /etc/systemd/system.conf

# Raise Number of File Descriptors
echo '* soft nofile 65536' >> /etc/security/limits.conf
echo '* hard nofile 65536' >> /etc/security/limits.conf

# Double stack size from default 8192KB
echo '* soft stack 16384' >> /etc/security/limits.conf
echo '* hard stack 16384' >> /etc/security/limits.conf

cat << EOF > /var/lib/cloud/scripts/per-instance/01-mount-data.sh
#!/bin/bash -e
if [ -b /dev/nvme1n1 ]; then
    logger -t "cloud-init" "Found extra data volume, format and mount to /data"
    mkfs.ext4 -L data /dev/nvme1n1
    mkdir -p /data
    mount -L data /data
    mkdir -p /data/docker
    chown -R root:docker /data/docker
    mkdir -p /data/_work
    chown -R ubuntu:ubuntu /data/_work
    rm -rf /opt/actions-runner/_work
    ln -s /data/_work /opt/actions-runner/
    systemctl restart docker
fi
EOF
chmod +x /var/lib/cloud/scripts/per-instance/01-mount-data.sh

apt-get -y update
apt-get -y install apt-transport-https ca-certificates software-properties-common
# https://github.com/ilikenwf/apt-fast
add-apt-repository ppa:apt-fast/stable
apt-get -y update
apt-get -y install apt-fast
apt-get -y install curl gnupg lsb-release jq git unzip curl wget net-tools dnsutils
apt-get -y install build-essential autoconf automake cmake
apt-get -y install --no-install-recommends python3 python3-pip python3-venv python-is-python3
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable > /etc/apt/sources.list.d/docker.list
apt-get -y update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now containerd.service
systemctl enable --now docker.service
usermod -a -G docker ubuntu

cat << EOF > /usr/bin/docker-compose
#!/bin/sh
docker compose "\$@"
EOF
chmod +x /usr/bin/docker-compose

curl -f https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -o amazon-cloudwatch-agent.deb
dpkg -i amazon-cloudwatch-agent.deb
systemctl restart amazon-cloudwatch-agent
curl -f https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o awscliv2.zip
unzip -q awscliv2.zip
./aws/install

wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /tmp/yq
mv /tmp/yq /usr/bin/yq
chmod +x /usr/bin/yq

systemctl restart snapd.socket
systemctl restart snapd
snap set system refresh.hold="$(date --date='today+60 days' +%Y-%m-%dT%H:%M:%S%:z)"

# Stop and disable apt-daily upgrade services;
systemctl stop apt-daily.timer
systemctl disable apt-daily.timer
systemctl disable apt-daily.service
systemctl stop apt-daily-upgrade.timer
systemctl disable apt-daily-upgrade.timer
systemctl disable apt-daily-upgrade.service

apt-get purge unattended-upgrades

# cache builder image
docker pull ghcr.io/emqx/emqx-builder/5.1-3:1.14.5-25.3.2-1-ubuntu22.04

# clean up
journalctl --rotate
journalctl --vacuum-time=1s

# delete all .gz and rotated file
find /var/log -type f -regex ".*\.gz$" -delete
find /var/log -type f -regex ".*\.[0-9]$" -delete

# wipe log files
find /var/log/ -type f -exec cp /dev/null {} \;
