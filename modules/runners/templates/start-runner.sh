# shellcheck shell=bash

## Retrieve instance metadata

echo "Retrieving TOKEN from AWS API"
token=$(curl -sSL -X PUT --retry 40 --retry-connrefused --retry-delay 5 "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 180")

ami_id=$(curl -fsSL -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/ami-id)
echo "ami_id = $ami_id"
region=$(curl -fsSL -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
echo "region = $region"
instance_id=$(curl -fsSL -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-id)
echo "instance_id = $instance_id"
instance_type=$(curl -fsSL -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-type)
echo "instance_type = $instance_type"
availability_zone=$(curl -fsSL -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/availability-zone)
echo "availability_zone = $availability_zone"

resolvectl flush-caches

%{ if metadata_tags == "enabled" }
environment=$(curl -fsSL -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:environment)
ssm_config_path=$(curl -fsSL -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:ssm_config_path)
runner_name_prefix=$(curl -fsSL -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:runner_name_prefix || echo "")
runner_redis_url=$(curl -fsSL -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:runner_redis_url)

%{ else }

tags=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id")
echo "Retrieved tags from AWS API ($tags)"
environment=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:environment") | .Value')
ssm_config_path=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:ssm_config_path") | .Value')
runner_name_prefix=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:runner_name_prefix") | .Value' || echo "")
runner_redis_url=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:runner_redis_url") | .Value' || echo "")

%{ endif }

echo "ghr:environment = $environment"
echo "ghr:ssm_config_path = $ssm_config_path"
echo "ghr:runner_name_prefix = $runner_name_prefix"
echo "ghr:runner_redis_url = $runner_redis_url"

parameters=$(aws ssm get-parameters-by-path --path "$ssm_config_path" --region "$region" --query "Parameters[*].{Name:Name,Value:Value}")
echo "Retrieved parameters from AWS SSM ($parameters)"

run_as=$(echo "$parameters" | jq -r '.[] | select(.Name == "'$ssm_config_path'/run_as") | .Value')
echo "Retrieved /$ssm_config_path/run_as parameter - ($run_as)"

enable_cloudwatch_agent=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/enable_cloudwatch") | .Value')
echo "Retrieved /$ssm_config_path/enable_cloudwatch parameter - ($enable_cloudwatch_agent)"

agent_mode=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/agent_mode") | .Value')
echo "Retrieved /$ssm_config_path/agent_mode parameter - ($agent_mode)"

enable_jit_config=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/enable_jit_config") | .Value')
echo "Retrieved /$ssm_config_path/enable_jit_config parameter - ($enable_jit_config)"

docker_cache_proxy=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/docker_cache_proxy") | .Value')
echo "Retrieved /$ssm_config_path/docker_cache_proxy parameter - ($docker_cache_proxy)"

if [[ "$enable_cloudwatch_agent" == "true" ]]; then
  echo "Cloudwatch is enabled, initializing cloudwatch agent."
  amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c "ssm:$ssm_config_path/cloudwatch_agent_config_runner"
fi

## Configure the runner

echo "Get GH Runner config from redis"
config=$(redis-cli -h "$runner_redis_url" GET "$instance_id")
echo "Retrieved config from redis: $(echo $config | base64 -d | jq -r '.[".runner"]' | base64 -d)"
redis-cli -h "$runner_redis_url" DEL "$instance_id"

if [ -z "$run_as" ]; then
  echo "No user specified, using default ec2-user account"
  run_as="ec2-user"
fi

if [ -b /dev/nvme1n1 ]; then
    echo "Found extra data volume, format and mount to /data"
    mount
    lsblk
    if ! mkfs.xfs -f -L data /dev/nvme1n1; then
      echo "Failed to format /dev/nvme1n1"
      aws ec2 terminate-instances --instance-ids $instance_id --region $region
      exit 1
    fi

    mkdir -p /data
    mount -L data /data
    mkdir -p /data/docker
    chown -R root:docker /data/docker

    mkdir -p /data/_work
    chown -R $run_as:$run_as /data/_work
    rm -rf /opt/actions-runner/_work
    ln -s /data/_work /opt/actions-runner/

    mkdir -p /data/_diag
    chown -R $run_as:$run_as /data/_diag
    rm -rf /opt/actions-runner/_diag
    ln -s /data/_diag /opt/actions-runner/
fi

if [ -n "$docker_cache_proxy" ]; then
  echo "Setting docker cache proxy to $docker_cache_proxy"
  # See https://docs.docker.com/registry/recipes/mirror/
  tmp=$(mktemp)
  jq --arg reg "http://$docker_cache_proxy,http://$docker_cache_proxy:81" '."registry-mirrors" = ($reg|split(","))' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
  tmp=$(mktemp)
  jq --arg reg "$docker_cache_proxy,$docker_cache_proxy:81" '."insecure-registries" = ($reg|split(","))' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json

  # without below config, docker buildx will fail when throttled by docker hub
  # https://stackoverflow.com/questions/63409755/how-to-use-docker-buildx-pushing-image-to-registry-use-http-protocol#63411302
  # https://github.com/docker/buildx/issues/1370
  # https://docs.docker.com/build/buildkit/toml-configuration/
  # https://github.com/moby/buildkit/blob/master/docs/buildkitd.toml.md
  mkdir -p /home/$run_as/.docker/buildx
  chown -R $run_as /home/$run_as/.docker
  cat > /home/$run_as/.docker/buildx/buildkitd.default.toml <<EOF
[registry."$docker_cache_proxy:80"]
http = true
insecure = true

[registry."$docker_cache_proxy:81"]
http = true
insecure = true
EOF

  mkdir -p /root/.docker/buildx
  cat > /root/.docker/buildx/buildkitd.default.toml <<EOF
[registry."$docker_cache_proxy:80"]
http = true
insecure = true

[registry."$docker_cache_proxy:81"]
http = true
insecure = true
EOF
fi

systemctl restart docker.service
docker info

if [[ "$run_as" == "root" ]]; then
  echo "run_as is set to root - export RUNNER_ALLOW_RUNASROOT=1"
  export RUNNER_ALLOW_RUNASROOT=1
fi

chown -R $run_as .

info_arch=$(uname -p)
info_os=$(( lsb_release -ds || cat /etc/*release || uname -om ) 2>/dev/null | head -n1 | cut -d "=" -f2- | tr -d '"')

jq -n \
  --arg info_os "$info_os" \
  --arg info_arch "$info_arch" \
  --arg ami_id "$ami_id" \
  --arg instance_type "$instance_type" \
  --arg availability_zone "$availability_zone" \
  '[
     {"group": "Operating System", "detail": "Distribution: \($info_os)\nArchitecture: \($info_arch)"},
     {"group": "Runner Image", "detail": "AMI id: \($ami_id)"},
     {"group": "EC2", "detail": "Instance type: \($instance_type)\nAvailability zone: \($availability_zone)"}
   ]' > /opt/actions-runner/.setup_info

JOB_STARTED_HOOK=/opt/actions-runner/job-started-hook.sh
JOB_COMPLETED_HOOK=/opt/actions-runner/job-completed-hook.sh

cat > $JOB_STARTED_HOOK <<EOF
#!/bin/bash
set -x
df -h
redis-cli -h "$runner_redis_url" DEL "workflow:\$GITHUB_RUN_ID:ts"
redis-cli -h "$runner_redis_url" DEL "workflow:\$GITHUB_RUN_ID:payload"
redis-cli -h "$runner_redis_url" DEL "workflow:\$GITHUB_RUN_ID:requeue_count"

EOF

cat > $JOB_COMPLETED_HOOK <<EOF
#!/bin/bash
set -x
journalctl -u docker.service --no-pager

EOF

runner_s3_bucket=id-emqx-test
if [ -n "$runner_s3_bucket" ]; then
    if aws s3api head-object --bucket "$runner_s3_bucket" --key job_started_hook.sh >/dev/null 2>&1; then
        aws s3 cp s3://$s3_bucket_name/job_started_hook.sh /tmp/job_started_hook.sh
        cat /tmp/job_started_hook.sh >> $JOB_STARTED_HOOK
    fi
    if aws s3api head-object --bucket "$runner_s3_bucket" --key job_completed_hook.sh >/dev/null 2>&1; then
        aws s3 cp s3://$s3_bucket_name/job_completed_hook.sh /tmp/job_completed_hook.sh
        cat /tmp/job_completed_hook.sh >> $JOB_COMPLETED_HOOK
    fi
fi

chmod a+x $JOB_STARTED_HOOK
chmod a+x $JOB_COMPLETED_HOOK

echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$JOB_STARTED_HOOK" >> /opt/actions-runner/.env
echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$JOB_COMPLETED_HOOK" >> /opt/actions-runner/.env

## Start the runner
echo "Starting runner after $(awk '{print int($1/3600)":"int(($1%3600)/60)":"int($1%60)}' /proc/uptime)"
echo "Starting the runner as user $run_as"

# configure the runner if the runner is non ephemeral or jit config is disabled
if [[ "$enable_jit_config" == "false" || $agent_mode != "ephemeral" ]]; then
  echo "Configure GH Runner as user $run_as"
  sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./config.sh --unattended --name "$runner_name_prefix$instance_id" --work "_work" $${config}
fi

if [[ $agent_mode = "ephemeral" ]]; then

cat >/opt/start-runner-service.sh <<-EOF

  echo "Starting the runner in ephemeral mode"

  if [[ "$enable_jit_config" == "true" ]]; then
    echo "Starting with JIT config"
    sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./run.sh --jitconfig $${config}
  else
    echo "Starting without JIT config"
    sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./run.sh
  fi

  echo "Runner has finished"
  echo "Stopping cloudwatch service"
  systemctl stop amazon-cloudwatch-agent.service
  echo "Terminating instance"
  aws ec2 terminate-instances --instance-ids "$instance_id" --region "$region"
EOF
  # Starting the runner via a own process to ensure this process terminates
  nohup bash /opt/start-runner-service.sh &

else
  echo "Installing the runner as a service"
  ./svc.sh install "$run_as"
  echo "Starting the runner in persistent mode"
  ./svc.sh start
fi
