#!/bin/sh
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

ZNUNY_HOME="/opt/znuny"
cd "$ZNUNY_HOME"

echo 'Checking modules...'
$ZNUNY_HOME/bin/znuny.CheckModules.pl --all

echo 'Starting Watchdog.'

CHECK_INTERVAL=30   # seconds
MAX_FAILS=10        # 10 × 30s = 5 minutes

FAILS=0
DAEMON="/opt/znuny/bin/znuny.Daemon.pl"
RESTART_TRIGGER="/persistent/restart-daemon"

term_handler() {
    echo "Received termination signal, stopping Znuny"
    perl "$DAEMON" stop || true
    exit 0
}

trap term_handler INT TERM

echo "Znuny supervisor started"
perl "$DAEMON" start || true

while true; do
    # Check for restart trigger
    if [ -f "$RESTART_TRIGGER" ]; then
        echo "Restart trigger detected, restarting Znuny daemon..."
        rm -f "$RESTART_TRIGGER"
        perl "$DAEMON" stop || true
        perl "$DAEMON" start || true
        FAILS=0
        echo "Daemon restarted."
    fi

    if perl "$DAEMON" status | grep -q "Daemon running"; then
        FAILS=0
    else
        FAILS=$((FAILS + 1))
        echo "Znuny not running ($FAILS/$MAX_FAILS)"
    fi

    if [ "$FAILS" -ge "$MAX_FAILS" ]; then
        echo "Znuny down for 5 minutes — exiting container"
        exit 1
    fi

    sleep "$CHECK_INTERVAL"
done
