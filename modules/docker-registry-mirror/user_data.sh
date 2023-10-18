#!/bin/bash -x

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive

# Enable retry logic for apt up to 10 times
echo "APT::Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries

apt-get -y update
apt-get -y install apt-transport-https ca-certificates software-properties-common
apt-get -y install curl gnupg lsb-release jq git unzip curl wget net-tools dnsutils
apt-get -y install --no-install-recommends python3 python3-pip python3-venv python-is-python3

wget -q https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip -O /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

ARCH=$(dpkg --print-architecture) # amd64/arm64

SSM_ARCH=
case "$ARCH" in
 amd64) SSM_ARCH=64bit ;;
 arm64) SSM_ARCH=arm64 ;;
esac

wget -q https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_$SSM_ARCH/session-manager-plugin.deb -O /tmp/session-manager-plugin.deb
apt install /tmp/session-manager-plugin.deb

# cloudwatch agent
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/$ARCH/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb
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
                    "log_stream_name": "docker-registry-mirror",
                    "retention_in_days": ${logging_retention_in_days}
                  },
                  {
                    "file_path": "/var/log/user-data.log",
                    "log_group_name": "${log_group_name}",
                    "log_stream_name": "docker-registry-mirror",
                    "retention_in_days": ${logging_retention_in_days}
                  }
                ]
            }
        }
    }
}
EOF

amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c "file:/tmp/cloudwatch-config.json"

# install docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo deb [arch=$ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable > /etc/apt/sources.list.d/docker.list
apt-get -y update
apt-get -y install docker-ce docker-ce-cli containerd.io

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
fi

systemctl enable --now containerd.service
systemctl enable --now docker.service

RUNNER_ARCH=
case "$ARCH" in
 amd64) RUNNER_ARCH=linux-x64 ;;
 arm64) RUNNER_ARCH=linux-arm64 ;;
esac


mkdir -p /etc/docker/certs
aws ssm get-parameter \
    --name "/github-action-runners/ci/$RUNNER_ARCH/runners/config/docker_registry_mirror_cert" \
    --query 'Parameter.Value' \
    --output text \
    --with-decryption > /etc/docker/certs/server.crt
aws ssm get-parameter \
    --name "/github-action-runners/ci/$RUNNER_ARCH/runners/config/docker_registry_mirror_key" \
    --query 'Parameter.Value' \
    --output text \
    --with-decryption > /etc/docker/certs/server.key

docker run -d \
       --restart=always \
       --name registry \
       -v /data/registry/registry-1.docker.io:/var/lib/registry/ \
       -v /etc/docker/certs:/certs \
       -e REGISTRY_HTTP_ADDR=0.0.0.0:443 \
       -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/server.crt \
       -e REGISTRY_HTTP_TLS_KEY=/certs/server.key \
       -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
       -p 443:443 \
       public.ecr.aws/docker/library/registry:2

docker run -d --restart=always -p 6379:6379 --name redis public.ecr.aws/docker/library/redis:latest
