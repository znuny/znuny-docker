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

# Znuny upgrade script
# This runs when the image version (from RELEASE) differs from the installed version.
# Syncs updated app files from the staging directory (baked into the image) into
# the shared volume, then runs any additional upgrade steps.
#
# Available variables:
#   INSTALLED_VERSION - the previously installed version (from /persistent/version)
#   NEW_VERSION       - the version from the current image (from RELEASE)

set -e

ZNUNY_HOME="/opt/znuny"
STAGING_DIR="/opt/znuny-staging"

echo "Upgrading Znuny from ${INSTALLED_VERSION} to ${NEW_VERSION}..."

INSTALLED_MAJOR=$(echo "$INSTALLED_VERSION" | cut -d. -f1)
INSTALLED_MINOR=$(echo "$INSTALLED_VERSION" | cut -d. -f2)
NEW_MAJOR=$(echo "$NEW_VERSION" | cut -d. -f1)
NEW_MINOR=$(echo "$NEW_VERSION" | cut -d. -f2)

# Detect skipped minor versions by parsing CHANGES.md.
# Only the migration script for the current image version is available,
# so skipping a minor version would silently miss its schema changes.
CHANGES_FILE="$STAGING_DIR/CHANGES.md"
if [ ! -f "$CHANGES_FILE" ]; then
    echo "ERROR: $CHANGES_FILE not found — cannot verify upgrade path" >&2
    exit 1
fi

SKIPPED=$(grep '^# [0-9]' "$CHANGES_FILE" \
    | sed 's/^# \([0-9]*\)\.\([0-9]*\)\.[0-9]* .*/\1 \2/' \
    | sort -k1,1n -k2,2n -u \
    | while read -r maj min; do
        if { [ "$maj" -gt "$INSTALLED_MAJOR" ] || \
             { [ "$maj" -eq "$INSTALLED_MAJOR" ] && [ "$min" -gt "$INSTALLED_MINOR" ]; }; } && \
           { [ "$maj" -lt "$NEW_MAJOR" ] || \
             { [ "$maj" -eq "$NEW_MAJOR" ] && [ "$min" -lt "$NEW_MINOR" ]; }; }; then
            printf '%s.%s ' "$maj" "$min"
        fi
    done)

if [ -n "$SKIPPED" ]; then
    echo "ERROR: upgrade from $INSTALLED_VERSION to $NEW_VERSION skips minor versions: $SKIPPED" >&2
    echo "ERROR: upgrade step by step through each minor version." >&2
    exit 1
fi

# Sync updated application files into the shared volume
# --delete removes files that no longer exist in the new version
# Excludes runtime data that should be preserved
rsync -a --delete \
    --exclude='var/tmp/' \
    --exclude='var/log/' \
    --exclude='var/article/' \
    --exclude='var/sessions/' \
    --exclude='var/httpd/htdocs/custom/' \
    --exclude='Kernel/Config.pm' \
    "$STAGING_DIR/" "$ZNUNY_HOME/" 2>&1 | grep -v "failed to set times on" || true

MIGRATE_SCRIPT="$ZNUNY_HOME/scripts/MigrateToZnuny${NEW_MAJOR}_${NEW_MINOR}.pl"

if [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "ERROR: migration script not found: $MIGRATE_SCRIPT" >&2
    exit 1
fi

$ZNUNY_HOME/bin/znuny.Console.pl Maint::Cache::Delete
echo "Running migration script: $MIGRATE_SCRIPT"
"$MIGRATE_SCRIPT" --verbose --non-interactive
$ZNUNY_HOME/bin/znuny.Console.pl Admin::Package::ReinstallAll
"$MIGRATE_SCRIPT" --verbose --non-interactive
$ZNUNY_HOME/bin/znuny.Console.pl Maint::Cache::Delete
$ZNUNY_HOME/bin/znuny.Console.pl Maint::Log::Clear
echo "Upgrade complete."
