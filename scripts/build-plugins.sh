#!/usr/bin/env bash
# Builds the community plugins from the GeoServer source tree (cwd = repo root) and
# collects module jars + runtime dependencies into /out/lib.
#
# Strategy A (fast): build each module group in its own small reactor. Core gs-* 3.0.x
#   artifacts are resolved from the OSGeo release repository, NOT rebuilt.
# Strategy B (fallback): full-reactor build with the communityRelease profile (slow).
set -euo pipefail
cd src
OUT=/out/lib; mkdir -p "$OUT"
# No -T (parallel): modules copy dependencies into the same directory and would race.
MVN="mvn -B -ntp -DskipTests -Dmaven.javadoc.skip=true -Dmaven.source.skip=true"
COPY="-DoutputDirectory=$OUT -DincludeScope=runtime -Dmdep.useRepositoryLayout=false"

# Fail early and clearly if a module is not present in this GeoServer tag
for m in community/fips community/cog community/duckdb community/keycloak-roles; do
  test -f "$m/pom.xml" || { echo "ERROR: $m/pom.xml not found in this GeoServer tag" >&2; exit 1; }
done

# NOTE: called inside `if !`, where `set -e` is disabled, so steps are chained with && explicitly.
strategy_a() {
  $MVN -f community/cog/pom.xml -pl cog-core,cog-s3,cog-http package dependency:copy-dependencies $COPY \
  && $MVN -f community/fips/pom.xml package dependency:copy-dependencies $COPY \
  && $MVN -f community/duckdb/pom.xml package dependency:copy-dependencies $COPY \
  && $MVN -f community/keycloak-roles/pom.xml package dependency:copy-dependencies $COPY
}
strategy_b() {
  $MVN -PcommunityRelease -pl community/fips,community/cog/cog-core,community/cog/cog-s3,community/cog/cog-http,community/duckdb,community/keycloak-roles -am \
       install dependency:copy-dependencies $COPY
}

if ! strategy_a; then
  echo "Strategy A failed; falling back to full reactor build (slow)" >&2
  strategy_b
fi

# module jars themselves
find community/cog community/fips community/duckdb community/keycloak-roles -path '*/target/*.jar' \
     ! -name '*-tests.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' -exec cp -f {} "$OUT"/ \;
echo "collected $(ls "$OUT" | wc -l) jars"
for want in fips cog duckdb sec-keycloak-roles; do
  ls "$OUT" | grep -qi "$want" || { echo "ERROR: no $want jars collected" >&2; exit 1; }
done