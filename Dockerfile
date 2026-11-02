# syntax=docker/dockerfile:1.7
#
# Hardened GeoServer 3.0.x image for FIPS-enabled hosts.
#   Base:    Rocky Linux 9 UBI-init (pinned by digest; this digest is the linux/amd64 image)
#   Java:    distro-packaged OpenJDK 21 JRE (the JVM that honours the RHEL system crypto policy)
#   Servlet: Apache Tomcat 11 (GeoServer 3 needs Servlet API 6.1)
#   Plugins: fips, cog-s3, cog-http, duckdb, sec-keycloak-roles
#
# Community modules are NOT published with stable releases, and a module built against a
# different core build usually fails. So we take the stable WAR and build the community
# modules from the matching git tag. The "plugins" and "assemble" stages run in parallel.

ARG BASE_IMAGE=rockylinux/rockylinux:9-ubi-init@sha256:3ce8a19ffda84f34b790ce6e4575fb1bccca97df3ab43e464df1675cabde52f6
ARG GS_VERSION=3.0.2

############################################################################
# Stage 1: build the community plugin jars from the matching git tag
############################################################################
FROM ${BASE_IMAGE} AS plugins
ARG GS_VERSION
ARG GS_GIT_REF=${GS_VERSION}
ARG MAVEN_VERSION=3.9.11

RUN dnf -y install --setopt=install_weak_deps=False java-21-openjdk-devel git-core tar gzip findutils \
 && dnf clean all
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
    PATH=/opt/maven/bin:${PATH}

RUN set -eux; cd /tmp; \
    base="https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries"; \
    f="apache-maven-${MAVEN_VERSION}-bin.tar.gz"; \
    curl -fsSLO "${base}/${f}"; curl -fsSLO "${base}/${f}.sha512"; \
    echo "$(cat ${f}.sha512)  ${f}" | sha512sum -c -; \
    mkdir /opt/maven; tar -xzf "${f}" -C /opt/maven --strip-components=1; rm -f "${f}"*

WORKDIR /src
RUN git clone --depth 1 --single-branch --branch "${GS_GIT_REF}" https://github.com/geoserver/geoserver.git .

COPY scripts/build-plugins.sh /usr/local/bin/build-plugins.sh
RUN --mount=type=cache,target=/root/.m2 bash /usr/local/bin/build-plugins.sh

############################################################################
# Stage 2: assemble webapp (stable WAR + FIPS jar swap + plugins) inside Tomcat
############################################################################
FROM ${BASE_IMAGE} AS assemble
ARG GS_VERSION
ARG GS_WAR_URL=https://downloads.sourceforge.net/project/geoserver/GeoServer/${GS_VERSION}/geoserver-${GS_VERSION}-war.zip
ARG GS_WAR_SHA256=""
ARG TOMCAT_VERSION=11.0.25

RUN dnf -y install --setopt=install_weak_deps=False unzip tar gzip findutils && dnf clean all

WORKDIR /build
# Downloads first (cached independently of the plugin build)
RUN set -eux; \
    curl -fsSL -o war.zip "${GS_WAR_URL}"; \
    if [ -n "${GS_WAR_SHA256}" ]; then echo "${GS_WAR_SHA256}  war.zip" | sha256sum -c -; fi; \
    unzip -q -p war.zip geoserver.war > geoserver.war; \
    mkdir geoserver; unzip -q geoserver.war -d geoserver; rm -f war.zip geoserver.war

RUN set -eux; \
    base="https://archive.apache.org/dist/tomcat/tomcat-11/v${TOMCAT_VERSION}/bin"; \
    f="apache-tomcat-${TOMCAT_VERSION}.tar.gz"; \
    curl -fsSLO "${base}/${f}"; curl -fsSLO "${base}/${f}.sha512"; \
    sha512sum -c "${f}.sha512"; \
    mkdir tomcat; tar -xzf "${f}" -C tomcat --strip-components=1; rm -f "${f}"*; \
    cd tomcat; \
    rm -rf webapps/* webapps.dist bin/*.bat; \
    sed -i 's|<Server port="8005"|<Server port="-1"|' conf/server.xml; \
    sed -i 's|<Connector port="8080"|<Connector port="8080" server="GeoServer" xpoweredBy="false"|' conf/server.xml; \
    sed -i 's|autoDeploy="true"|autoDeploy="false"|' conf/server.xml; \
    sed -i 's|</Host>|  <Valve className="org.apache.catalina.valves.ErrorReportValve" showReport="false" showServerInfo="false"/>\n      </Host>|' conf/server.xml; \
    grep -q 'port="-1"' conf/server.xml && grep -q showServerInfo conf/server.xml && grep -q 'autoDeploy="false"' conf/server.xml

COPY --from=plugins /out/lib /build/plugin-lib
COPY scripts/assemble-plugins.sh /usr/local/bin/assemble-plugins.sh
# Set final permissions HERE so the runtime stage needs no recursive chmod/chown
# (which would duplicate the whole webapp into a second image layer).
RUN set -eux; \
    bash /usr/local/bin/assemble-plugins.sh /build/geoserver /build/plugin-lib; \
    mv /build/geoserver tomcat/webapps/geoserver; \
    mkdir -p tomcat/conf/Catalina/localhost; \
    chmod -R a+rX,go-w tomcat

############################################################################
# Stage 3: runtime
############################################################################
FROM ${BASE_IMAGE} AS runtime
ARG GS_UID=10001
ARG GS_VERSION
LABEL org.opencontainers.image.title="geoserver-fips" \
      org.opencontainers.image.version="${GS_VERSION}" \
      org.opencontainers.image.description="Hardened GeoServer ${GS_VERSION} (FIPS, cog-s3, cog-http, duckdb, sec-keycloak-roles) on Rocky Linux 9"

# Patch the whole base image (the digest-pinned base is only as fresh as when it was published),
# install the JRE and runtime libraries, set the FIPS crypto policy, strip setuid/setgid bits.
# NOTE: crypto-policies-scripts must stay installed. The Java package depends on it, so
# "dnf remove crypto-policies-scripts" silently removes Java as well.
RUN set -eux; \
    dnf -y upgrade --refresh; \
    dnf -y install --setopt=install_weak_deps=False --nodocs \
        java-21-openjdk-headless nss openssl-libs crypto-policies crypto-policies-scripts \
        fontconfig freetype dejavu-sans-fonts; \
    update-crypto-policies --set FIPS; \
    JHOME="$(dirname "$(dirname "$(readlink -f /usr/bin/java)")")"; \
    ln -s "${JHOME}" /opt/java; \
    dnf clean all; rm -rf /var/cache/dnf /var/log/dnf* /var/lib/dnf/history*; \
    find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true; \
    # final assertions, AFTER every dnf operation in this layer
    rpm -q java-21-openjdk-headless nss openssl-libs crypto-policies fontconfig freetype dejavu-sans-fonts; \
    grep -qx FIPS /etc/crypto-policies/config; \
    /opt/java/bin/java -version

# /opt/java is a stable link to the real JRE install dir, resolved at build time
# (the /usr/lib/jvm/jre-* alias names vary by package version). Tomcat runs java via JRE_HOME.
ENV CATALINA_HOME=/opt/tomcat \
    GEOSERVER_DATA_DIR=/opt/geoserver_data \
    JRE_HOME=/opt/java \
    JAVA_OPTS="-Djava.awt.headless=true -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError -Dfile.encoding=UTF-8 -XX:ErrorFile=/opt/tomcat/logs/hs_err_pid%p.log"
# Do NOT add -Dorg.bouncycastle.fips.approved_only=false; the FIPS module turns approved-only on.

# Application files stay root-owned and read-only for the service user;
# only logs/temp/work, Tomcat's per-host conf dir and the data dir are writable (group 0 for arbitrary UIDs).
COPY --from=assemble /build/tomcat ${CATALINA_HOME}
RUN useradd --system --uid ${GS_UID} --gid 0 --no-create-home --home-dir ${CATALINA_HOME} --shell /sbin/nologin geoserver \
 && mkdir -p ${GEOSERVER_DATA_DIR} \
 && cd ${CATALINA_HOME} \
 && chown -R ${GS_UID}:0 logs temp work conf/Catalina ${GEOSERVER_DATA_DIR} \
 && chmod -R g=u logs temp work conf/Catalina ${GEOSERVER_DATA_DIR}

USER ${GS_UID}
# Build-time check, as the service user: the JVM runs and Tomcat accepts JRE_HOME
RUN "${JRE_HOME}/bin/java" -version && "${CATALINA_HOME}/bin/catalina.sh" version
WORKDIR ${CATALINA_HOME}
VOLUME ["/opt/geoserver_data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD ["/bin/bash","-c","exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /geoserver/web/ HTTP/1.0\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -Eq ' (200|302) '"]

STOPSIGNAL SIGTERM
# ubi-init defaults to systemd as PID 1; we run Tomcat directly instead.
ENTRYPOINT []
CMD ["/opt/tomcat/bin/catalina.sh", "run"]