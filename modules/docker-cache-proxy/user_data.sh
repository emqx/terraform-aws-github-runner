#!/bin/bash -x

export DEBIAN_FRONTEND=noninteractive

# Enable retry logic for apt up to 10 times
echo "APT::Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries

apt-get -y update
apt-get -y install apt-transport-https ca-certificates software-properties-common
apt-get -y install --no-install-recommends python3 python3-pip python3-venv python-is-python3

# cloudwatch agent
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb
apt-get install -y /tmp/amazon-cloudwatch-agent.deb

cat <<EOF > /tmp/cloudwatch-config.json
{
    "agent": {
        "metrics_collection_interval": 5
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                  {
                    "file_path": "/var/log/cloud-init-output.log",
                    "log_group_name": "${log_group_name}",
                    "log_stream_name": "docker-cache-proxy",
                    "retention_in_days": 7
                  }
                ]
            }
        }
    }
}
EOF

amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c "file:/tmp/cloudwatch-config.json"

wget -q https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb -O /tmp/session-manager-plugin.deb
apt install /tmp/session-manager-plugin.deb

# install docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable > /etc/apt/sources.list.d/docker.list
apt-get -y update
apt-get -y install docker-ce docker-ce-cli containerd.io
systemctl enable --now containerd.service
systemctl enable --now docker.service

if [ -b /dev/nvme1n1 ]; then
    echo "Found extra data volume, format and mount to /data"
    mount
    lsblk
    mkfs.xfs -f -L data /dev/nvme1n1
    mkdir -p /data
    mount -L data /data
    mkdir -p /data/docker
    chown -R root:docker /data
    cat << EOF >> /etc/docker/daemon.json
{
  "data-root": "/data/docker"
}
EOF

    systemctl restart docker.service
fi

usermod -a -G docker ubuntu

start_registry() {
    local name=$1
    local lport=$2
    local upstream_name=$3
    local data_dir="/data/registry/$name"
    mkdir -p "$data_dir"
    docker run -d --restart=always -p "$lport":5000 -e REGISTRY_PROXY_REMOTEURL="$upstream_name" \
        -v "$data_dir":/var/lib/registry/ --name "$name" registry:2
}

start_registry ghcr 80 "https://ghcr.io"
start_registry docker 81 "https://registry-1.docker.io"
