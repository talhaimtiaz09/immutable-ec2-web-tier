#!/usr/bin/env bash
# Roll the ASG onto the launch template version Terraform just created.
#
# Run from terraform/envs/lab after `terraform apply`. Terraform creates the new
# launch template version but leaves the ASG on the old one (ignore_changes).
# This starts an instance refresh with that version as DesiredConfiguration, so
# AWS saves it on the ASG only if the refresh succeeds. If a rollback alarm
# fires, AWS rolls back to the previous version and this script exits 1.
set -euo pipefail

POLL_SECONDS=20
TIMEOUT_SECONDS=3600

asg=$(terraform output -raw asg_name)
lt_id=$(terraform output -raw launch_template_id)
target=$(terraform output -raw launch_template_latest_version)
warmup=$(terraform output -raw instance_warmup)
alarms=$(terraform output -json rollback_alarm_names)

current=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$asg" \
  --query 'AutoScalingGroups[0].LaunchTemplate.Version' --output text)

if [[ "$current" == "$target" ]]; then
  echo "ASG $asg already on launch template version $target. Nothing to roll out."
  exit 0
fi

echo "Refreshing $asg: launch template version $current -> $target"

request=$(jq -n \
  --arg asg "$asg" --arg lt "$lt_id" --arg version "$target" \
  --argjson warmup "$warmup" --argjson alarms "$alarms" \
  '{
    AutoScalingGroupName: $asg,
    Strategy: "Rolling",
    DesiredConfiguration: { LaunchTemplate: { LaunchTemplateId: $lt, Version: $version } },
    Preferences: {
      MinHealthyPercentage: 100,
      MaxHealthyPercentage: 200,
      InstanceWarmup: $warmup,
      AutoRollback: true,
      AlarmSpecification: { Alarms: $alarms }
    }
  }')

refresh_id=$(aws autoscaling start-instance-refresh \
  --cli-input-json "$request" --query InstanceRefreshId --output text)
echo "Instance refresh $refresh_id started"

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  read -r status percent < <(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$asg" --instance-refresh-ids "$refresh_id" \
    --query 'InstanceRefreshes[0].[Status,PercentageComplete]' --output text)
  echo "$(date -u +%H:%M:%S) $status ${percent}%"

  case "$status" in
    Successful)
      echo "Rollout complete: $asg is on launch template version $target."
      exit 0 ;;
    RollbackSuccessful)
      echo "::error::Rollout rolled back to launch template version $current. Revert the ami_id bump to bring main back in line with the fleet."
      exit 1 ;;
    Failed | Cancelled | RollbackFailed)
      aws autoscaling describe-instance-refreshes \
        --auto-scaling-group-name "$asg" --instance-refresh-ids "$refresh_id" \
        --query 'InstanceRefreshes[0].StatusReason' --output text
      echo "::error::Instance refresh ended in $status."
      exit 1 ;;
  esac
  sleep "$POLL_SECONDS"
done

echo "::error::Instance refresh $refresh_id still running after ${TIMEOUT_SECONDS}s."
exit 1
