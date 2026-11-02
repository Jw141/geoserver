#!/usr/bin/env bash
# Run ON a FIPS-enabled host. Usage: scripts/verify-fips.sh [image]
# Exits non-zero on the first failed check and dumps any JVM crash log.
set -uo pipefail
IMAGE="${1:-geoserver-fips:dev}"
RT="${CONTAINER_RT:-$(command -v podman || command -v docker)}"
NAME="gs-fips-verify-$$"
ADMIN_USER="${GS_ADMIN_USER:-admin}"
ADMIN_PASS="${GS_ADMIN_PASSWORD:-geoserver}"   # set the real one if you changed it
pass(){ echo "PASS  $*"; }; fail(){ echo "FAIL  $*"; dump; cleanup; exit 1; }
dump(){ $RT logs --tail 80 "$NAME" 2>&1 | sed 's/^/  | /'
        $RT exec "$NAME" sh -c 'ls /opt/tomcat/logs/hs_err_pid*.log 2>/dev/null | head -1 | xargs -r head -60' 2>&1 | sed 's/^/  hs_err| /'; }
cleanup(){ $RT rm -f "$NAME" >/dev/null 2>&1; [ -n "${DATA:-}" ] && rm -rf "$DATA"; }
trap cleanup EXIT

# 1. host must really be in FIPS mode
[ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = "1" ] && pass "host kernel FIPS=1" || fail "host is not in FIPS mode"

# 2. JVM starts and sees FIPS on this host (no gateway: plain java, no GeoServer)
$RT run --rm --entrypoint /opt/java/bin/java "$IMAGE" -version >/dev/null 2>&1 \
  && pass "java -version (no SIGSEGV)" || fail "java -version crashed or failed"
$RT run --rm --entrypoint /bin/cat "$IMAGE" /proc/sys/crypto/fips_enabled | grep -q 1 && pass "container sees fips_enabled=1" || fail "container does not see fips_enabled=1"
$RT run --rm --entrypoint /bin/cat "$IMAGE" /etc/crypto-policies/config | grep -q '^FIPS' \
  && pass "crypto policy FIPS" || fail "image crypto policy is not FIPS"

# 3. GeoServer boots on a fresh data dir
DATA="$(mktemp -d)"; chmod 777 "$DATA"   # test-only: container uid 10001 must be able to write
$RT run -d --name "$NAME" -p 18080:8080 -v "$DATA:/opt/geoserver_data:Z" "$IMAGE" >/dev/null || fail "container did not start"
for i in $(seq 1 60); do
  curl -fsS -o /dev/null "http://localhost:18080/geoserver/web/" && break
  $RT ps --filter "name=$NAME" --format '{{.Names}}' | grep -q . || fail "container exited during startup"
  sleep 5
done
curl -fsS -o /dev/null "http://localhost:18080/geoserver/web/" && pass "GeoServer web UI up" || fail "GeoServer did not come up"

# 4. FIPS module self-report (gs-fips-provider entry of the status page)
ST="$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASS" -H 'Accept: application/json' http://localhost:18080/geoserver/rest/about/status.json || true)"
echo "$ST" | grep -q gs-fips-provider && pass "gs-fips-provider module present" || fail "FIPS module not loaded (status: ${ST:0:200})"
echo "$ST" | grep -q 'Crypto module: READY'   && pass "crypto module READY"   || fail "crypto module not READY"
echo "$ST" | grep -q 'Approved-only mode: on' && pass "approved-only on"      || fail "approved-only is NOT on"
echo "$ST" | grep -q 'Operating system FIPS mode: yes' && pass "OS FIPS mode yes" || fail "module does not see OS FIPS mode"

# 5. no crash artefacts
$RT exec "$NAME" sh -c 'ls /opt/tomcat/logs/hs_err_pid*.log' 2>/dev/null && fail "JVM crash log found" || pass "no hs_err crash logs"
echo "ALL CHECKS PASSED"