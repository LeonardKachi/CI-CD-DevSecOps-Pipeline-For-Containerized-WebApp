// Jenkinsfile: build, test, scan and deploy the 2048 container.
//
// Where it runs
//   On the Jenkins EC2 instance in a private subnet. There are no AWS keys
//   anywhere: the AWS CLI uses the instance role, which can only push to one
//   ECR repository and update one ECS service.
//
// Configuration
//   Set as global environment variables on the Jenkins controller (Terraform
//   does this), so nothing environment-specific lives in this file:
//   AWS_REGION, ECR_REPOSITORY, ECS_CLUSTER, ECS_SERVICE, ALB_NAME
//
// Tools needed on the Jenkins host
//   git, docker, aws cli v2, jq, curl
//
// Accepted risk
//   The jenkins user can run Docker, which is root-equivalent on this host.
//   That is why the host is isolated: private subnet, no inbound rules,
//   least-privilege role, no stored credentials.

pipeline {
    agent any

    options {
        skipDefaultCheckout(true)          // checkout is an explicit stage below
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()          // one deployment at a time
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    triggers {
        // Jenkins has no public address, so GitHub cannot call it.
        // Jenkins asks GitHub for new commits instead, about every 2 minutes.
        pollSCM('H/2 * * * *')
    }

    environment {
        LOCAL_IMAGE    = "2048-webapp:${BUILD_NUMBER}"
        // Tool versions are pinned so a pipeline run is repeatable.
        NODE_IMAGE     = 'node:22-alpine'
        JSHINT_VERSION = '2.13.6'
        TRIVY_IMAGE    = 'aquasec/trivy:0.65.0'
    }

    stages {

        // 1 ---------------------------------------------------------------
        stage('Checkout') {
            steps {
                script {
                    def scmVars = checkout scm
                    env.GIT_COMMIT = scmVars.GIT_COMMIT
                    env.GIT_BRANCH = scmVars.GIT_BRANCH
                }
                // Fail fast if the controller is missing any setting.
                sh '''#!/usr/bin/env bash
set -eu
for v in AWS_REGION ECR_REPOSITORY ECS_CLUSTER ECS_SERVICE ALB_NAME; do
  if [ -z "${!v:-}" ]; then
    echo "Missing Jenkins environment variable: $v"
    exit 1
  fi
done
'''
                script {
                    // The image tag is the commit, so every image maps to exactly
                    // one commit. ECR tags are immutable, so it can never change.
                    env.IMAGE_TAG  = env.GIT_COMMIT.take(12)
                    // Only the main branch may reach AWS. Other branches still
                    // get lint, build, test and scan.
                    env.IS_MAIN    = (env.GIT_BRANCH ==~ /(origin\/)?main/) ? 'true' : 'false'
                    env.ACCOUNT_ID = sh(returnStdout: true, script:
                        'aws sts get-caller-identity --query Account --output text --region "$AWS_REGION"').trim()
                    env.REGISTRY   = "${env.ACCOUNT_ID}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
                    env.IMAGE_URI  = "${env.REGISTRY}/${env.ECR_REPOSITORY}:${env.IMAGE_TAG}"
                    echo "Commit ${env.IMAGE_TAG} on ${env.GIT_BRANCH}, deploy allowed: ${env.IS_MAIN}"
                }
            }
        }

        // 2 ---------------------------------------------------------------
        stage('Lint') {
            steps {
                // Runs in a throwaway container: nothing is installed on the
                // Jenkins host, and the source is mounted read-only.
                sh '''#!/usr/bin/env bash
set -euo pipefail
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e npm_config_cache=/tmp/.npm \
  -v "$WORKSPACE/app:/src:ro" -w /src \
  "$NODE_IMAGE" \
  npx --yes "jshint@$JSHINT_VERSION" --config .jshintrc js
'''
            }
        }

        // 3 ---------------------------------------------------------------
        stage('Build image') {
            steps {
                sh '''#!/usr/bin/env bash
set -euo pipefail
docker build \
  --pull \
  --file docker/Dockerfile \
  --label "org.opencontainers.image.revision=${GIT_COMMIT}" \
  --label "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --tag "$LOCAL_IMAGE" \
  --tag "$IMAGE_URI" \
  .
'''
            }
        }

        // 4 ---------------------------------------------------------------
        stage('Test container') {
            steps {
                // The container starts with the same restrictions it gets in
                // production: read-only filesystem, no Linux capabilities.
                // If it cannot run like that, we find out here, not in ECS.
                sh '''#!/usr/bin/env bash
set -euo pipefail
NAME="test-2048-${BUILD_NUMBER}"
docker rm -f "$NAME" >/dev/null 2>&1 || true

docker run -d --name "$NAME" \
  --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  --publish 127.0.0.1::8080 \
  "$LOCAL_IMAGE" >/dev/null

PORT=$(docker port "$NAME" 8080/tcp | head -n1 | awk -F: '{print $NF}')
URL="http://127.0.0.1:${PORT}"

fail() {
  echo "TEST FAILED: $1"
  docker logs "$NAME" 2>&1 | tail -20
  exit 1
}

# Wait up to 60 seconds for the Dockerfile HEALTHCHECK to pass.
status="starting"
for _ in $(seq 1 30); do
  status=$(docker inspect --format '{{.State.Health.Status}}' "$NAME")
  [ "$status" = "healthy" ] && break
  sleep 2
done
[ "$status" = "healthy" ] || fail "container did not become healthy (status: $status)"

# --- checks
code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/health" || true)
[ "$code" = "200" ] || fail "/health returned $code"

# Output is captured first and searched with a here-string: piping curl into
# "grep -q" under pipefail can fail by accident when grep exits early.
body=$(curl -s "$URL/" || true)
grep -q '<title>2048</title>' <<< "$body" || fail "home page does not contain the game"

headers=$(curl -s -D - -o /dev/null "$URL/" || true)
for h in x-content-type-options x-frame-options referrer-policy content-security-policy; do
  grep -qi "^$h:" <<< "$headers" || fail "missing security header: $h"
done
server=$(grep -i '^server:' <<< "$headers" || true)
if [[ "$server" =~ [0-9] ]]; then
  fail "Server header leaks a version number"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/" || true)
[ "$code" = "405" ] || fail "POST returned $code, expected 405"

code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/.git/config" || true)
[ "$code" = "404" ] || fail "hidden file request returned $code, expected 404"

uid=$(docker exec "$NAME" id -u)
[ "$uid" = "101" ] || fail "container runs as uid $uid, expected 101 (non-root)"

echo "All container tests passed"
'''
            }
        }

        // 5 ---------------------------------------------------------------
        stage('Security scan') {
            steps {
                // The image is saved to a file and scanned from there, so the
                // scanner never needs access to the Docker socket.
                // Only HIGH and CRITICAL findings with an available fix fail the
                // build: a gate that fails on things nobody can fix gets turned off.
                sh '''#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.cache/trivy"
docker save "$IMAGE_URI" -o "$WORKSPACE/image.tar"

run_trivy() {
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e TRIVY_CACHE_DIR=/tmp/trivy-cache \
    -v "$HOME/.cache/trivy:/tmp/trivy-cache" \
    -v "$WORKSPACE:/work" \
    "$TRIVY_IMAGE" image \
    --input /work/image.tar \
    --scanners vuln,secret \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    "$@"
}

# Full report, kept as a build artifact. Never fails the build.
run_trivy --format json --output /work/trivy-report.json --exit-code 0

# The gate. Prints a readable table and fails on any finding.
run_trivy --format table --exit-code 1
'''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-report.json', allowEmptyArchive: true
                }
            }
        }

        // 6 ---------------------------------------------------------------
        stage('Push to ECR') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                sh '''#!/usr/bin/env bash
set -euo pipefail

# Registry credentials live in a temporary folder that is deleted afterwards.
export DOCKER_CONFIG="$(mktemp -d)"
trap 'rm -rf "$DOCKER_CONFIG"' EXIT

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# ECR tags are immutable, so pushing the same commit twice would fail.
# If this commit was already pushed (for example a re-run), reuse the image.
set +e
out=$(aws ecr describe-images --region "$AWS_REGION" \
  --repository-name "$ECR_REPOSITORY" \
  --image-ids imageTag="$IMAGE_TAG" 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  echo "Image tag $IMAGE_TAG already exists in ECR. Skipping push."
elif echo "$out" | grep -q 'ImageNotFoundException'; then
  docker push "$IMAGE_URI"
else
  echo "$out"
  exit 1
fi
'''
            }
        }

        // 7 ---------------------------------------------------------------
        stage('Deploy to ECS') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                script {
                    // Remember what is running now, so we can go back to it.
                    env.PREVIOUS_TASK_DEF = sh(returnStdout: true, script: '''aws ecs describe-services \
  --region "$AWS_REGION" --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].taskDefinition' --output text''').trim()

                    // New task definition revision: the newest revision of the task
                    // family with only the image replaced. Starting from the newest
                    // revision (not the one the service runs) means a settings change
                    // made in Terraform, such as memory, reaches production with the
                    // next deployment. Everything else (roles, read-only filesystem,
                    // log settings) is inherited from what Terraform defined.
                    // Every container in the task uses the same image, including the
                    // small helper that prepares the scratch folder.
                    env.NEW_TASK_DEF = sh(returnStdout: true, script: '''#!/usr/bin/env bash
set -euo pipefail
FAMILY="${PREVIOUS_TASK_DEF##*/}"
FAMILY="${FAMILY%:*}"
aws ecs describe-task-definition --region "$AWS_REGION" \
  --task-definition "$FAMILY" --query taskDefinition \
  | jq --arg IMAGE "$IMAGE_URI" '
      .containerDefinitions |= map(.image = $IMAGE)
      | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
            .compatibilities, .registeredAt, .registeredBy)' > taskdef.json
aws ecs register-task-definition --region "$AWS_REGION" \
  --cli-input-json file://taskdef.json \
  --query taskDefinition.taskDefinitionArn --output text
''').trim()
                }
                sh '''#!/usr/bin/env bash
set -euo pipefail
echo "Deploying $NEW_TASK_DEF (previous: $PREVIOUS_TASK_DEF)"
aws ecs update-service --region "$AWS_REGION" \
  --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --task-definition "$NEW_TASK_DEF" >/dev/null

# Waits until the rollout finishes. ECS replaces tasks gradually and its
# deployment circuit breaker rolls back by itself if new tasks keep failing.
aws ecs wait services-stable --region "$AWS_REGION" \
  --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"

# "Stable" is also what a rolled-back service looks like, so confirm the
# service really runs the new version.
CURRENT=$(aws ecs describe-services --region "$AWS_REGION" \
  --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].taskDefinition' --output text)
if [ "$CURRENT" != "$NEW_TASK_DEF" ]; then
  echo "ECS rolled the deployment back to $CURRENT"
  exit 1
fi
'''
            }
        }

        // 8 ---------------------------------------------------------------
        stage('Smoke test') {
            when { expression { env.IS_MAIN == 'true' } }
            steps {
                // The last check goes through the same public entry point real
                // users use. If it fails, the post section rolls back.
                sh '''#!/usr/bin/env bash
set -euo pipefail
DNS=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text)
URL="http://$DNS"

code="000"
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL/health" || true)
  [ "$code" = "200" ] && break
  sleep 5
done
[ "$code" = "200" ] || { echo "Smoke test failed: /health returned $code"; exit 1; }

body=$(curl -fsS --max-time 10 "$URL/" || true)
grep -q '<title>2048</title>' <<< "$body" \
  || { echo "Smoke test failed: home page is not the game"; exit 1; }

headers=$(curl -sI --max-time 10 "$URL/" || true)
grep -qi '^content-security-policy:' <<< "$headers" \
  || { echo "Smoke test failed: security headers missing"; exit 1; }

echo "Smoke test passed: $URL"
'''
            }
        }
    }

    post {
        failure {
            script {
                // Roll back only if a new version was registered AND is the one
                // the service is currently running. If ECS already rolled back
                // by itself, there is nothing to do.
                if (env.NEW_TASK_DEF && env.PREVIOUS_TASK_DEF) {
                    sh '''#!/usr/bin/env bash
set -euo pipefail
CURRENT=$(aws ecs describe-services --region "$AWS_REGION" \
  --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].taskDefinition' --output text)
if [ "$CURRENT" = "$NEW_TASK_DEF" ]; then
  echo "Rolling back to $PREVIOUS_TASK_DEF"
  aws ecs update-service --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
    --task-definition "$PREVIOUS_TASK_DEF" >/dev/null
  aws ecs wait services-stable --region "$AWS_REGION" \
    --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"
else
  echo "Service already runs $CURRENT. No rollback needed."
fi
'''
                }
            }
        }
        always {
            // Keep the Jenkins disk from filling up with old containers and images.
            sh '''#!/usr/bin/env bash
docker rm -f "test-2048-${BUILD_NUMBER}" >/dev/null 2>&1 || true
docker rmi "$LOCAL_IMAGE" "${IMAGE_URI:-none}" >/dev/null 2>&1 || true
docker image prune -f --filter "until=168h" >/dev/null 2>&1 || true
true
'''
        }
        cleanup {
            // Runs last, after everything above, so rollback can still use the workspace.
            deleteDir()
        }
    }
}
