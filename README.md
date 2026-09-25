# OpenCTI on Docker (Linux)

A single-host OpenCTI Community Edition stack pinned to **OpenCTI 7.260921.0**, for use on an
**internal network**. OpenCTI serves plain HTTP on port 8080; there is no reverse proxy or TLS.
It is based on the official [OpenCTI-Platform/docker](https://github.com/OpenCTI-Platform/docker)
setup, minus XTM One and XTM Composer.

| Service | Purpose |
|---|---|
| `opencti` | Platform + web UI (port 8080) |
| `worker` ×3 | Ingests bundles from the queue |
| `elasticsearch` | Storage and search |
| `redis` | Cache and event stream |
| `rabbitmq` | Message queue |
| `minio` | S3 storage for files |
| `connector-*` | STIX/CSV/TXT export, STIX/PDF/YARA import, OpenCTI datasets, MITRE ATT&CK |
| `connector-cisa-kev` | CISA Known Exploited Vulnerabilities, refreshed every 2 days |
| `connector-alienvault` | AlienVault OTX pulses every 30 minutes (only when an API key is set) |

Only OpenCTI's port 8080 is published on the host. Elasticsearch, Redis, RabbitMQ and MinIO are
reachable only inside the Docker network.

> **Internal use only.** Logins and API tokens travel unencrypted over HTTP. Keep port 8080
> unreachable from the internet. If the server ever needs outside access, put a TLS reverse
> proxy (nginx, Caddy, Traefik) in front first.

## Requirements

- Linux x86_64 with 16 GB RAM minimum (32 GB recommended), 4+ vCPU, 50 GB+ disk
- Docker Engine 24+ with the Compose v2 plugin (`docker compose`)
- `openssl`, and `sudo` for the kernel setting
- Port 8080 free on the host (or pick another with `OPENCTI_PORT` in `.env`)

## Install

```bash
./setup.sh --start
```

or, to use a DNS name instead of the server's IP:

```bash
./setup.sh --host opencti.corp.local --start
```

`setup.sh`:
1. checks Docker, Compose, RAM and whether port 8080 is free
2. sets `vm.max_map_count=1048575` (needed by Elasticsearch) and persists it in `/etc/sysctl.d/99-opencti.conf`
3. creates `.env` from `.env.example` with random passwords, tokens, UUIDs and encryption key (mode 600)
4. sets `OPENCTI_HOST` to `--host`, or to the server's IP address
5. with `--start`: pulls the images and runs `docker compose up -d`

Re-running it is safe. An existing `.env` keeps its secrets, missing keys are added, and a new
`--host` value is applied.

The first boot takes 3–5 minutes. Watch it with `docker compose logs -f opencti`. Then open
`http://<host>:8080`. The login is `admin@opencti.local`, and the password is in `.env` as
`OPENCTI_ADMIN_PASSWORD`.

`OPENCTI_HOST` must be the name or IP that colleagues type in their browser, because OpenCTI uses
it to build links. To change it later, run `./setup.sh --host <new-name>` and then
`docker compose up -d`.

## Operations

```bash
docker compose ps                     # status / health
docker compose logs -f opencti        # platform logs
docker compose down                   # stop (data kept in volumes)
docker compose down -v                # stop AND delete all data
```

**Upgrade:** set `OPENCTI_VERSION` in `.env` to the new release, then run
`docker compose pull && docker compose up -d`. Read the release notes first. The platform and
all connectors must stay on the same version.

**Back up:** keep `.env`, above all `OPENCTI_ENCRYPTION_KEY`. Without it, stored secrets cannot
be decrypted. Also back up the `esdata` and `s3data` volumes. Stop the stack, or use
Elasticsearch snapshots, for a consistent copy.

## Threat feeds

**CISA KEV** runs out of the box. It needs no key.

**AlienVault OTX** stays off until you add a free API key:

1. Create an account at https://otx.alienvault.com and copy the key from *Settings → API Integration*.
2. Put it in `.env` as `ALIENVAULT_API_KEY=<key>`. Keep it out of the command line, so it
   doesn't end up in your shell history.
3. Run `./setup.sh`, then `docker compose up -d`.

`setup.sh` then turns on the `alienvault` compose profile. The first import covers the last
30 days (`ALIENVAULT_PULSE_START_TIMESTAMP`) instead of the connector's 2020 default. The
connector imports pulses from the OTX users you subscribe to. A new account follows AlienVault
itself. To turn the connector off again, empty the key, re-run `./setup.sh`, and run
`docker compose rm -sf connector-alienvault`.

Connectors that fetch feeds need outbound internet access (HTTPS) from the server. No inbound
ports are needed.

**More feeds:** add a service per connector from
[OpenCTI-Platform/connectors](https://github.com/OpenCTI-Platform/connectors). Give each one a
`CONNECTOR_<NAME>_ID=CHANGEME` line in `.env.example` (`setup.sh` fills it with a UUID) and the
image tag `${OPENCTI_VERSION}`. In the Community Edition, connectors are managed here in
compose. OpenCTI's in-app Integration Manager, which uses XTM Composer, needs an Enterprise
license. Without one, its catalog is read-only.

## Tuning

| `.env` variable | Default | Notes |
|---|---|---|
| `ELASTIC_MEMORY_SIZE` | `4G` | ES heap; ~50% of RAM given to ES, max 31G |
| `OPENCTI_NODE_MEMORY_MB` | `8096` | Node.js heap for the platform |
| `OPENCTI_WORKER_REPLICAS` | `3` | More workers = faster ingestion |
| `OPENCTI_PORT` | `8080` | Port OpenCTI is published on |

On a 16 GB host, lower the first two, for example `ELASTIC_MEMORY_SIZE=2G` and
`OPENCTI_NODE_MEMORY_MB=4096`.

## Notes

- **Firewall:** Docker bypasses `ufw`/`firewalld` for published ports. To limit who on the
  internal network can reach port 8080, use the `DOCKER-USER` iptables chain or a network firewall.
- **Browser:** the Home dashboard's map needs WebGL2. If you see "An unknown error occurred"
  there, turn on hardware acceleration in the browser.
- **Change the admin password** after the first login, and create personal accounts.
