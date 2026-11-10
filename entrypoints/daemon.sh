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

# Daemon entrypoint. Application install/upgrade is handled by the httpd
# container — by the time this runs, /persistent/Config.pm and
# /opt/znuny are already populated and on the right version.

set -e

PERSISTENT_CFG="/persistent/Config.pm"
ZNUNY_CFG="/opt/znuny/Kernel/Config.pm"
ZNUNY_HOME="/opt/znuny"

# Defensive: ensure the Config.pm symlink is in place. Idempotent — httpd
# normally creates this first, but allows the daemon to run even if httpd
# was started after the volume was wiped.
if [ -f "$PERSISTENT_CFG" ]; then
    ln -sf "$PERSISTENT_CFG" "$ZNUNY_CFG"
else
    echo "ERROR: $PERSISTENT_CFG missing — start the httpd container first to run install." >&2
    exit 1
fi

mkdir -p "$ZNUNY_HOME/var/tmp"
chown znuny:www-data "$ZNUNY_HOME/var/tmp"

cd "$ZNUNY_HOME"

exec gosu znuny "$@"
