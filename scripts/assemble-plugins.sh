#!/usr/bin/env bash
# Usage: assemble-plugins.sh <exploded-war-dir> <plugin-lib-dir> [<overrides-dir>]
# Swaps BouncyCastle for the FIPS jars and merges ONLY the plugin jars the WAR does not
# already ship. The Maven dependency copy contains hundreds of jars the WAR already has
# (often at other versions); copying those would put two versions on the classpath.
set -euo pipefail
WAR="$1"; PLUG="$2"; OVR="${3:-}"; LIB="$WAR/WEB-INF/lib"

# 1. drop the regular BouncyCastle jars from the WAR
rm -f "$LIB"/bcprov-*.jar "$LIB"/bcpkix-*.jar "$LIB"/bcutil-*.jar

added=0; skipped=0
for f in "$PLUG"/*.jar; do
  n="$(basename "$f")"
  base="$(echo "$n" | sed -E 's/-[0-9][^/]*\.jar$//')"

  # never take non-FIPS BouncyCastle (it comes in transitively), nor test-support jars
  case "$n" in
    bcprov-*|bcpkix-*|bcutil-*) case "$n" in *fips*) ;; *) echo "SKIP  non-FIPS BC : $n"; continue;; esac;; esac
  case "$base" in *-tests) echo "SKIP  tests jar     : $n"; continue;; esac

  # artifact already in the WAR (any version) -> keep the WAR's copy
  if compgen -G "$LIB/${base}-[0-9]*.jar" >/dev/null; then
    skipped=$((skipped+1)); continue
  fi
  cp "$f" "$LIB/"; added=$((added+1)); echo "ADD   $n"
done
echo "added=$added skipped(already in WAR)=$skipped"

# 1b. security overrides: replace any version of the same artifact, unless the image already has a newer one
if [ -n "$OVR" ] && compgen -G "$OVR/*.jar" >/dev/null; then
  for f in "$OVR"/*.jar; do
    n="$(basename "$f")"; base="$(echo "$n" | sed -E 's/-[0-9][^/]*\.jar$//')"
    vo="${n#${base}-}"; vo="${vo%.jar}"
    newer=""
    for e in $(compgen -G "$LIB/${base}-[0-9]*.jar" || true); do
      ve="$(basename "$e")"; ve="${ve#${base}-}"; ve="${ve%.jar}"
      if [ "$ve" != "$vo" ] && [ "$(printf '%s\n%s\n' "$vo" "$ve" | sort -V | tail -1)" = "$ve" ]; then newer="$ve"; fi
    done
    if [ -n "$newer" ]; then echo "WARN  override $n skipped: image already has $base $newer (remove it from jar-overrides.txt)"; continue; fi
    rm -f "$LIB/${base}"-[0-9]*.jar
    cp "$f" "$LIB/"; echo "OVERRIDE $n"
  done
fi

# 2. a data directory written by a normal GeoServer cannot be opened under FIPS
rm -rf "$WAR/data"

# 3. assertions
echo "--- BouncyCastle jars now present:"; ls "$LIB" | grep -i '^bc' || true
if ls "$LIB" | grep -Ei '^bc.*(lts8on|jdk1[0-9]on|jdk15)'; then echo "ERROR: non-FIPS BouncyCastle jar present" >&2; exit 1; fi
for want in bc-fips bcpkix-fips bcutil-fips gs-fips-provider gs-web-fips gs-cog-core gs-cog-http gs-cog-s3 gs-sec-keycloak-roles-core gs-sec-keycloak-roles-web; do
  compgen -G "$LIB/${want}-[0-9]*.jar" >/dev/null || { echo "ERROR: missing $want" >&2; exit 1; }
done
compgen -G "$LIB/*duckdb*.jar" >/dev/null || { echo "ERROR: no duckdb jars" >&2; exit 1; }
echo "--- duplicate artifacts (should be empty):"
ls "$LIB" | sed -E 's/-[0-9][^/]*\.jar$//' | sort | uniq -d | sed 's/^/DUPLICATE: /'