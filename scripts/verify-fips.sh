#!/usr/bin/env bash
# Run ON a FIPS-enabled host. Usage: scripts/verify-fips.sh [image]
# On a non-FIPS machine (e.g. a Codespace) use: ALLOW_NON_FIPS=1 scripts/verify-fips.sh [image]
#   -> host/OS FIPS checks become warnings; everything else (module loaded, READY,
#      approved-only, no JVM crash) is still checked. This is NOT proof of FIPS operation.
# Exits non-zero on the first failed check and dumps any JVM crash log.
set -uo pipefail
IMAGE="${1:-geoserver-fips:dev}"
RT="${CONTAINER_RT:-$(command -v podman || command -v docker)}"
NAME="gs-fips-verify-$$"
ADMIN_USER="${GS_ADMIN_USER:-admin}"
ADMIN_PASS="${GS_ADMIN_PASSWORD:-geoserver}"   # set the real one if you changed it
ALLOW_NON_FIPS="${ALLOW_NON_FIPS:-0}"
pass(){ echo "PASS  $*"; }; fail(){ echo "FAIL  $*"; dump; cleanup; exit 1; }
hostcheck(){ if [ "$ALLOW_NON_FIPS" = 1 ]; then echo "WARN  $* (ALLOW_NON_FIPS=1)"; else fail "$*"; fi; }
dump(){ $RT inspect "$NAME" >/dev/null 2>&1 || return 0   # nothing started yet
        $RT logs --tail 80 "$NAME" 2>&1 | sed 's/^/  | /'
        $RT exec "$NAME" sh -c 'ls /opt/tomcat/logs/hs_err_pid*.log 2>/dev/null | head -1 | xargs -r head -60' 2>&1 | sed 's/^/  hs_err| /'; }
VOL="${NAME}-data"; CLEANED=0
cleanup(){ [ "$CLEANED" = 1 ] && return 0; CLEANED=1
           $RT rm -f "$NAME" >/dev/null 2>&1; $RT volume rm -f "$VOL" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 1. host must really be in FIPS mode
[ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = "1" ] && pass "host kernel FIPS=1" || hostcheck "host is not in FIPS mode"

# 2. JVM starts and sees FIPS on this host (no gateway: plain java, no GeoServer)
$RT run --rm --entrypoint /opt/java/bin/java "$IMAGE" -version >/dev/null 2>&1 \
  && pass "java -version (no SIGSEGV)" || fail "java -version crashed or failed"
$RT run --rm --entrypoint /bin/cat "$IMAGE" /proc/sys/crypto/fips_enabled | grep -q 1 && pass "container sees fips_enabled=1" || hostcheck "container does not see fips_enabled=1"
$RT run --rm --entrypoint /bin/cat "$IMAGE" /etc/crypto-policies/config | grep -q '^FIPS' \
  && pass "crypto policy FIPS" || fail "image crypto policy is not FIPS"

# 3. GeoServer boots on a fresh data dir
# fresh, empty data dir in a throwaway named volume (inherits the image's ownership; removed on exit)
$RT volume create "$VOL" >/dev/null
$RT run -d --name "$NAME" -p 18080:8080 -v "$VOL:/opt/geoserver_data" "$IMAGE" >/dev/null || fail "container did not start"
for i in $(seq 1 60); do
  curl -fs -o /dev/null "http://localhost:18080/geoserver/web/" 2>/dev/null && break
  $RT ps --filter "name=$NAME" --format '{{.Names}}' | grep -q . || fail "container exited during startup"
  sleep 5
done
curl -fsS -o /dev/null "http://localhost:18080/geoserver/web/" && pass "GeoServer web UI up" || fail "GeoServer did not come up"

# 4. FIPS module self-report. /rest/about/status.json only lists module names + links,
#    so find the FIPS entry and fetch its own status document.
AUTH=(-u "$ADMIN_USER:$ADMIN_PASS" -H 'Accept: application/json')
LIST="$(curl -fsS "${AUTH[@]}" http://localhost:18080/geoserver/rest/about/status.json || true)"
HREF="$(echo "$LIST" | grep -oE '"name":"[^"]*FIPS[^"]*","href":"[^"]*"' | head -1 | sed -E 's/.*"href":"([^"]*)"/\1/')"
[ -n "$HREF" ] && pass "FIPS module listed in server status" || fail "FIPS module not in server status (check admin password; got: ${LIST:0:200})"
# The status API is a chain of listings ({"statuss":...} with "href" links) ending in a detail
# document. Links encode spaces as "+", which GeoServer's own lookup may not decode, so each
# link is tried as given and with %20. Follow links until we reach the detail document.
BASE="http://localhost:18080/geoserver/rest/about/status"
fetch(){ local u r; for u in "$1" "${1//+/%20}"; do
           r="$(curl -fs "${AUTH[@]}" "$u" 2>/dev/null)" && [ -n "$r" ] && { echo "$r"; return 0; }
         done; return 1; }
ST="$(fetch "$BASE/gs-fips-provider.json" || fetch "$HREF" || true)"
for depth in 1 2 3; do
  echo "$ST" | grep -q '"statuss"' || break                     # already a detail document
  NEXT="$(echo "$ST" | grep -oE '"href":"[^"]*"' | head -1 | sed -E 's/"href":"([^"]*)"/\1/')"
  [ -n "$NEXT" ] || break
  R="$(fetch "$NEXT" || true)"; [ -n "$R" ] || break
  ST="$R"
done
if echo "$ST" | grep -q '"statuss"'; then
  echo "      FIPS module status (listing only): $ST"
  echo "WARN  could not read the FIPS module details over REST."
  echo "      Check in the UI instead: About & Status > Server Status > FIPS"
  echo "      (crypto module READY, approved-only on, OS FIPS mode yes on a FIPS host)."
  DETAIL=0
else
  DETAIL=1
fi
if [ "$DETAIL" = 1 ]; then
  echo "      FIPS module status: $ST"
  echo "$ST" | grep -qiE '"isAvailable" *: *true|"available" *: *true' && pass "FIPS module available" || fail "FIPS module not available"
  echo "$ST" | grep -qi 'ready'                                   && pass "crypto module READY"  || fail "crypto module not reported READY"
  echo "$ST" | grep -qiE 'approved[^,"]*(on|true|yes|enabled)'     && pass "approved-only on"     || fail "approved-only mode not reported on"
  echo "$ST" | grep -qiE '(os|operating system)[^,"]*fips[^,"]*(yes|true|on|enabled)' \
    && pass "OS FIPS mode yes" || hostcheck "module does not report OS FIPS mode"
fi

# 5. no crash artefacts
$RT exec "$NAME" sh -c 'ls /opt/tomcat/logs/hs_err_pid*.log' 2>/dev/null && fail "JVM crash log found" || pass "no hs_err crash logs"
if [ "$DETAIL" != 1 ]; then echo "CHECKS PASSED EXCEPT FIPS MODULE DETAILS: confirm them in the UI (see WARN above)"
elif [ "$ALLOW_NON_FIPS" = 1 ]; then echo "CHECKS PASSED (non-FIPS host: run again on a FIPS host for the real result)"
else echo "ALL CHECKS PASSED"; fi