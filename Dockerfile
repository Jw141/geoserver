# ==========================================
# STAGE 1: Process and Flatten Staged Zip Packages Local Context Only
# ==========================================
FROM docker.io/rockylinux/rockylinux:9.7 AS build-stage
WORKDIR /downloads

RUN dnf install -y unzip tar && dnf clean all

# 1. Expand the core GeoServer archive package
COPY geoserver-3.0-RC-war.zip /downloads/
RUN mkdir -p /downloads/geoserver_war /downloads/geoserver && \
    unzip -q geoserver-3.0-RC-war.zip -d /downloads/geoserver_war && \
    unzip -q /downloads/geoserver_war/geoserver.war -d /downloads/geoserver && \
    rm -rf geoserver-3.0-RC-war.zip /downloads/geoserver_war

# Shift context directly into the web application classpath
WORKDIR /downloads/geoserver/WEB-INF/lib

# 2. Copy and unfold your five downloaded stable and community zip packages
COPY geoserver-3.0-*.zip ./
RUN for f in *.zip; do unzip -q -o "$f"; rm -f "$f"; done

# Eliminate alternative cloud platform cross-contamination
RUN rm -f *google* *azure*


# ==========================================
# STAGE 2: Hardened Rocky Linux 9.7 Diagnostic Runtime
# ==========================================
FROM docker.io/rockylinux/rockylinux:9.7

LABEL org.opencontainers.image.title="Hardened GeoServer Enterprise Suite" \
      org.opencontainers.image.description="GeoServer 3.0 on Rocky Linux 9.7 featuring optimized Java performance, native PostGIS mosaic pooling, and integrated telemetry utilities." \
      org.opencontainers.image.vendor="Radix Metasystems"

# 1. Patch systemic vulnerabilities and register enterprise repositories
RUN dnf clean all && \
    dnf update -y --refresh && \
    dnf install -y epel-release && \
    dnf config-manager --set-enabled crb

# 2. Install Java 17 and native diagnostic packages (PostGIS standards)
RUN dnf install -y --allowerasing \
    java-17-openjdk-headless \
    wget \
    tar \
    procps-ng \
    htop \
    iputils \
    less \
    ncurses && \
    dnf clean all

ENV CATALINA_HOME=/usr/local/tomcat
ENV PATH=$CATALINA_HOME/bin:$PATH
WORKDIR /usr/local

# 3. Provision Tomcat 11 for modern Jakarta EE 10 compliance
RUN wget -q https://archive.apache.org/dist/tomcat/tomcat-11/v11.0.0-M20/bin/apache-tomcat-11.0.0-M20.tar.gz && \
    tar -xf apache-tomcat-11.0.0-M20.tar.gz && \
    mv apache-tomcat-11.0.0-M20 $CATALINA_HOME && \
    rm -f apache-tomcat-11.0.0-M20.tar.gz && \
    rm -rf $CATALINA_HOME/webapps/*

# 4. Extract completed web application layer from Stage 1
COPY --from=build-stage /downloads/geoserver $CATALINA_HOME/webapps/geoserver

# 5. Establish core persistent mount zones
RUN mkdir -p /opt/geoserver_data /data/rasters /var/geowebcache

# 6. Inject the administrative initialization script for runtime credential overrides
COPY geoserver-init.sh /usr/local/bin/geoserver-init.sh
RUN chmod +x /usr/local/bin/geoserver-init.sh

# 7. Operational Tuning Parameters
ENV GEOSERVER_DATA_DIR=/opt/geoserver_data
ENV GEOWEBCACHE_CACHE_DIR=/var/geowebcache

ENV CATALINA_OPTS="-Xms4g -Xmx4g \
    -Djava.awt.headless=true \
    -Daws.region=us-east-1 \
    -Daws.s3Endpoint=http://your-internal-s3-cluster.local:9000 \
    -Daws.s3SignerType=AWSS3V4SignerType \
    -DSKIP_DEMO_DATA=true"

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/geoserver-init.sh"]