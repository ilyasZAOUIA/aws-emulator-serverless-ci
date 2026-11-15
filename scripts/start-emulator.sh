#!/usr/bin/env bash
# Install (if needed) and start AWS Emulator, wait until healthy, then export
# the variables that point the AWS CLI, SDKs and Terraform at it.
# Works on Ubuntu/Debian: GitHub Actions runners and GitHub Codespaces.
set -euo pipefail

PORT="${EMULATOR_PORT:-9297}"
# Only the latest LTS build is published at a stable URL, so the version
# cannot be pinned at download time. It is checked after install instead.
DEB_URL="https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_amd64.deb"
TESTED_VERSION="1.0.385" # last version this project was tested against
EMU_DIR="$HOME/.aws/emulator/$PORT"
LOG_FILE="${EMULATOR_LOG:-/tmp/aws-emulator.log}"
ENV_FILE="${ENV_FILE:-.emulator.env}"

if ! command -v aws-emulator >/dev/null 2>&1; then
  echo "==> Installing AWS Emulator"
  curl -fsSLo /tmp/aws-emulator.deb "$DEB_URL"
  sudo apt-get install -y -qq /tmp/aws-emulator.deb >/dev/null
fi

VERSION="$(aws-emulator -v | sed -n 's/^Version: *//p')"
if [ -z "$VERSION" ]; then
  echo "Could not read the AWS Emulator version from 'aws-emulator -v'" >&2
  exit 1
fi
echo "==> AWS Emulator $VERSION"
if [ "$VERSION" != "$TESTED_VERSION" ]; then
  msg="AWS Emulator $VERSION differs from the tested version $TESTED_VERSION"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::warning title=AWS Emulator version::$msg"
  else
    echo "WARNING: $msg" >&2
  fi
fi

echo "==> Starting AWS Emulator on port $PORT (log: $LOG_FILE)"
# --idle-timeout: stop by itself if a CI job dies halfway.
nohup aws-emulator -p "$PORT" --telemetry off --idle-timeout 1800 >"$LOG_FILE" 2>&1 &

for _ in $(seq 60); do
  if [ -f "$EMU_DIR/ca.pem" ] &&
    curl -sf --cacert "$EMU_DIR/ca.pem" "https://127.0.0.1:$PORT/__admin/health" >/dev/null; then
    echo "==> Emulator is healthy"
    break
  fi
  sleep 1
done
curl -sf --cacert "$EMU_DIR/ca.pem" "https://127.0.0.1:$PORT/__admin/health" >/dev/null || {
  echo "Emulator did not become healthy in 60s" >&2
  cat "$LOG_FILE" >&2
  exit 1
}

# Credentials and CA are regenerated on every start, so export them now.
cat >"$ENV_FILE" <<EOF
AWS_ENDPOINT_URL=https://127.0.0.1:$PORT
AWS_SHARED_CREDENTIALS_FILE=$EMU_DIR/emulator_credentials
AWS_CONFIG_FILE=$EMU_DIR/config
AWS_CA_BUNDLE=$EMU_DIR/ca.pem
NODE_EXTRA_CA_CERTS=$EMU_DIR/ca.pem
AWS_EC2_METADATA_DISABLED=true
AWS_DISABLE_HOST_PREFIX_INJECTION=true
AWS_REGION=us-east-1
AWS_DEFAULT_REGION=us-east-1
TF_VAR_emulator_dir=$EMU_DIR
EOF

if [ -n "${GITHUB_ENV:-}" ]; then
  cat "$ENV_FILE" >>"$GITHUB_ENV"
fi
echo "==> Environment written to $ENV_FILE"
