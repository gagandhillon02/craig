#!/usr/bin/env sh
set -eu
umask 077

CALLER_DIR="$(pwd)"
CHART_DIR="${CRAIG_CHART_DIR:?Set CRAIG_CHART_DIR to the separate local chart}"
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
CRAIG_PULL_SOURCE="${CRAIG_PULL_SOURCE:-1}"
CRAIG_REPO_URL="${CRAIG_REPO_URL:-$(git config --get remote.origin.url 2>/dev/null || true)}"
CRAIG_REPO_REF="${CRAIG_REPO_REF:-${CURRENT_BRANCH:-main}}"
CRAIG_SOURCE_DIR="${CRAIG_SOURCE_DIR:-/tmp/craig-ecr-build-src}"
CRAIG_OVERLAY_DEPLOY_FILES="${CRAIG_OVERLAY_DEPLOY_FILES:-1}"
CRAIG_OVERLAY_DIR="${CRAIG_OVERLAY_DIR:-$CALLER_DIR}"

AWS_REGION="${AWS_REGION:?Set AWS_REGION first}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID first}"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_PREFIX="${ECR_PREFIX:-craig}"
VALUES_FILE="${CRAIG_VALUES_FILE:-${CHART_DIR}/values-eks-gitlab.yaml}"
OUTPUT_VALUES_FILE="${CRAIG_ECR_VALUES_FILE:-deploy/kubernetes/craig/values-ecr.generated.yaml}"
KEYCLOAK_REALM_SOURCE="${CRAIG_KEYCLOAK_REALM_SOURCE:-devstack/keycloak/craig-realm.json}"
CARGO_PROFILE="${CARGO_PROFILE:-devstack}"
CRAIG_WEB_FEATURES="${CRAIG_WEB_FEATURES-plugin-example,plugin-ssa-screening}"
CRAIG_INTAKE_FEATURES="${CRAIG_INTAKE_FEATURES:-}"
CRAIG_CASES_FEATURES="${CRAIG_CASES_FEATURES:-}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
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

for tool in aws docker git helm openssl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool not found on PATH" >&2
    exit 1
  }
done

case "$OUTPUT_VALUES_FILE" in
/*) ;;
*) OUTPUT_VALUES_FILE="${CALLER_DIR}/${OUTPUT_VALUES_FILE}" ;;
esac

ENV_VALUES_FILE="$(mktemp)"
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

SOURCE_REV="$(git rev-parse --short HEAD)"
IMAGE_TAG="${IMAGE_TAG:-${SOURCE_REV}-$(date -u +%Y%m%d%H%M%S)}"

docker info >/dev/null 2>&1 || {
  echo "ERROR: docker daemon not reachable" >&2
  exit 1
}
docker buildx version >/dev/null 2>&1 || {
  echo "ERROR: docker buildx plugin not available" >&2
  exit 1
}

aws sts get-caller-identity >/dev/null

ecr_repo() {
  printf '%s/%s' "$ECR_PREFIX" "$1"
}

ecr_image() {
  printf '%s/%s:%s' "$ECR_REGISTRY" "$(ecr_repo "$1")" "$2"
}

ensure_repo() {
  ecr_repository="$(ecr_repo "$1")"
  if aws ecr describe-repositories \
    --region "$AWS_REGION" \
    --repository-names "$ecr_repository" >/dev/null 2>&1; then
    return 0
  fi

  echo "ERROR: required existing ECR repository unavailable: $ecr_repository" >&2
  exit 1
}

build_and_push_context() {
  image_name="$1"
  dockerfile="$2"
  context="$3"
  ensure_repo "$image_name"
  image_tagged="$(ecr_image "$image_name" "$IMAGE_TAG")"
  image_latest="$(ecr_image "$image_name" latest)"
  echo "==> ${image_name}: ${image_tagged}"
  docker buildx build \
    --platform "$DOCKER_PLATFORM" \
    -f "$dockerfile" \
    -t "$image_tagged" \
    -t "$image_latest" \
    --push \
    "$context"
}

echo "==> Logging in to ECR ${ECR_REGISTRY}..."
aws ecr get-login-password --region "$AWS_REGION" |
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

APP_TARGETS="
craig-rules
craig-cases
craig-placement
craig-exchange
craig-financial
craig-reporting
craig-security
craig-intake
craig-composition
craig-web
craig-mock-server
craig-seed
"

echo "==> Building and pushing baked Keycloak image..."
ensure_repo "craig-keycloak-baked"

generated_value() {
  key="$1"
  [ -f "$OUTPUT_VALUES_FILE" ] || return 0
  python3 - "$OUTPUT_VALUES_FILE" "$key" <<'PY'
import sys

path, want = sys.argv[1:]
section = None
for raw in open(path, encoding="utf-8"):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if not line.startswith(" ") and line.endswith(":"):
        section = line[:-1]
        continue
    if section == "secrets" and line.startswith("  ") and ":" in line:
        key, value = line.strip().split(":", 1)
        if key == want:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] == '"':
                value = value[1:-1]
            print(value)
            break
PY
}

INTAKE_CLIENT_SECRET="${CRAIG_INTAKE_CLIENT_SECRET:-$(generated_value intakeClientSecret)}"
[ -n "$INTAKE_CLIENT_SECRET" ] || INTAKE_CLIENT_SECRET="$(openssl rand -base64 32)"
BACKEND_SERVICE_CLIENT_SECRET="${CRAIG_BACKEND_SERVICE_CLIENT_SECRET:-$(generated_value backendServiceClientSecret)}"
[ -n "$BACKEND_SERVICE_CLIENT_SECRET" ] || BACKEND_SERVICE_CLIENT_SECRET="$(openssl rand -base64 32)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR" "$ENV_VALUES_FILE"' EXIT

helm template craig "$CHART_DIR" \
  -f "$VALUES_FILE" \
  -f "$ENV_VALUES_FILE" \
  --show-only templates/render-keycloak-realm.yaml > "${BUILD_DIR}/keycloak-build-metadata.yaml"

yaml_data_value() {
  key="$1"
  awk -v key="  ${key}: " '
    index($0, key) == 1 {
      value = substr($0, length(key) + 1)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      exit
    }
  ' "${BUILD_DIR}/keycloak-build-metadata.yaml"
}

WEB_EXTERNAL_URL="$(yaml_data_value webExternalUrl)"
INTAKE_EXTERNAL_URL="$(yaml_data_value intakeExternalUrl)"

[ -n "$WEB_EXTERNAL_URL" ] || {
  echo "ERROR: failed to render webExternalUrl from Helm values" >&2
  exit 1
}

python3 - "$KEYCLOAK_REALM_SOURCE" "${BUILD_DIR}/craig-realm.json" \
  "$WEB_EXTERNAL_URL" "$INTAKE_EXTERNAL_URL" \
  "$INTAKE_CLIENT_SECRET" "$BACKEND_SERVICE_CLIENT_SECRET" <<'PY'
import json
import sys

source, output, web_url, intake_url, intake_secret, backend_secret = sys.argv[1:]
with open(source, encoding="utf-8") as fh:
    realm = json.load(fh)

backend_clients = {
    "craig-rules",
    "craig-cases",
    "craig-placement",
    "craig-exchange",
    "craig-financial",
    "craig-reporting",
    "craig-security",
    "craig-web",
    "craig-composition",
}

for client in realm.get("clients", []):
    client_id = client.get("clientId")
    if client_id == "craig-ui":
        client["redirectUris"] = [
            f"{web_url}/*",
            "http://localhost:8080/*",
            "http://localhost:3000/*",
            "http://docker:8080/*",
            "http://host.docker.internal:8080/*",
            "http://craig-web:8080/*",
        ]
        client["webOrigins"] = [
            web_url,
            "http://localhost:8080",
            "http://localhost:3000",
            "http://docker:8080",
            "http://host.docker.internal:8080",
            "http://craig-web:8080",
        ]
    elif client_id == "craig-intake":
        client["secret"] = intake_secret
    elif client_id in backend_clients:
        client["secret"] = backend_secret

with open(output, "w", encoding="utf-8") as fh:
    json.dump(realm, fh, indent=2)
    fh.write("\n")
PY

[ -s "${BUILD_DIR}/craig-realm.json" ] || {
  echo "ERROR: extracted an empty craig-realm.json" >&2
  exit 1
}
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${BUILD_DIR}/craig-realm.json"

cat > "${BUILD_DIR}/Dockerfile" <<'EOF'
FROM quay.io/keycloak/keycloak:26.5
USER root
COPY craig-realm.json /opt/keycloak/data/import/craig-realm.json
RUN chown 1000:0 /opt/keycloak/data/import /opt/keycloak/data/import/craig-realm.json \
    && chmod 0750 /opt/keycloak/data/import \
    && chmod 0640 /opt/keycloak/data/import/craig-realm.json
USER 1000
EOF

keycloak_tagged="$(ecr_image craig-keycloak-baked "$IMAGE_TAG")"
keycloak_latest="$(ecr_image craig-keycloak-baked latest)"
docker buildx build \
  --platform "$DOCKER_PLATFORM" \
  -t "$keycloak_tagged" \
  -t "$keycloak_latest" \
  --push \
  "$BUILD_DIR"

# Check traversal as the actual image user; COPY modes can affect a new parent directory.
docker run --rm --platform "$DOCKER_PLATFORM" --entrypoint /bin/sh "$keycloak_tagged" \
  -c 'test -x /opt/keycloak/data/import && test -r /opt/keycloak/data/import/craig-realm.json'

echo "==> Building and pushing baked devstack infra images..."
build_and_push_context "craig-postgres" "devstack/postgres/Dockerfile" "devstack/postgres"
build_and_push_context "craig-rabbitmq" "devstack/rabbitmq/Dockerfile" "devstack/rabbitmq"

echo "==> Building and pushing CRAIG app images..."
for target in $APP_TARGETS; do
  ensure_repo "$target"
  image_tagged="$(ecr_image "$target" "$IMAGE_TAG")"
  image_latest="$(ecr_image "$target" latest)"
  echo "==> ${target}: ${image_tagged}"
  docker buildx build \
    --platform "$DOCKER_PLATFORM" \
    --target "$target" \
    --build-arg "CARGO_PROFILE=${CARGO_PROFILE}" \
    --build-arg "CRAIG_WEB_FEATURES=${CRAIG_WEB_FEATURES}" \
    --build-arg "CRAIG_INTAKE_FEATURES=${CRAIG_INTAKE_FEATURES}" \
    --build-arg "CRAIG_CASES_FEATURES=${CRAIG_CASES_FEATURES}" \
    -t "$image_tagged" \
    -t "$image_latest" \
    --push \
    .
done

POSTGRES_IMAGE="$(ecr_image craig-postgres "$IMAGE_TAG")"
RABBITMQ_IMAGE="$(ecr_image craig-rabbitmq "$IMAGE_TAG")"

cat > "$OUTPUT_VALUES_FILE" <<EOF
images:
  repositoryPrefix: ${ECR_REGISTRY}/${ECR_PREFIX}
  tag: ${IMAGE_TAG}
  pullPolicy: IfNotPresent
keycloak:
  image: ${keycloak_tagged}
postgres:
  image: ${POSTGRES_IMAGE}
rabbitmq:
  image: ${RABBITMQ_IMAGE}
secrets:
  intakeClientSecret: "${INTAKE_CLIENT_SECRET}"
  backendServiceClientSecret: "${BACKEND_SERVICE_CLIENT_SECRET}"
EOF

cat "$ENV_VALUES_FILE" >> "$OUTPUT_VALUES_FILE"

echo
echo "Done. Generated Helm values file:"
echo "  ${OUTPUT_VALUES_FILE}"
echo
echo "Deploy with:"
echo "  CRAIG_EXTRA_VALUES_FILE=${OUTPUT_VALUES_FILE} scripts/helm-deploy-craig-eks-gitlab.sh"
