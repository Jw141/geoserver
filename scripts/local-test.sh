#!/usr/bin/env bash
# Local equivalent of the CI workflow (build + smoke test + optional scan), e.g. in a Codespace.
# Usage:
#   scripts/local-test.sh                 # full build + smoke test, leaves GeoServer running
#   scripts/local-test.sh --target plugins  # only build up to a stage (fast iteration on one step)
#   KEEP=0 scripts/local-test.sh          # stop the container after the test
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-geoserver-fips:local}"
NAME="${NAME:-gs-local}"
PORT="${PORT:-8080}"
KEEP="${KEEP:-1}"

command -v docker >/dev/null || { echo "docker not found: add the docker-in-docker feature to your devcontainer" >&2; exit 1; }
docker info >/dev/null 2>&1   || { echo "docker daemon not reachable" >&2; exit 1; }

# 1. Build (same Dockerfile and build arg as CI). --progress=plain shows full Maven/script output.
if [ "${1:-}" = "--target" ]; then
  DOCKER_BUILDKIT=1 docker build --progress=plain --target "$2" -t "$IMAGE-$2" .
  echo "Built stage '$2' only."; exit 0
fi
DOCKER_BUILDKIT=1 docker build --progress=plain --build-arg GS_VERSION="${GS_VERSION:-3.0.2}" -t "$IMAGE" .

# 2. Smoke test (same check as CI)
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT:8080" "$IMAGE" >/dev/null
echo "Waiting for GeoServer on port $PORT ..."
ok=0
for i in $(seq 1 60); do
  if curl -fsS "http://localhost:$PORT/geoserver/ows?service=wms&version=1.3.0&request=GetCapabilities" >/dev/null 2>&1; then
    ok=1; echo "UP after $((i*5))s"; break
  fi
  if [ -z "$(docker ps -q --filter "name=^${NAME}$")" ]; then echo "Container exited:"; break; fi
  sleep 5
done
if [ "$ok" != 1 ]; then docker logs --tail 150 "$NAME"; docker rm -f "$NAME" >/dev/null; exit 1; fi

# 3. Optional vulnerability scan, only if trivy is installed locally (report only, never fails)
if command -v trivy >/dev/null; then
  trivy image --severity CRITICAL,HIGH --ignore-unfixed --exit-code 0 "$IMAGE" || true
else
  echo "(trivy not installed; skipping scan)"
fi

if [ "$KEEP" = 1 ]; then
  echo "GeoServer is running: http://localhost:$PORT/geoserver   (stop: docker rm -f $NAME)"
else
  docker rm -f "$NAME" >/dev/null
fi