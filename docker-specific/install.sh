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

ZNUNY_HOME="/opt/znuny"

echo "Running Znuny installation..."

# Add installation steps here
for SQL in schema initial_insert schema-post
do
  mysql -h "${DB_HOST}" -u "${DB_USER}" -p"${DB_USER_PASS}" "${DB_NAME}" < "/opt/znuny/scripts/database/${SQL}.mysql.sql"
done
gosu znuny $ZNUNY_HOME/bin/znuny.Console.pl Maint::Config::Rebuild
gosu znuny $ZNUNY_HOME/bin/znuny.Console.pl Maint::Loader::CacheGenerate
gosu znuny $ZNUNY_HOME/bin/znuny.Console.pl Maint::Log::Clear
gosu znuny $ZNUNY_HOME/bin/znuny.Console.pl Admin::Config::Update --setting-name SecureMode --value 1
gosu znuny $ZNUNY_HOME/bin/znuny.Console.pl Admin::Config::Update --setting-name SystemID --value "$(printf "%02d\n" $((RANDOM % 99 + 1)))"
gosu znuny $ZNUNY_HOME/bin/znuny.Console.pl Admin::Package::Install 'Znuny Open Source Add-ons:Znuny-ContainerHelper'
gosu znuny $ZNUNY_HOME/bin/znuny.Console.pl Maint::Cache::Delete
gosu znuny $ZNUNY_HOME/bin/znuny.Console.pl Admin::User::SetPassword root@localhost "$ZNUNY_ADMIN_PASS"
echo "Installation complete."
