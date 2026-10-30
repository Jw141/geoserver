# syntax=docker/dockerfile:1.7
#
# Hardened GeoServer 3.0.x image for FIPS-enabled hosts.
#   Base:    Rocky Linux 9 UBI-init (pinned by digest; this digest is the linux/amd64 image)
#   Java:    distro-packaged OpenJDK 21 (the JVM that honours the RHEL system crypto policy)
#   Servlet: Apache Tomcat 11 (GeoServer 3 needs Servlet API 6.1)
#   Plugins: fips + cog-s3 + cog-http, built from the GeoServer git tag matching the release
#
# Community modules are NOT published with stable releases, and a module built against
# a different core build usually fails. So we take the stable WAR and build the community
# modules from the matching tag.

ARG BASE_IMAGE=rockylinux/rockylinux:9-ubi-init@sha256:3ce8a19ffda84f34b790ce6e4575fb1bccca97df3ab43e464df1675cabde52f6
ARG GS_VERSION=3.0.2

############################################################################
# Stage 1: build the community plugin jars from the matching git tag
############################################################################
FROM ${BASE_IMAGE} AS plugins
ARG GS_VERSION
ARG GS_GIT_REF=${GS_VERSION}
ARG MAVEN_VERSION=3.9.11

RUN dnf -y install --setopt=install_weak_deps=False java-21-openjdk-devel git tar gzip findutils \
 && dnf clean all
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk

WORKDIR /opt
RUN set -eux; \
    base="https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries"; \
    curl -fsSLO "${base}/apache-maven-${MAVEN_VERSION}-bin.tar.gz"; \
    curl -fsSLO "${base}/apache-maven-${MAVEN_VERSION}-bin.tar.gz.sha512"; \
    echo "$(cat apache-maven-${MAVEN_VERSION}-bin.tar.gz.sha512)  apache-maven-${MAVEN_VERSION}-bin.tar.gz" | sha512sum -c -; \
    mkdir maven; tar -xzf apache-maven-${MAVEN_VERSION}-bin.tar.gz -C maven --strip-components=1
ENV PATH=/opt/maven/bin:${PATH}

WORKDIR /src
RUN git clone --depth 1 --branch "${GS_GIT_REF}" https://github.com/geoserver/geoserver.git .

# Build fips + cog-s3 + cog-http and collect jars into /out/lib (see scripts/build-plugins.sh)
COPY scripts/build-plugins.sh /usr/local/bin/build-plugins.sh
RUN --mount=type=cache,target=/root/.m2 bash /usr/local/bin/build-plugins.sh

############################################################################
# Stage 2: assemble webapp (stable WAR + FIPS jar swap + plugins) and Tomcat
############################################################################
FROM ${BASE_IMAGE} AS assemble
ARG GS_VERSION
ARG GS_WAR_URL=https://downloads.sourceforge.net/project/geoserver/GeoServer/${GS_VERSION}/geoserver-${GS_VERSION}-war.zip
ARG GS_WAR_SHA256=""
ARG TOMCAT_VERSION=11.0.25

RUN dnf -y install --setopt=install_weak_deps=False unzip tar gzip findutils && dnf clean all

WORKDIR /build
RUN set -eux; \
    curl -fsSL -o war.zip "${GS_WAR_URL}"; \
    if [ -n "${GS_WAR_SHA256}" ]; then echo "${GS_WAR_SHA256}  war.zip" | sha256sum -c -; fi; \
    unzip -q war.zip geoserver.war; \
    mkdir geoserver; unzip -q geoserver.war -d geoserver

RUN set -eux; \
    base="https://archive.apache.org/dist/tomcat/tomcat-11/v${TOMCAT_VERSION}/bin"; \
    curl -fsSLO "${base}/apache-tomcat-${TOMCAT_VERSION}.tar.gz"; \
    curl -fsSLO "${base}/apache-tomcat-${TOMCAT_VERSION}.tar.gz.sha512"; \
    sha512sum -c "apache-tomcat-${TOMCAT_VERSION}.tar.gz.sha512"; \
    mkdir tomcat; tar -xzf "apache-tomcat-${TOMCAT_VERSION}.tar.gz" -C tomcat --strip-components=1

COPY --from=plugins /out/lib /build/plugin-lib

COPY scripts/assemble-plugins.sh /usr/local/bin/assemble-plugins.sh
RUN bash /usr/local/bin/assemble-plugins.sh /build/geoserver /build/plugin-lib

RUN set -eux; cd tomcat; \
    rm -rf webapps/* webapps.dist bin/*.bat; \
    mkdir -p webapps; mv /build/geoserver webapps/geoserver; \
    sed -i 's|<Server port="8005"|<Server port="-1"|' conf/server.xml; \
    sed -i 's|<Connector port="8080"|<Connector port="8080" server="GeoServer" xpoweredBy="false"|' conf/server.xml; \
    sed -i 's|</Host>|  <Valve className="org.apache.catalina.valves.ErrorReportValve" showReport="false" showServerInfo="false"/>\n      </Host>|' conf/server.xml; \
    grep -q 'port="-1"' conf/server.xml && grep -q showServerInfo conf/server.xml

############################################################################
# Stage 3: runtime
############################################################################
FROM ${BASE_IMAGE} AS runtime
ARG GS_UID=10001
ARG GS_VERSION
LABEL org.opencontainers.image.title="geoserver-fips" \
      org.opencontainers.image.version="${GS_VERSION}" \
      org.opencontainers.image.description="Hardened GeoServer with FIPS, cog-s3, cog-http on Rocky Linux 9"

# Patch the whole base image first: the digest-pinned base is only as fresh as when it was published.
RUN dnf -y upgrade --refresh \
 && dnf -y install --setopt=install_weak_deps=False \
        java-21-openjdk-headless nss openssl-libs fontconfig freetype dejavu-sans-fonts crypto-policies-scripts \
 && update-crypto-policies --set FIPS \
 && dnf -y remove crypto-policies-scripts \
 && dnf clean all && rm -rf /var/cache/dnf /var/log/dnf* \
 && (find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true)

ENV CATALINA_HOME=/opt/tomcat \
    GEOSERVER_DATA_DIR=/opt/geoserver_data \
    JAVA_HOME=/usr/lib/jvm/jre-21-openjdk

RUN useradd --system --uid ${GS_UID} --gid 0 --no-create-home --home-dir /opt/tomcat --shell /sbin/nologin geoserver \
 && mkdir -p ${GEOSERVER_DATA_DIR}

COPY --from=assemble --chown=${GS_UID}:0 /build/tomcat ${CATALINA_HOME}
RUN chown -R ${GS_UID}:0 ${GEOSERVER_DATA_DIR} \
 && chmod -R g=u ${CATALINA_HOME}/conf ${CATALINA_HOME}/logs ${CATALINA_HOME}/temp ${CATALINA_HOME}/work ${GEOSERVER_DATA_DIR} \
 && chmod -R go-w ${CATALINA_HOME}/bin ${CATALINA_HOME}/lib ${CATALINA_HOME}/webapps

# Do NOT set -Dorg.bouncycastle.fips.approved_only=false; the FIPS module turns approved-only on.
# hs_err logs land in Tomcat logs so a JVM crash leaves evidence (mount /opt/tomcat/logs if you want them off-container)
ENV JAVA_OPTS="-Djava.awt.headless=true -XX:MaxRAMPercentage=75 -Dfile.encoding=UTF-8 -XX:ErrorFile=/opt/tomcat/logs/hs_err_pid%p.log"

USER ${GS_UID}
WORKDIR ${CATALINA_HOME}
VOLUME ["/opt/geoserver_data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD ["/bin/bash","-c","exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /geoserver/web/ HTTP/1.0\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -Eq ' (200|302) '"]

STOPSIGNAL SIGTERM
ENTRYPOINT []
CMD ["/opt/tomcat/bin/catalina.sh", "run"]