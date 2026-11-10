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

set -eu

CHECK_INTERVAL=30
RESTART_TRIGGER="/persistent/restart-httpd"

term_handler() {
    echo "Received termination signal, stopping Apache"
    apachectl stop || true
    exit 0
}

trap term_handler INT TERM

echo "Starting Apache..."
apache2 -DFOREGROUND &
APACHE_PID=$!

echo "Apache watcher started."

while true; do
    if ! kill -0 "$APACHE_PID" 2>/dev/null; then
        echo "Apache process died — exiting container"
        exit 1
    fi

    # Check for restart trigger
    if [ -f "$RESTART_TRIGGER" ]; then
        echo "Restart trigger detected, gracefully restarting Apache..."
        rm -f "$RESTART_TRIGGER"
        apachectl graceful || true
        echo "Apache restarted."
    fi

    sleep "$CHECK_INTERVAL"
done
