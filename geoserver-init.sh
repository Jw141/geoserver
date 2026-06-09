#!/bin/bash
set -e

# Define standard target configuration paths
USER_CONFIG="${GEOSERVER_DATA_DIR}/security/usergroup/default/users.xml"

# Only attempt modification if the data directory has already been initialized
if [ -f "$USER_CONFIG" ]; then
    
    # Handle Admin Username override if requested
    if [ ! -z "$GEOSERVER_ADMIN_USER" ] && [ "$GEOSERVER_ADMIN_USER" != "admin" ]; then
        echo "Updating administrative username to match environment config..."
        sed -i "s/username=\"admin\"/username=\"${GEOSERVER_ADMIN_USER}\"/g" "$USER_CONFIG"
    fi

    # Handle Admin Password override if requested
    if [ ! -z "$GEOSERVER_ADMIN_PASSWORD" ]; then
        echo "Injecting secure administrative password override..."
        # Note: GeoServer 3.0 accepts plain text injection here on boot, 
        # and will automatically encrypt it on the first successful application initialization pass.
        sed -i "s/password=\"[^\"]*\"/password=\"plain:${GEOSERVER_ADMIN_PASSWORD}\"/g" "$USER_CONFIG"
    fi

fi

# Hand execution back over to the core Tomcat application manager
exec "catalina.sh" "run"