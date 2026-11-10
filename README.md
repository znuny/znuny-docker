# Znuny Docker Setup

> **Experimental** — This Docker setup is under active development and not yet ready for production use. The upgrade process is still incomplete and may require manual intervention. Use at your own risk.

## Architecture

The setup consists of three containers, two of them built from a shared base image:

| Image/Container | Name          | Role                                      |
|-----------------|---------------|-------------------------------------------|
| `znuny-base`    | (build only)  | Shared base image: OS, Perl modules, Znuny source files |
| `znuny-daemon`  | `znuny_daemon`| Znuny daemon                              |
| `znuny-httpd`   | `znuny_httpd` | Apache web server                         |
| `znuny-db`      | `znuny_db`    | MariaDB database                          |

The daemon and Apache Dockerfiles both extend the `znuny-base` image, which contains all common packages and application files. The daemon and web server containers share the application directory (`/opt/znuny`) via a Docker volume. The Apache (httpd) container owns the application lifecycle (installation, upgrades, add-on registration) so the daemon can be stopped without taking down the web tier.

An optional Traefik override (`docker-compose.traefik.yml`) adds TLS termination with automatic Let's Encrypt certificates.

## Volumes

| Volume            | Container Mount Path   | Purpose                              |
|-------------------|------------------------|--------------------------------------|
| `ZnunyApp`        | `/opt/znuny`           | Shared application directory         |
| `ZnunyPersistent` | `/persistent`          | Persistent config and version state  |
| `MariaDBVol`      | `/var/lib/mysql`       | MariaDB data                         |
| `TraefikCerts`    | `/certs`               | Let's Encrypt certificates (Traefik only) |

## Files and Paths

### Repository Layout

| Path                                  | Purpose                                            |
|---------------------------------------|----------------------------------------------------|
| `docker-compose.yml`                  | Service definitions and volume config              |
| `docker-compose.traefik.yml`          | Traefik reverse proxy override (TLS/HTTPS)         |
| `.env.example`                        | Example environment file with all variables        |
| `dockerfiles/base`                    | Dockerfile for the shared base image               |
| `dockerfiles/daemon`                  | Dockerfile for the daemon container (extends base) |
| `dockerfiles/apache`                  | Dockerfile for the web server container (extends base) |
| `entrypoints/daemon.sh`              | Daemon container entrypoint                        |
| `entrypoints/apache.sh`              | Apache container entrypoint                        |
| `docker-specific/watchdog.sh`        | Daemon process supervisor and restart trigger watcher |
| `docker-specific/apache_starter.sh`  | Apache process supervisor and restart trigger watcher |
| `docker-specific/install.sh`         | Initial installation script (runs on first start)  |
| `docker-specific/upgrade.sh`         | Upgrade script (runs when version changes)         |

### Inside the Daemon Container

| Path                        | Purpose                                                    |
|-----------------------------|------------------------------------------------------------|
| `/opt/znuny`                | Application directory (shared volume, symlink to `/opt/znuny-<VERSION>`) |
| `/persistent/Config.pm`     | Persistent Znuny configuration file                        |
| `/persistent/version`       | Installed version number (format: `MAJOR.MINOR.PATCH`)    |
| `/persistent/restart-daemon`| Trigger file: when present, watchdog restarts the daemon   |
| `/persistent/restart-httpd` | Trigger file: when present, Apache watcher restarts httpd  |
| `/usr/local/bin/entrypoint.sh` | Entrypoint script                                       |
| `/usr/local/bin/watchdog.sh`   | Daemon supervisor (CMD)                                 |

### Inside the Apache Container

| Path                             | Purpose                                          |
|----------------------------------|--------------------------------------------------|
| `/opt/znuny`                     | Application directory (shared volume)            |
| `/opt/znuny-staging`             | Staging copy of the application (baked into the image, used by `upgrade.sh` to sync updates into the shared volume) |
| `/persistent/Config.pm`          | Persistent Znuny configuration file              |
| `/usr/local/bin/entrypoint.sh`   | Entrypoint script                                |
| `/usr/local/bin/apache_starter.sh` | Apache supervisor with restart trigger watcher |
| `/usr/local/bin/install.sh`      | Installation script                              |
| `/usr/local/bin/upgrade.sh`      | Upgrade script                                   |

## Script Details

### `entrypoints/apache.sh`

Runs at Apache container startup. The httpd container owns the application lifecycle, so install/upgrade happens here before Apache is started:

1. Sets up `Config.pm` from persistent storage; on first run, configures the DB connection from environment variables
2. Sets file permissions
3. Detects installation state:
   - **First run** (no `/persistent/version`): runs `install.sh`, writes version file
   - **Version mismatch**: determines update type (`major`, `minor`, or `patch`), runs `upgrade.sh` with `INSTALLED_VERSION`, `NEW_VERSION`, and `UPDATE_TYPE` exported, writes new version
   - **Same version**: no action
4. Creates Apache Znuny config symlink if not present
5. Configures default interface redirect (agent or customer)
6. Hands off to CMD (`apache_starter.sh`); Apache itself starts as root and drops worker processes to `www-data`

### `entrypoints/daemon.sh`

Runs at daemon container startup. The daemon depends on the httpd service being healthy, which means install/upgrade has already completed:

1. Verifies the persistent `Config.pm` exists and ensures the symlink is in place (fails fast if httpd has not been started yet)
2. Ensures `var/tmp` exists on the shared volume with correct ownership
3. Hands off to CMD (`watchdog.sh`) as the `znuny` user

### `docker-specific/watchdog.sh`

Main process of the daemon container:

1. Checks Perl modules
2. Starts the Znuny daemon
3. Loops every 30 seconds:
   - Checks for `/persistent/restart-daemon` trigger file; if found, restarts the daemon and deletes the trigger
   - Monitors daemon health; exits the container after 5 minutes of consecutive failures

### `docker-specific/apache_starter.sh`

Main process of the Apache container:

1. Starts Apache in the background
2. Loops every 30 seconds:
   - Checks if Apache is still running; exits container if not
   - Checks for `/persistent/restart-httpd` trigger file; if found, runs `apachectl graceful` and deletes the trigger

### `docker-specific/install.sh`

Runs from the httpd entrypoint on first startup when no `/persistent/version` exists. Imports the database schema, rebuilds the configuration, enables SecureMode, sets a random SystemID, and sets the initial admin password from the `ZNUNY_ADMIN_PASS` environment variable.

### `docker-specific/upgrade.sh`

Runs from the httpd entrypoint when the image version differs from `/persistent/version`. Receives the following environment variables:

- `INSTALLED_VERSION` - previous version
- `NEW_VERSION` - version from the new image
- `UPDATE_TYPE` - one of `major`, `minor`, or `patch`

Syncs application files from `/opt/znuny-staging` into the shared volume via `rsync`, excluding runtime data (`var/tmp/`, `var/log/`, `var/article/`, `var/sessions/`, `var/httpd/htdocs/custom/`, `Kernel/Config.pm`).

## Environment Variables

Copy `.env.example` to `.env` and fill in the required values before starting:

```bash
cp .env.example .env
```

### Required

| Variable            | Purpose                          |
|---------------------|----------------------------------|
| `ROOT_PASS`         | MariaDB root password            |
| `DB_USER_PASS`      | Database user password           |
| `ZNUNY_ADMIN_PASS`  | Initial Znuny admin password     |

### Optional

| Variable               | Default      | Purpose                          |
|------------------------|--------------|----------------------------------|
| `CONTAINER_REGISTRY`   | `znuny`      | Container registry prefix (see below) |
| `ZNUNY_IMAGE_TAG`      | `latest`     | Image tag to pull (`latest`, `stable`, branch name) |
| `DB_HOST`              | `znuny-db`   | Database hostname                |
| `DB_NAME`              | `znuny`      | Database name                    |
| `DB_USER`              | `znuny`      | Database user                    |
| `MARIADB_VERSION`      | `11.4.7`     | MariaDB image tag                |
| `ZNUNY_DAEMON_MEMLIMIT`| `2048m`     | Memory limit for daemon          |
| `ZNUNY_DAEMON_CPUS`   | `2`          | CPU limit for daemon             |
| `ZNUNY_HTTPD_MEMLIMIT` | `1024m`     | Memory limit for Apache          |
| `ZNUNY_HTTPD_CPUS`    | `2`          | CPU limit for Apache             |
| `ZNUNY_DB_MEMLIMIT`   | `2048m`      | Memory limit for MariaDB         |
| `ZNUNY_DB_CPUS`      | `2`          | CPU limit for MariaDB            |
| `external_port`        | `80`         | Exposed HTTP port on host        |
| `DEFAULT_INTERFACE`    | `agent`      | Default web interface: `agent` or `customer` |

### Traefik (only with `docker-compose.traefik.yml`)

| Variable            | Purpose                          |
|---------------------|----------------------------------|
| `ZNUNY_DOMAIN`      | Domain name for the Znuny instance (required) |
| `ACME_EMAIL`        | Email for Let's Encrypt registration (required) |

### Build Arguments

| Argument          | Default  | Purpose                                      |
|-------------------|----------|----------------------------------------------|
| `ZNUNY_VERSION`   | `7.3.1`  | Znuny version to download and install        |

Supported values for `ZNUNY_VERSION`:

- Release version (e.g. `7.3.1`): downloads from `https://download.znuny.org/releases/znuny-<version>.tar.gz`
- `nightly`: downloads the latest nightly build
- `lts-nightly`: downloads the latest LTS nightly build

## Usage

### Pulling Pre-built Images

To use pre-built images from a registry instead of building locally, set `CONTAINER_REGISTRY` in your `.env`:

```env
# GitHub Container Registry
CONTAINER_REGISTRY=ghcr.io/znuny/znuny-docker
ZNUNY_IMAGE_TAG=stable
```

Then start without `--build`:

```bash
docker compose up -d
```

To build locally instead, leave `CONTAINER_REGISTRY` at the default (`znuny`) and use `--build`:

```bash
docker compose up -d --build
```

### Building and Starting the Stack

All images (base, daemon, Apache) are built automatically in the correct order:

```bash
docker compose up -d --build
```

To build with a specific Znuny version, set the build arg on the base service:

```bash
docker compose build --build-arg ZNUNY_VERSION=7.3.1 znuny-base
docker compose up -d --build
```

To build with a nightly version:

```bash
docker compose build --build-arg ZNUNY_VERSION=nightly znuny-base
docker compose up -d --build
```

### Upgrading Znuny

When the httpd container starts, the entrypoint compares the version stored in `/persistent/version` against the version baked into the new image. If they differ, it runs `upgrade.sh` automatically before Apache starts. The daemon container waits for httpd to be healthy, so it only starts after the upgrade completes.

**Local build:**

```bash
docker compose build --build-arg ZNUNY_VERSION=7.3.2 znuny-base
docker compose up -d --build
```

**Pre-built images from a registry:**

Set `ZNUNY_IMAGE_TAG` to the new version in `.env`:

```env
CONTAINER_REGISTRY=ghcr.io/znuny/znuny-docker
ZNUNY_IMAGE_TAG=7.3.2
```

Then pull and restart:

```bash
docker compose pull
docker compose up -d
```

### Starting with Traefik (HTTPS)

```bash
docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d --build
```

This adds a Traefik reverse proxy that:
- Terminates TLS with automatic Let's Encrypt certificates
- Redirects HTTP to HTTPS
- Replaces the direct port mapping on `znuny-httpd`

### Using an External Database

To connect to an existing database instead of the bundled MariaDB container, use the `docker-compose.external-db.yml` override. Set the connection details in `.env`:

```env
DB_HOST=db.example.com
DB_NAME=znuny
DB_USER=znuny
DB_USER_PASS=secret
ROOT_PASS=unused  # required by the base file but not used
```

Then start with both compose files:

```bash
# Local build
docker compose -f docker-compose.yml -f docker-compose.external-db.yml up -d --build

# Pre-built images
docker compose -f docker-compose.yml -f docker-compose.external-db.yml up -d
```

The `znuny-db` container is replaced by a lightweight dummy that satisfies the internal health check dependency without running MariaDB. The database schema is imported automatically on first start by `install.sh`, the same as with the local database.

### Stopping the Stack

```bash
docker compose down
```

### Running znuny.Console.pl

Execute console commands via the daemon container:

```bash
docker exec -u znuny znuny_daemon /opt/znuny/bin/znuny.Console.pl <Command> [options]
```

Examples:

```bash
# List available commands
docker exec -u znuny znuny_daemon /opt/znuny/bin/znuny.Console.pl List

# Install an add-on from a repository
docker exec -u znuny znuny_daemon /opt/znuny/bin/znuny.Console.pl Admin::Package::Install <url>

# Rebuild the system configuration
docker exec -u znuny znuny_daemon /opt/znuny/bin/znuny.Console.pl Maint::Config::Rebuild

# Delete the cache
docker exec -u znuny znuny_daemon /opt/znuny/bin/znuny.Console.pl Maint::Cache::Delete
```

### Database Backup with mysqldump

Using environment variables from `.env`:

```bash
source .env
docker exec znuny_db mysqldump -u "$DB_USER" -p"$DB_USER_PASS" "$DB_NAME" > backup.sql
```

To create a compressed backup:

```bash
source .env
docker exec znuny_db mysqldump -u "$DB_USER" -p"$DB_USER_PASS" "$DB_NAME" | gzip > backup_$(date +%Y%m%d_%H%M%S).sql.gz
```

### Restoring a Database Backup

```bash
source .env
docker exec -i znuny_db mysql -u "$DB_USER" -p"$DB_USER_PASS" "$DB_NAME" < backup.sql
```

## CI/CD

The `.gitlab-ci.yml` pipeline builds and pushes all three images to the GitLab Container Registry in two stages:

1. **`build_base`** — Builds the `znuny-base` image
2. **`build_images`** — Builds `znuny-daemon` and `znuny-httpd` in parallel

Images are pushed to:
- `<registry>/znuny-base`
- `<registry>/znuny-daemon`
- `<registry>/znuny-httpd`

Branch pushes are tagged with the branch name. Pushes to `master` are tagged `stable` and `latest`.

The `ZNUNY_VERSION` build argument can be set as a CI/CD variable to control which Znuny version is baked into the image.

## Cron Jobs

Linux cron is not used in this Docker setup. The Znuny daemon manages all scheduled tasks internally via its own task worker system (Znuny Cron tasks). These can be configured in the Znuny system configuration under `Daemon::SchedulerCronTaskManager::Task`.

## Restart Trigger Mechanism

After installing or removing add-ons, the daemon and web server processes need to be restarted. This is handled via trigger files on the shared `/persistent` volume:

- `/persistent/restart-daemon` - triggers a daemon restart (checked every 30s)
- `/persistent/restart-httpd` - triggers an Apache graceful restart (checked every 30s)

A custom Znuny add-on hooks into the package manager to create these trigger files automatically after package install/upgrade/uninstall operations.

To trigger restarts manually:

```bash
docker exec -u znuny znuny_daemon touch /persistent/restart-daemon /persistent/restart-httpd
```

## License

Copyright (C) 2021 Znuny GmbH, https://znuny.org/

This project is licensed under the GNU General Public License v3.0 or later (`GPL-3.0-or-later`). See [LICENSE](LICENSE) for the full text.
