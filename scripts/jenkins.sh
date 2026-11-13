#!/usr/bin/env bash
# Helper for reaching and inspecting the Jenkins server, which has no public address.
#
#   bash scripts/jenkins.sh tunnel     open Jenkins at http://localhost:8080 (leave it running)
#   bash scripts/jenkins.sh password   print the admin password
#   bash scripts/jenkins.sh doctor     print what Jenkins is doing, and why a build did or did not run
#   bash scripts/jenkins.sh shell      open a shell on the server
#
# Run it on your own computer, in the project folder. NOT inside the server shell.

set -euo pipefail
cd "$(dirname "$0")/../terraform"

tf() { terraform output -raw "$1"; }
ID=$(tf jenkins_instance_id)
REGION=$(tf region)

case "${1:-help}" in
  tunnel)
    echo "Opening Jenkins. Browse to http://localhost:8080 and log in as admin. Press Ctrl+C to close."
    aws ssm start-session --target "$ID" --region "$REGION" \
      --document-name AWS-StartPortForwardingSession \
      --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
    ;;
  password)
    aws ssm get-parameter --name "$(tf jenkins_admin_password_parameter)" --with-decryption \
      --query Parameter.Value --output text --region "$REGION"
    ;;
  shell)
    aws ssm start-session --target "$ID" --region "$REGION"
    ;;
  doctor)
    SCRIPT=$(cat <<'REMOTE'
echo "=== boot script: last 30 lines of /var/log/jenkins-bootstrap.log"
tail -n 30 /var/log/jenkins-bootstrap.log 2>&1
echo
echo "=== jenkins service: $(systemctl is-active jenkins 2>&1), enabled: $(systemctl is-enabled jenkins 2>&1)"
echo "=== plugins installed: $(ls /var/lib/jenkins/plugins 2>/dev/null | wc -l)"
echo "=== jobs: $(ls /var/lib/jenkins/jobs 2>/dev/null | tr '\n' ' ')"
echo
echo "=== polling log (does Jenkins see the repository and the Jenkinsfile?)"
tail -n 25 /var/lib/jenkins/jobs/*/scm-polling.log 2>&1
echo
echo "=== newest build console, last 70 lines"
LOG=$(ls -t /var/lib/jenkins/jobs/*/builds/*/log 2>/dev/null | head -n 1)
if [ -n "$LOG" ]; then echo "$LOG"; tail -n 70 "$LOG"; else echo "no build has run yet"; fi
echo
echo "=== jenkins journal, last 25 lines"
journalctl -u jenkins -n 25 --no-pager 2>&1
REMOTE
)
    PARAMS=$(python3 -c 'import json, sys; print(json.dumps({"commands": [sys.stdin.read()]}))' <<<"$SCRIPT")
    CMD_ID=$(aws ssm send-command --instance-ids "$ID" --document-name AWS-RunShellScript \
      --parameters "$PARAMS" --query Command.CommandId --output text --region "$REGION")
    echo "Running diagnostics on the Jenkins server (command $CMD_ID)..."
    STATUS="Pending"
    for _ in $(seq 1 30); do
      STATUS=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$ID" \
        --query Status --output text --region "$REGION" 2>/dev/null || echo "Pending")
      case "$STATUS" in Success|Failed|Cancelled|TimedOut) break ;; esac
      sleep 2
    done
    echo "Status: $STATUS"; echo
    aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$ID" \
      --query StandardOutputContent --output text --region "$REGION"
    ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
