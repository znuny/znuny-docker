#!/bin/bash
# --
# Copyright (C) 2021 Znuny GmbH, https://znuny.org/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file LICENSE for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# --

set -e

# Vars
external_port="${external_port:-80}"
PERSISTENT_CFG="/persistent/Config.pm"
ZNUNY_CFG="/opt/znuny/Kernel/Config.pm"
ZNUNY_HOME="/opt/znuny"
VERSION_FILE="/persistent/version"

export DB_HOST="${DB_HOST:-znuny-db}"
export DB_NAME="${DB_NAME:-znuny}"
export DB_USER="${DB_USER:-znuny}"
export DB_USER_PASS="${DB_USER_PASS:?DB_USER_PASS must be set}"

# Welcome message
echo "Listening on port ${external_port}"

# Setup persistence
if [ -f "$PERSISTENT_CFG" ]; then
    echo "Using persistent Config.pm"
else
    echo "Persistent Config.pm not found, seeding it"
    cp "$ZNUNY_CFG" "$PERSISTENT_CFG"
fi
ln -sf "$PERSISTENT_CFG" "$ZNUNY_CFG"

# Configure database connection on fresh install (no version file yet)
if [ ! -f "$VERSION_FILE" ]; then
    echo "Configuring database connection in Config.pm"
    grep -qF "\$Self->{DatabaseHost} = '127.0.0.1';" "$PERSISTENT_CFG" \
        || { echo "ERROR: DatabaseHost placeholder not found in Config.pm — template may have changed" >&2; exit 1; }
    sed -i "s/\$Self->{DatabaseHost} = '127\.0\.0\.1';/\$Self->{DatabaseHost} = '$DB_HOST';/" "$PERSISTENT_CFG"
    grep -qF "\$Self->{DatabaseUser} = 'znuny';" "$PERSISTENT_CFG" \
        || { echo "ERROR: DatabaseUser placeholder not found in Config.pm — template may have changed" >&2; exit 1; }
    sed -i "s/\$Self->{DatabaseUser} = 'znuny';/\$Self->{DatabaseUser} = '$DB_USER';/" "$PERSISTENT_CFG"
    grep -qF "\$Self->{Database} = 'znuny';" "$PERSISTENT_CFG" \
        || { echo "ERROR: Database placeholder not found in Config.pm — template may have changed" >&2; exit 1; }
    sed -i "s/\$Self->{Database} = 'znuny';/\$Self->{Database} = '$DB_NAME';/" "$PERSISTENT_CFG"
    grep -qF "\$Self->{DatabasePw} = 'some-pass';" "$PERSISTENT_CFG" \
        || { echo "ERROR: DatabasePw placeholder not found in Config.pm — template may have changed" >&2; exit 1; }
    sed -i "s/\$Self->{DatabasePw} = 'some-pass';/\$Self->{DatabasePw} = '$DB_USER_PASS';/" "$PERSISTENT_CFG"
fi

chown -R znuny:www-data /persistent/Config.pm
chmod -R 770 /persistent/Config.pm

cd "$ZNUNY_HOME"
"$ZNUNY_HOME/bin/znuny.SetPermissions.pl" --znuny-user znuny

# Detect install or upgrade
RELEASE_VERSION=$(grep 'VERSION' "/opt/znuny-staging/RELEASE" 2>/dev/null | head -1 | awk '{print $NF}')
if [ -z "$RELEASE_VERSION" ]; then
    echo "ERROR: could not determine release version from /opt/znuny-staging/RELEASE" >&2
    exit 1
fi

if [ ! -f "$VERSION_FILE" ]; then
    echo "No installation detected, running install script..."
    /usr/local/bin/install.sh
    echo "$RELEASE_VERSION" > "$VERSION_FILE"
    chown znuny:www-data "$VERSION_FILE"
else
    INSTALLED_VERSION=$(cat "$VERSION_FILE")
    if [ "$INSTALLED_VERSION" != "$RELEASE_VERSION" ]; then
        # Parse version components
        INSTALLED_MAJOR=$(echo "$INSTALLED_VERSION" | cut -d. -f1)
        INSTALLED_MINOR=$(echo "$INSTALLED_VERSION" | cut -d. -f2)
        NEW_MAJOR=$(echo "$RELEASE_VERSION" | cut -d. -f1)
        NEW_MINOR=$(echo "$RELEASE_VERSION" | cut -d. -f2)

        if [ "$INSTALLED_MAJOR" != "$NEW_MAJOR" ]; then
            export UPDATE_TYPE="major"
        elif [ "$INSTALLED_MINOR" != "$NEW_MINOR" ]; then
            export UPDATE_TYPE="minor"
        else
            export UPDATE_TYPE="patch"
        fi

        echo "Version change detected: $INSTALLED_VERSION -> $RELEASE_VERSION ($UPDATE_TYPE update)"
        export INSTALLED_VERSION
        export NEW_VERSION="$RELEASE_VERSION"
        gosu znuny /usr/local/bin/upgrade.sh
        echo "$RELEASE_VERSION" > "$VERSION_FILE"
        chown znuny:www-data "$VERSION_FILE"
    else
        echo "Znuny $RELEASE_VERSION already installed, no action needed."
    fi
fi

# Setup Apache Znuny config (shared volume is now available)
if [ ! -f /etc/apache2/conf-available/zzz_znuny.conf ]; then
    ln -s /opt/znuny/scripts/apache2-httpd.include.conf /etc/apache2/conf-available/zzz_znuny.conf
    a2enconf zzz_znuny
fi

# Set default interface redirect
DEFAULT_INTERFACE="${DEFAULT_INTERFACE:-agent}"
if [ "$DEFAULT_INTERFACE" = "customer" ]; then
    DEFAULT_PAGE="customer.pl"
else
    DEFAULT_PAGE="index.pl"
fi
sed -i "s|URL=/znuny/[a-z_]*\.pl|URL=/znuny/${DEFAULT_PAGE}|" /opt/znuny/var/httpd/htdocs/index.html

# Move to Main process
# Apache must start as root (to bind port 80 and open log files),
# it drops to www-data for worker processes via APACHE_RUN_USER.
exec "$@"
