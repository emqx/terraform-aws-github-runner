#!/bin/bash

# https://docs.aws.amazon.com/xray/latest/devguide/xray-api-sendingdata.html
# https://docs.aws.amazon.com/xray/latest/devguide/scorekeep-scripts.html
create_xray_start_segment() {
  START_TIME=$(date -d "$(uptime -s)" +%s)
  TRACE_ID=$1
  INSTANCE_ID=$2
  SEGMENT_ID=$(dd if=/dev/random bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d ' \t\n')
  SEGMENT_DOC="{\"trace_id\": \"$TRACE_ID\", \"id\": \"$SEGMENT_ID\", \"start_time\": $START_TIME, \"in_progress\": true, \"name\": \"Runner\",\"origin\": \"AWS::EC2::Instance\", \"aws\": {\"ec2\":{\"instance_id\":\"$INSTANCE_ID\"}}}"
  HEADER='{"format": "json", "version": 1}'
  TRACE_DATA="$HEADER\n$SEGMENT_DOC"
  echo "$HEADER" > document.txt
  echo "$SEGMENT_DOC" >> document.txt
  UDP_IP="127.0.0.1"
  UDP_PORT=2000
  cat document.txt > /dev/udp/$UDP_IP/$UDP_PORT
  echo "$SEGMENT_DOC"
}

create_xray_success_segment() {
  local SEGMENT_DOC=$1
  if [ -z "$SEGMENT_DOC" ]; then
    echo "No segment doc provided"
    return
  fi
  SEGMENT_DOC=$(echo "$SEGMENT_DOC" | jq '. | del(.in_progress)')
  END_TIME=$(date +%s)
  SEGMENT_DOC=$(echo "$SEGMENT_DOC" | jq -c ". + {\"end_time\": $END_TIME}")
  HEADER="{\"format\": \"json\", \"version\": 1}"
  TRACE_DATA="$HEADER\n$SEGMENT_DOC"
  echo "$HEADER" > document.txt
  echo "$SEGMENT_DOC" >> document.txt
  UDP_IP="127.0.0.1"
  UDP_PORT=2000
  cat document.txt > /dev/udp/$UDP_IP/$UDP_PORT
  echo "$SEGMENT_DOC"
}

create_xray_error_segment() {
  local SEGMENT_DOC="$1"
  if [ -z "$SEGMENT_DOC" ]; then
    echo "No segment doc provided"
    return
  fi
  MESSAGE="$2"
  ERROR="{\"exceptions\": [{\"message\": \"$MESSAGE\"}]}"
  SEGMENT_DOC=$(echo "$SEGMENT_DOC" | jq '. | del(.in_progress)')
  END_TIME=$(date +%s)
  SEGMENT_DOC=$(echo "$SEGMENT_DOC" | jq -c ". + {\"end_time\": $END_TIME, \"error\": true, \"cause\": $ERROR }")
  HEADER="{\"format\": \"json\", \"version\": 1}"
  TRACE_DATA="$HEADER\n$SEGMENT_DOC"
  echo "$HEADER" > document.txt
  echo "$SEGMENT_DOC" >> document.txt
  UDP_IP="127.0.0.1"
  UDP_PORT=2000
  cat document.txt > /dev/udp/$UDP_IP/$UDP_PORT
  echo "$SEGMENT_DOC"
}

cleanup() {
  local exit_code="$1"
  local error_location="$2"
  local error_lineno="$3"

  if [ "$exit_code" -ne 0 ]; then
    echo "ERROR: runner-start-failed with exit code $exit_code occurred on $error_location"
    create_xray_error_segment "$SEGMENT" "runner-start-failed with exit code $exit_code occurred on $error_location - $error_lineno"
  fi
  # allows to flush the cloud watch logs and traces
  sleep 10
  if [ "$agent_mode" = "ephemeral" ] || [ "$exit_code" -ne 0 ]; then
    keep=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id" "Name=key,Values=ghr:keep" --query 'Tags[0].Value' --output text)
    if [ "$keep" = "true" ]; then
        echo "The instance is marked for keeping it running."
    else
        echo "Stopping CloudWatch service"
        systemctl stop amazon-cloudwatch-agent.service || true
        echo "Terminating instance"
        aws ec2 terminate-instances \
            --instance-ids "$instance_id" \
            --region "$region" \
            || true
    fi
  fi
}

trap 'cleanup $? $LINENO $BASH_LINENO' EXIT

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
xray_trace_id=$(curl -fsSL -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:trace_id || echo "")

%{ else }

tags=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id")
echo "Retrieved tags from AWS API ($tags)"
environment=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:environment") | .Value')
ssm_config_path=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:ssm_config_path") | .Value')
runner_name_prefix=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:runner_name_prefix") | .Value' || echo "")
runner_redis_url=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:runner_redis_url") | .Value' || echo "")
xray_trace_id=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:trace_id") | .Value' || echo "")

%{ endif }

echo "ghr:environment: $environment"
echo "ghr:ssm_config_path: $ssm_config_path"
echo "ghr:runner_name_prefix: $runner_name_prefix"
echo "ghr:runner_redis_url: $runner_redis_url"

parameters=$(aws ssm get-parameters-by-path --path "$ssm_config_path" --region "$region" --with-decryption --query "Parameters[*].{Name:Name,Value:Value}")
echo "Retrieved parameters from AWS SSM"

run_as=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/run_as") | .Value')
echo "$ssm_config_path/run_as: $run_as"

enable_cloudwatch_agent=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/enable_cloudwatch") | .Value')
echo "$ssm_config_path/enable_cloudwatch: $enable_cloudwatch_agent"

agent_mode=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/agent_mode") | .Value')
echo "$ssm_config_path/agent_mode: $agent_mode"

enable_jit_config=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/enable_jit_config") | .Value')
echo "$ssm_config_path/enable_jit_config: $enable_jit_config"

docker_registry_mirror=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/docker_registry_mirror") | .Value')
echo "$ssm_config_path/docker_registry_mirror: $docker_registry_mirror"

docker_registry_mirror_cert=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/docker_registry_mirror_cert") | .Value')
[ -n "$docker_registry_mirror_cert" ] && echo "$ssm_config_path/docker_registry_mirror_cert is configured"

if [[ "$xray_trace_id" != "" ]]; then
  # run xray service
  curl https://s3.us-east-2.amazonaws.com/aws-xray-assets.us-east-2/xray-daemon/aws-xray-daemon-linux-3.x.zip -o aws-xray-daemon-linux-3.x.zip
  unzip aws-xray-daemon-linux-3.x.zip -d aws-xray-daemon-linux-3.x
  chmod +x ./aws-xray-daemon-linux-3.x/xray
  ./aws-xray-daemon-linux-3.x/xray -o -n "$region" &


  SEGMENT=$(create_xray_start_segment "$xray_trace_id" "$instance_id")
  echo "$SEGMENT"
fi

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

if [ -n "$docker_registry_mirror" ]; then
  echo "Setting docker registry mirror to $docker_registry_mirror"
  # See https://docs.docker.com/registry/recipes/mirror/
  tmp=$(mktemp)
  if [ -n "$docker_registry_mirror_cert" ]; then
    echo "Setting docker registry mirror cert"
    mkdir -p "/etc/docker/certs.d/$docker_registry_mirror"
    echo "$docker_registry_mirror_cert" > "/etc/docker/certs.d/$docker_registry_mirror/ca.crt"
    jq --arg reg "https://$docker_registry_mirror" '."registry-mirrors" = ($reg|split(","))' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
  else
    jq --arg reg "http://$docker_registry_mirror" '."registry-mirrors" = ($reg|split(","))' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json
    # without below config, docker buildx will fail when throttled by docker hub
    # https://stackoverflow.com/questions/63409755/how-to-use-docker-buildx-pushing-image-to-registry-use-http-protocol#63411302
    # https://github.com/docker/buildx/issues/1370
    # https://docs.docker.com/build/buildkit/toml-configuration/
    # https://github.com/moby/buildkit/blob/master/docs/buildkitd.toml.md
    mkdir -p /home/$run_as/.docker/buildx
    chown -R $run_as /home/$run_as/.docker
    cat > /home/$run_as/.docker/buildx/buildkitd.default.toml <<EOF
[registry."$docker_registry_mirror:80"]
http = true
insecure = true
EOF

    mkdir -p /root/.docker/buildx
    cat > /root/.docker/buildx/buildkitd.default.toml <<EOF
[registry."$docker_registry_mirror:80"]
http = true
insecure = true
EOF

    # see https://github.com/docker/buildx/issues/1642
    # remove when moby v25 is released
    echo 'export DOCKER_BUILDKIT=0' >> /etc/environment
  fi
fi

systemctl restart docker.service
docker info

if [[ "$run_as" == "root" ]]; then
  echo "run_as is set to root - export RUNNER_ALLOW_RUNASROOT=1"
  export RUNNER_ALLOW_RUNASROOT=1
fi

chown -R $run_as .

info_arch=$(uname -p)
info_os=$( ( lsb_release -ds || cat /etc/*release || uname -om ) 2>/dev/null | head -n1 | cut -d "=" -f2- | tr -d '"')

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

# runner_s3_bucket=id-emqx-test
# if [ -n "$runner_s3_bucket" ]; then
#     if aws s3api head-object --bucket "$runner_s3_bucket" --key job_started_hook.sh; then
#         echo "Found job_started_hook.sh in $runner_s3_bucket, adding extra commands to $JOB_STARTED_HOOK"
#         aws s3 cp s3://$s3_bucket_name/job_started_hook.sh /tmp/job_started_hook.sh
#         cat /tmp/job_started_hook.sh >> $JOB_STARTED_HOOK
#     fi
#     if aws s3api head-object --bucket "$runner_s3_bucket" --key job_completed_hook.sh; then
#         echo "Found job_completed_hook.sh in $runner_s3_bucket, adding extra commands to $JOB_COMPLETED_HOOK"
#         aws s3 cp s3://$s3_bucket_name/job_completed_hook.sh /tmp/job_completed_hook.sh
#         cat /tmp/job_completed_hook.sh >> $JOB_COMPLETED_HOOK
#     fi
# fi

chown $run_as $JOB_STARTED_HOOK $JOB_COMPLETED_HOOK
chmod a+x $JOB_STARTED_HOOK $JOB_COMPLETED_HOOK

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

create_xray_success_segment "$SEGMENT"
if [[ $agent_mode = "ephemeral" ]]; then
  echo "Starting the runner in ephemeral mode"

  if [[ "$enable_jit_config" == "true" ]]; then
    echo "Starting with JIT config"
    sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./run.sh --jitconfig $${config}
  else
    echo "Starting without JIT config"
    sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./run.sh
  fi
  echo "Runner has finished"
else
  echo "Installing the runner as a service"
  ./svc.sh install "$run_as"
  echo "Starting the runner in persistent mode"
  ./svc.sh start
fi
