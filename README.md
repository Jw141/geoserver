# geoserver-fips

Hardened GeoServer 3.0.x container for FIPS-enabled hosts.

- Base: `rockylinux/rockylinux:9-ubi-init` (digest-pinned, linux/amd64)
- Java: Rocky-packaged OpenJDK 21 (reads the system crypto policy)
- Tomcat 11 (GeoServer 3 requires Servlet 6.1)
- GeoServer 3.0.2 (stable WAR from SourceForge)
- Plugins: `fips`, `cog-s3`, `cog-http`, `duckdb`, `sec-keycloak-roles` — community modules, **built from the 3.0.2 git tag** (they are not published with stable releases)
- Runs as non-root (uid 10001), no default Tomcat apps, shutdown port off, version info hidden

## Build
    docker build -t geoserver-fips:dev .

## Run (on a FIPS host: `cat /proc/sys/crypto/fips_enabled` -> 1)
    mkdir -p data && sudo chown 10001:0 data
    docker run -p 8080:8080 -v $PWD/data:/opt/geoserver_data geoserver-fips:dev

Then open **About & Status > Server Status > FIPS** and confirm: crypto module READY,
approved-only mode on, OS FIPS mode yes, provider position first.

## Things to know
1. **New data directory required.** A FIPS GeoServer cannot open a data directory created by a normal one
   (keystore JCEKS -> BCFKS, password encryption crypt3). No migration tool yet.
2. Community modules must match the core build exactly, so the Dockerfile builds them from the git tag. First build is slow (Maven compiles GeoServer core modules); BuildKit caches `~/.m2`. Override with `--build-arg GS_VERSION=3.0.3`; set `GS_WAR_SHA256` to pin the WAR.
3. The module does not put the host in FIPS mode; that is a kernel boot setting.
4. `cog-http` is assumed to be what was meant by "cot-http".

## Verifying on a FIPS host
    docker build -t geoserver-fips:dev .
    GS_ADMIN_PASSWORD=<admin pw> scripts/verify-fips.sh geoserver-fips:dev

The script checks: host FIPS=1, `java -version` survives (no SIGSEGV), GeoServer boots on a fresh
data dir, the `gs-fips-provider` status reports READY / approved-only on / OS FIPS yes, and no
`hs_err_pid*.log` appeared. On failure it prints the container log and the head of any crash log.

If the JVM still crashes: grab `/opt/tomcat/logs/hs_err_pid*.log` (the "Problematic frame" and
"Native frames" lines name the library). On Docker (not Podman), also try
`-v /etc/crypto-policies:/etc/crypto-policies:ro` since Podman mounts host FIPS state automatically and Docker does not.

## DuckDB notes
- The JDBC driver ships a native library that is extracted to `java.io.tmpdir` (Tomcat: `/opt/tomcat/temp`) and loaded.
  With a read-only root filesystem, mount a **writable, exec-enabled** tmpfs there (not `noexec`).
- DuckDB's native code and its extensions (e.g. httpfs, spatial) do their own crypto and are **outside** the BouncyCastle FIPS
  boundary. Stores are read-only by default; check with your compliance owner before enabling remote (https/S3) access from DuckDB.
- Extensions cannot be downloaded at runtime in an air-gapped environment.