#!/usr/bin/env bash
# Checks everything that can go wrong BEFORE you spend money on AWS.
# Run it from anywhere:  bash scripts/preflight.sh
# It reads the versions from the project files, so it cannot drift from them.

cd "$(dirname "$0")/.." || exit 1
FAIL=0
ok()   { printf '  OK       %s\n' "$1"; }
bad()  { printf '  PROBLEM  %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '           %s\n' "$1"; }
code() { curl -s -o /dev/null -L -w '%{http_code}' --max-time 15 "$1" 2>/dev/null; }

echo "1. Is the project on GitHub? (Jenkins builds from there, not from your laptop)"
REPO_URL=$(sed -n '/variable "github_repo_url"/,/}/p' terraform/variables.tf | sed -n 's/.*default *= *"\(.*\)".*/\1/p')
BRANCH=$(sed -n '/variable "github_branch"/,/}/p' terraform/variables.tf | sed -n 's/.*default *= *"\(.*\)".*/\1/p')
REGION=$(sed -n '/variable "region"/,/}/p' terraform/variables.tf | sed -n 's/.*default *= *"\(.*\)".*/\1/p')
# values set in terraform.tfvars win over the defaults
tfv() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" terraform/terraform.tfvars 2>/dev/null | head -n1; }
[ -n "$(tfv github_repo_url)" ] && REPO_URL=$(tfv github_repo_url)
[ -n "$(tfv github_branch)" ] && BRANCH=$(tfv github_branch)
[ -n "$(tfv region)" ] && REGION=$(tfv region)
TOKEN_PARAM=$(tfv github_token_parameter)
SLUG=$(echo "$REPO_URL" | sed -E 's#https://github.com/##; s#\.git$##')
note "repository: $SLUG, branch: $BRANCH"
FILES="Jenkinsfile docker/Dockerfile docker/nginx.conf app/index.html"
if [ -z "$TOKEN_PARAM" ]; then
  note "public repository mode (no github_token_parameter set)"
  for f in $FILES; do
    c=$(code "https://raw.githubusercontent.com/$SLUG/$BRANCH/$f")
    if [ "$c" = "200" ]; then ok "$f is on GitHub"
    else bad "$f is NOT reachable (HTTP $c). Push the project to $SLUG on branch $BRANCH. If the repository is private, make it public or set github_token_parameter (see the README)."; fi
  done
else
  note "private repository mode: the read-only token is read from SSM parameter $TOKEN_PARAM"
  TOKEN=$(aws ssm get-parameter --name "$TOKEN_PARAM" --with-decryption --query Parameter.Value --output text --region "$REGION" 2>/dev/null) || TOKEN=""
  if [ -z "$TOKEN" ]; then
    bad "SSM parameter $TOKEN_PARAM was not found in $REGION. Create it first, see 'Private repository' in the README."
  else
    for f in $FILES; do
      c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$SLUG/contents/$f?ref=$BRANCH" 2>/dev/null)
      case "$c" in
        200) ok "$f is readable with the token" ;;
        401) bad "GitHub rejects the token (HTTP 401): it is wrong or expired. Create a new one and update the SSM parameter."; break ;;
        404) bad "$f not found with this token (HTTP 404): the token cannot see $SLUG, or the file is not on branch $BRANCH." ;;
        *)   bad "$f could not be checked (HTTP $c)" ;;
      esac
    done
  fi
  unset TOKEN
fi

echo; echo "2. Tools on this computer"
if command -v terraform >/dev/null; then
  v=$(terraform version | head -n1 | sed -E 's/[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
  if [ "$(printf '%s\n1.11.0\n' "$v" | sort -V | head -n1)" = "1.11.0" ]; then ok "terraform $v"; else bad "terraform $v is too old, 1.11 or newer is needed"; fi
else bad "terraform is not installed"; fi
command -v aws >/dev/null && ok "aws cli: $(aws --version 2>&1 | cut -d' ' -f1)" || bad "aws cli is not installed"
command -v session-manager-plugin >/dev/null && ok "session-manager-plugin" || bad "session-manager-plugin is not installed (needed for the Jenkins tunnel)"
command -v python3 >/dev/null && ok "python3" || bad "python3 is not installed (used by helper scripts)"

echo; echo "3. AWS credentials"
if acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then ok "signed in to AWS account $acct"; else bad "aws cannot sign in. Run: aws configure"; fi

echo; echo "4. Versions pinned in the project exist on Docker Hub"
NGINX_V=$(sed -n 's/^ARG NGINX_VERSION=//p' docker/Dockerfile)
TRIVY_V=$(sed -n "s/.*TRIVY_IMAGE *= *'aquasec\/trivy:\(.*\)'.*/\1/p" Jenkinsfile)
NODE_T=$(sed -n "s/.*NODE_IMAGE *= *'node:\(.*\)'.*/\1/p" Jenkinsfile)
check_tag() {
  c=$(code "https://hub.docker.com/v2/repositories/$1/tags/$2")
  if [ "$c" = "200" ]; then ok "$1:$2"; elif [ "$c" = "404" ]; then bad "$1:$2 does not exist. Change it in the project and push."; else note "could not check $1:$2 (HTTP $c)"; fi
}
check_tag nginxinc/nginx-unprivileged "${NGINX_V}-alpine-slim"
check_tag aquasec/trivy "$TRIVY_V"
check_tag library/node "$NODE_T"
c=$(code "https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key")
if [ "$c" = "200" ]; then ok "Jenkins package signing key"; else bad "Jenkins package signing key not reachable (HTTP $c)"; fi

echo; echo "5. Newest Nginx base images (a pinned image goes stale, and the scan stage fails on known fixable vulnerabilities)"
curl -s --max-time 20 "https://hub.docker.com/v2/repositories/nginxinc/nginx-unprivileged/tags?name=alpine-slim&page_size=50&ordering=last_updated" 2>/dev/null | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
    rows = [(r["name"], r["last_updated"][:10]) for r in d.get("results", []) if re.fullmatch(r"\d+\.\d+\.\d+-alpine-slim", r["name"])]
    for n, t in rows[:5]:
        print("           %-24s published %s" % (n, t))
    if not rows: print("           (nothing found)")
except Exception:
    print("           (could not read the list)")
'
note "pinned now: ${NGINX_V}-alpine-slim  (edit ARG NGINX_VERSION in docker/Dockerfile to use a newer one)"

echo
if [ "$FAIL" -eq 0 ]; then echo "All checks passed."; else echo "$FAIL problem(s) found. Fix them before running terraform apply."; fi
exit "$FAIL"
