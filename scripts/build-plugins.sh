#!/usr/bin/env bash
# Builds the community plugins from the GeoServer source tree (cwd = repo root) and
# collects module jars + runtime dependencies into /out/lib.
#
# Strategy A (fast): build each module group in its own small reactor. Core gs-* 3.0.x
#   artifacts are resolved from the OSGeo release repository, NOT rebuilt.
# Strategy B (fallback): full-reactor build with the communityRelease profile (slow).
set -euxo pipefail
cd src
OUT=/out/lib; mkdir -p "$OUT"
MVN="mvn -B -ntp -DskipTests -Dmaven.javadoc.skip=true"
COPY="-DoutputDirectory=$OUT -DincludeScope=runtime -Dmdep.useRepositoryLayout=false"

# NOTE: called inside `if !`, where `set -e` is disabled, so steps are chained with && explicitly.
strategy_a() {
  $MVN -f community/cog/pom.xml -pl cog-core,cog-s3,cog-http package dependency:copy-dependencies $COPY \
  && $MVN -f community/fips/pom.xml package dependency:copy-dependencies $COPY \
  && $MVN -f community/duckdb/pom.xml package dependency:copy-dependencies $COPY
}
strategy_b() {
  $MVN -PcommunityRelease -pl community/fips,community/cog/cog-core,community/cog/cog-s3,community/cog/cog-http,community/duckdb -am \
       install dependency:copy-dependencies $COPY
}

if ! strategy_a; then
  echo "Strategy A failed; falling back to full reactor build (slow)" >&2
  strategy_b
fi

# module jars themselves
find community/cog community/fips community/duckdb -path '*/target/*.jar' \
     ! -name '*-tests.jar' ! -name '*-sources.jar' ! -name '*-javadoc.jar' -exec cp -f {} "$OUT"/ \;
ls "$OUT" | wc -l
ls "$OUT" | grep -Ei 'fips|cog' >/dev/null && ls "$OUT" | grep -Ei 'duckdb' || { echo "expected fips/cog/duckdb jars missing" >&2; exit 1; }