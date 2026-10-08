#!/usr/bin/env sh
set -eu
umask 077

CALLER_DIR="$(pwd)"
CHART_DIR="${CRAIG_CHART_DIR:?Set CRAIG_CHART_DIR to the separate local chart}"
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
CRAIG_PULL_SOURCE="${CRAIG_PULL_SOURCE:-1}"
CRAIG_REPO_URL="${CRAIG_REPO_URL:-$(git config --get remote.origin.url 2>/dev/null || true)}"
CRAIG_REPO_REF="${CRAIG_REPO_REF:-${CURRENT_BRANCH:-main}}"
CRAIG_SOURCE_DIR="${CRAIG_SOURCE_DIR:-/tmp/craig-eks-deploy-src}"
CRAIG_OVERLAY_DEPLOY_FILES="${CRAIG_OVERLAY_DEPLOY_FILES:-1}"
CRAIG_OVERLAY_DIR="${CRAIG_OVERLAY_DIR:-$CALLER_DIR}"

NAMESPACE="${CRAIG_NAMESPACE:?Set CRAIG_NAMESPACE first}"
RELEASE="${CRAIG_HELM_RELEASE:-craig}"
VALUES_FILE="${CRAIG_VALUES_FILE:-${CHART_DIR}/values-eks-gitlab.yaml}"
EXTRA_VALUES_FILE="${CRAIG_EXTRA_VALUES_FILE:-}"
case "$EXTRA_VALUES_FILE" in ""|/*) ;; *) EXTRA_VALUES_FILE="$CALLER_DIR/$EXTRA_VALUES_FILE" ;; esac
REGISTRY="${GITLAB_REGISTRY:-registry.gitlab.com}"
SECRET_NAME="craig-secrets"
CREATE_NAMESPACE="${CRAIG_CREATE_NAMESPACE:-0}"
ACTOR_KEYS_ENV_FILE="${CRAIG_ACTOR_KEYS_ENV_FILE:-devstack/devstack-actor-keys.env}"
CRAIG_APP_HOST="${CRAIG_APP_HOST:-${CRAIG_HOST:-}}"
CRAIG_KEYCLOAK_HOST="${CRAIG_KEYCLOAK_HOST:-${CRAIG_APP_HOST}}"
CRAIG_INTAKE_HOST="${CRAIG_INTAKE_HOST:-}"
CRAIG_CASES_INTERNAL_HOST="${CRAIG_CASES_INTERNAL_HOST:-}"
CRAIG_EXTERNAL_SCHEME="${CRAIG_EXTERNAL_SCHEME:-https}"
CRAIG_INGRESS_CLASS="${CRAIG_INGRESS_CLASS:-}"
CRAIG_INTERNAL_INGRESS_CLASS="${CRAIG_INTERNAL_INGRESS_CLASS:-${CRAIG_INGRESS_CLASS}}"
CRAIG_TLS_ENABLED="${CRAIG_TLS_ENABLED:-}"
CRAIG_SEED_ENABLED="${CRAIG_SEED_ENABLED:-}"
CRAIG_TGB_ENABLED="${CRAIG_TGB_ENABLED:-}"
CRAIG_PUBLIC_TGB_ENABLED="${CRAIG_PUBLIC_TGB_ENABLED:-}"
CRAIG_PUBLIC_TGB_NAMESPACE="${CRAIG_PUBLIC_TGB_NAMESPACE:-}"
CRAIG_PUBLIC_TGB_NAME="${CRAIG_PUBLIC_TGB_NAME:-}"
CRAIG_PUBLIC_TGB_SERVICE_NAME="${CRAIG_PUBLIC_TGB_SERVICE_NAME:-}"
CRAIG_PUBLIC_TGB_SERVICE_PORT="${CRAIG_PUBLIC_TGB_SERVICE_PORT:-}"
CRAIG_PUBLIC_TGB_ARN="${CRAIG_PUBLIC_TGB_ARN:-}"
export CRAIG_APP_HOST CRAIG_HOST CRAIG_KEYCLOAK_HOST CRAIG_INTAKE_HOST
export CRAIG_CASES_INTERNAL_HOST CRAIG_EXTERNAL_SCHEME CRAIG_INGRESS_CLASS
export CRAIG_INTERNAL_INGRESS_CLASS CRAIG_TLS_ENABLED CRAIG_SEED_ENABLED
export CRAIG_TGB_ENABLED CRAIG_PUBLIC_TGB_ENABLED CRAIG_PUBLIC_TGB_NAMESPACE
export CRAIG_PUBLIC_TGB_NAME CRAIG_PUBLIC_TGB_SERVICE_NAME
export CRAIG_PUBLIC_TGB_SERVICE_PORT CRAIG_PUBLIC_TGB_ARN

for tool in git kubectl helm openssl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool not found on PATH" >&2
    exit 1
  }
done

if [ "$CRAIG_PULL_SOURCE" = "1" ]; then
  [ -n "$CRAIG_REPO_URL" ] || {
    echo "ERROR: CRAIG_REPO_URL is empty and no git remote.origin.url was found" >&2
    exit 1
  }

  if [ -d "${CRAIG_SOURCE_DIR}/.git" ]; then
    echo "==> Updating source in ${CRAIG_SOURCE_DIR}..."
    git -C "$CRAIG_SOURCE_DIR" fetch origin --tags
  else
    echo "==> Cloning ${CRAIG_REPO_URL} into ${CRAIG_SOURCE_DIR}..."
    git clone "$CRAIG_REPO_URL" "$CRAIG_SOURCE_DIR"
    git -C "$CRAIG_SOURCE_DIR" fetch origin --tags
  fi

  cd "$CRAIG_SOURCE_DIR"
  git fetch origin "$CRAIG_REPO_REF"
  if git rev-parse --verify "origin/${CRAIG_REPO_REF}" >/dev/null 2>&1; then
    git checkout -B "$CRAIG_REPO_REF" "origin/${CRAIG_REPO_REF}"
  else
    git checkout "$CRAIG_REPO_REF"
  fi
  git submodule update --init --recursive

  if [ "$CRAIG_OVERLAY_DEPLOY_FILES" = "1" ] && [ -d "${CRAIG_OVERLAY_DIR}/deploy/kubernetes/craig" ]; then
    echo "==> Overlaying deployment files from ${CRAIG_OVERLAY_DIR}..."
    mkdir -p deploy/kubernetes
    rm -rf deploy/kubernetes/craig
    cp -R "${CRAIG_OVERLAY_DIR}/deploy/kubernetes/craig" deploy/kubernetes/craig
  fi
else
  echo "==> Using current checkout without pulling source..."
fi

GENERATED_VALUES_FILE="$(mktemp)"
chmod 600 "$GENERATED_VALUES_FILE"
ENV_VALUES_FILE="$(mktemp)"
chmod 600 "$ENV_VALUES_FILE"
write_env_values() {
  output="$1"
  python3 - "$output" <<'PY'
import os
import sys

out = sys.argv[1]
lines = []

def env(name):
    return os.environ.get(name, "")

def yaml_bool(value):
    return "true" if value.lower() in {"1", "true", "yes", "on"} else "false"

app_host = env("CRAIG_APP_HOST") or env("CRAIG_HOST")
keycloak_host = env("CRAIG_KEYCLOAK_HOST") or app_host
intake_host = env("CRAIG_INTAKE_HOST")
cases_host = env("CRAIG_CASES_INTERNAL_HOST")
scheme = env("CRAIG_EXTERNAL_SCHEME")
ingress_class = env("CRAIG_INGRESS_CLASS")
internal_ingress_class = env("CRAIG_INTERNAL_INGRESS_CLASS") or ingress_class
tls_enabled = env("CRAIG_TLS_ENABLED")

if any([app_host, keycloak_host, intake_host, cases_host, scheme, ingress_class, internal_ingress_class, tls_enabled]):
    lines.append("global:")
    if scheme:
        lines.append(f"  externalScheme: {scheme}")
    if any([app_host, keycloak_host, intake_host, cases_host]):
        lines.append("  hosts:")
        if keycloak_host:
            lines.append(f"    keycloak: {keycloak_host}")
        if app_host:
            lines.append(f"    app: {app_host}")
        if cases_host:
            lines.append(f"    casesInternal: {cases_host}")
        if intake_host:
            lines.append(f"    intake: {intake_host}")
    if any([ingress_class, internal_ingress_class, tls_enabled]):
        lines.append("  ingress:")
        if ingress_class:
            lines.append(f"    externalClassName: {ingress_class}")
        if internal_ingress_class:
            lines.append(f"    internalClassName: {internal_ingress_class}")
        if tls_enabled:
            lines.append("    tls:")
            lines.append(f"      enabled: {yaml_bool(tls_enabled)}")

if env("CRAIG_SEED_ENABLED"):
    lines.append("seed:")
    lines.append(f"  enabled: {yaml_bool(env('CRAIG_SEED_ENABLED'))}")

if any(env(name) for name in [
    "CRAIG_TGB_ENABLED",
    "CRAIG_PUBLIC_TGB_ENABLED",
    "CRAIG_PUBLIC_TGB_NAMESPACE",
    "CRAIG_PUBLIC_TGB_NAME",
    "CRAIG_PUBLIC_TGB_SERVICE_NAME",
    "CRAIG_PUBLIC_TGB_SERVICE_PORT",
    "CRAIG_PUBLIC_TGB_ARN",
]):
    lines.append("targetGroupBindings:")
    if env("CRAIG_TGB_ENABLED"):
        lines.append(f"  enabled: {yaml_bool(env('CRAIG_TGB_ENABLED'))}")
    lines.append("  publicNginx:")
    if env("CRAIG_PUBLIC_TGB_ENABLED"):
        lines.append(f"    enabled: {yaml_bool(env('CRAIG_PUBLIC_TGB_ENABLED'))}")
    if env("CRAIG_PUBLIC_TGB_NAMESPACE"):
        lines.append(f"    namespace: {env('CRAIG_PUBLIC_TGB_NAMESPACE')}")
    if env("CRAIG_PUBLIC_TGB_NAME"):
        lines.append(f"    name: {env('CRAIG_PUBLIC_TGB_NAME')}")
    if env("CRAIG_PUBLIC_TGB_SERVICE_NAME"):
        lines.append(f"    serviceName: {env('CRAIG_PUBLIC_TGB_SERVICE_NAME')}")
    if env("CRAIG_PUBLIC_TGB_SERVICE_PORT"):
        lines.append(f"    servicePort: {env('CRAIG_PUBLIC_TGB_SERVICE_PORT')}")
    if env("CRAIG_PUBLIC_TGB_ARN"):
        lines.append(f"    targetGroupARN: {env('CRAIG_PUBLIC_TGB_ARN')}")

with open(out, "w", encoding="utf-8") as fh:
    if lines:
        fh.write("\n".join(lines))
        fh.write("\n")
PY
}
write_env_values "$ENV_VALUES_FILE"
trap 'rm -f "$GENERATED_VALUES_FILE" "$ENV_VALUES_FILE"' EXIT

kubectl get namespace "$NAMESPACE" >/dev/null

if [ -n "${GITLAB_USERNAME:-}" ] && [ -n "${GITLAB_TOKEN:-}" ]; then
  kubectl create secret docker-registry gitlab-registry \
    --namespace "$NAMESPACE" \
    --docker-server="$REGISTRY" \
    --docker-username="$GITLAB_USERNAME" \
    --docker-password="$GITLAB_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

existing_secret_value() {
  kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" \
    -o jsonpath="{.data.$1}" 2>/dev/null | { base64 -d 2>/dev/null || true; }
}

random_b64_32() { openssl rand -base64 32; }
random_b64_96() { openssl rand -base64 96 | tr -d '\n'; }

POSTGRES_PASSWORD="$(existing_secret_value POSTGRES_PASSWORD)"
[ -n "$POSTGRES_PASSWORD" ] || POSTGRES_PASSWORD="$(random_b64_32)"

RABBITMQ_PASSWORD="$(existing_secret_value RABBITMQ_PASSWORD)"
[ -n "$RABBITMQ_PASSWORD" ] || RABBITMQ_PASSWORD="$(random_b64_32)"

WEB_SESSION_SECRET="$(existing_secret_value CRAIG_WEB__SESSION_SECRET)"
[ -n "$WEB_SESSION_SECRET" ] || WEB_SESSION_SECRET="$(random_b64_96)"

FIELD_ENCRYPTION_KEY="$(existing_secret_value CRAIG_FIELD_ENCRYPTION_KEY)"
[ -n "$FIELD_ENCRYPTION_KEY" ] || FIELD_ENCRYPTION_KEY="$(random_b64_32)"

REPORTING_FIELD_ENCRYPTION_KEY="$(existing_secret_value CRAIG_REPORTING_FIELD_ENCRYPTION_KEY)"
[ -n "$REPORTING_FIELD_ENCRYPTION_KEY" ] || REPORTING_FIELD_ENCRYPTION_KEY="$(random_b64_32)"

INTAKE_CLIENT_SECRET="${CRAIG_INTAKE_CLIENT_SECRET:-}"
if [ -z "$INTAKE_CLIENT_SECRET" ]; then
  INTAKE_CLIENT_SECRET="$(existing_secret_value CRAIG_INTAKE__CLIENT_SECRET)"
fi
[ -n "$INTAKE_CLIENT_SECRET" ] || INTAKE_CLIENT_SECRET="$(random_b64_32)"

INTAKE_IP_HASH_SECRET="$(existing_secret_value CRAIG_INTAKE__IP_HASH_SECRET)"
[ -n "$INTAKE_IP_HASH_SECRET" ] || INTAKE_IP_HASH_SECRET="$(random_b64_32)"

BACKEND_SERVICE_CLIENT_SECRET="${CRAIG_BACKEND_SERVICE_CLIENT_SECRET:-}"
if [ -z "$BACKEND_SERVICE_CLIENT_SECRET" ]; then
  BACKEND_SERVICE_CLIENT_SECRET="$(existing_secret_value CRAIG_BACKEND_SERVICE_CLIENT_SECRET)"
fi
[ -n "$BACKEND_SERVICE_CLIENT_SECRET" ] || BACKEND_SERVICE_CLIENT_SECRET="$(random_b64_32)"

KEYCLOAK_ADMIN_PASSWORD="$(existing_secret_value KEYCLOAK_ADMIN_PASSWORD)"
[ -n "$KEYCLOAK_ADMIN_PASSWORD" ] || KEYCLOAK_ADMIN_PASSWORD="$(random_b64_32)"

ACTOR_KEYS_VALUES_FILE="$(mktemp)"
chmod 600 "$ACTOR_KEYS_VALUES_FILE"
trap 'rm -f "$GENERATED_VALUES_FILE" "$ENV_VALUES_FILE" "$ACTOR_KEYS_VALUES_FILE"' EXIT

[ -f "$ACTOR_KEYS_ENV_FILE" ] || {
  echo "ERROR: actor keys env file not found: ${ACTOR_KEYS_ENV_FILE}" >&2
  echo "Copy it at devstack/devstack-actor-keys.env, or set CRAIG_ACTOR_KEYS_ENV_FILE." >&2
  exit 1
}

python3 - "$ACTOR_KEYS_ENV_FILE" > "$ACTOR_KEYS_VALUES_FILE" <<'PY'
import sys

print("actorKeys:")
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.startswith("CRAIG_") and ("SIGNING_" in key or key == "CRAIG_PEER_JWKS_JSON"):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        print(f'  {key}: "{escaped}"')
PY

grep -q '^  CRAIG_PEER_JWKS_JSON:' "$ACTOR_KEYS_VALUES_FILE" || {
  echo "ERROR: ${ACTOR_KEYS_ENV_FILE} did not contain CRAIG_PEER_JWKS_JSON" >&2
  exit 1
}

cat > "$GENERATED_VALUES_FILE" <<EOF
secrets:
  postgresPassword: "${POSTGRES_PASSWORD}"
  rabbitmqPassword: "${RABBITMQ_PASSWORD}"
  webSessionSecret: "${WEB_SESSION_SECRET}"
  fieldEncryptionKey: "${FIELD_ENCRYPTION_KEY}"
  reportingFieldEncryptionKey: "${REPORTING_FIELD_ENCRYPTION_KEY}"
  intakeClientSecret: "${INTAKE_CLIENT_SECRET}"
  intakeIpHashSecret: "${INTAKE_IP_HASH_SECRET}"
  backendServiceClientSecret: "${BACKEND_SERVICE_CLIENT_SECRET}"
keycloak:
  adminPassword: "${KEYCLOAK_ADMIN_PASSWORD}"
EOF

if [ -n "$EXTRA_VALUES_FILE" ]; then
  helm upgrade --install "$RELEASE" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --values "$VALUES_FILE" \
    --values "$GENERATED_VALUES_FILE" \
    --values "$ACTOR_KEYS_VALUES_FILE" \
    --values "$ENV_VALUES_FILE" \
    --values "$EXTRA_VALUES_FILE" \
    "$@"
else
  helm upgrade --install "$RELEASE" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --values "$VALUES_FILE" \
    --values "$GENERATED_VALUES_FILE" \
    --values "$ACTOR_KEYS_VALUES_FILE" \
    --values "$ENV_VALUES_FILE" \
    "$@"
fi

kubectl rollout status deployment/craig-web -n "$NAMESPACE"

echo "Secrets are stored in Secret/${SECRET_NAME} (namespace ${NAMESPACE}) and will be reused (not rotated) on future runs of this script."
echo "View them with: kubectl get secret ${SECRET_NAME} -n ${NAMESPACE} -o yaml"
