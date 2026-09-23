# OpenCTI on Docker (Linux)

A single-host OpenCTI stack pinned to **OpenCTI 7.260921.0**, served over HTTPS by Caddy. It is
based on the official [OpenCTI-Platform/docker](https://github.com/OpenCTI-Platform/docker) setup,
minus XTM One and XTM Composer.

| Service | Purpose |
|---|---|
| `caddy` | HTTPS reverse proxy with automatic certificates (ports 80/443) |
| `opencti` | Platform + web UI |
| `worker` ×3 | Ingests bundles from the queue |
| `elasticsearch` | Storage and search |
| `redis` | Cache and event stream |
| `rabbitmq` | Message queue |
| `minio` | S3 storage for files |
| `connector-*` | STIX/CSV/TXT export, STIX/PDF/YARA import, OpenCTI datasets, MITRE ATT&CK |
| `connector-cisa-kev` | CISA Known Exploited Vulnerabilities, refreshed every 2 days |
| `connector-alienvault` | AlienVault OTX pulses every 30 minutes (only when an API key is set) |

Only Caddy is reachable from the network. OpenCTI's plain-HTTP port is bound to
`127.0.0.1:8080` for local debugging. Elasticsearch, Redis, RabbitMQ and MinIO are reachable
only inside the Docker network.

## Requirements

- Linux x86_64 with 16 GB RAM minimum (32 GB recommended), 4+ vCPU, 50 GB+ disk
- Docker Engine 24+ with the Compose v2 plugin (`docker compose`)
- `openssl`, and `sudo` for the kernel setting
- Ports 80 and 443 free on the host

## Install

Pick the certificate type that matches how users reach the server.

**Public domain name → Let's Encrypt certificate.** `cti.example.org` must have a DNS record
pointing at this server, and ports 80 and 443 must be reachable from the internet so that
Let's Encrypt can validate it:

```bash
./setup.sh --host cti.example.org --email you@example.org --start
```

**Internal hostname, IP address or lab → Caddy's own CA:**

```bash
./setup.sh --host opencti.corp.local --internal-tls --start
```

IPs, `localhost` and names without a dot switch to the internal CA automatically.

`setup.sh`:
1. checks Docker, Compose, RAM and whether ports 80/443 are free
2. sets `vm.max_map_count=1048575` (needed by Elasticsearch) and persists it in `/etc/sysctl.d/99-opencti.conf`
3. creates `.env` from `.env.example` with random passwords, tokens, UUIDs and encryption key (mode 600)
4. writes `OPENCTI_HOST` and `CADDY_TLS` (your email, or `internal`)
5. with `--start`: pulls the images and runs `docker compose up -d`

Re-running it is safe. An existing `.env` keeps its secrets. Keys that are missing are added,
and new `--host`/`--email`/`--internal-tls` values are applied.

The first boot takes 3–5 minutes. Until OpenCTI is healthy, Caddy returns 502. Watch it with
`docker compose logs -f opencti caddy`. Then open `https://<host>`. The login is
`admin@opencti.local`, and the password is in `.env` as `OPENCTI_ADMIN_PASSWORD`.

### Trusting the internal CA

With `CADDY_TLS=internal`, browsers show a certificate warning until you trust Caddy's root
certificate. To export it:

```bash
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./opencti-root-ca.crt
```

Install it in the OS or browser trust store, or roll it out via GPO/MDM. The root stays valid for
10 years and lives in the `caddydata` volume. If you delete that volume, you get a new root.

## Operations

```bash
docker compose ps                     # status / health
docker compose logs -f opencti        # platform logs
docker compose logs -f caddy          # certificate issuance / proxy errors
docker compose down                   # stop (data kept in volumes)
docker compose down -v                # stop AND delete all data
```

**Upgrade:** set `OPENCTI_VERSION` in `.env` to the new release, then run
`docker compose pull && docker compose up -d`. Read the release notes first. The platform and
all connectors must stay on the same version.

**Back up:** keep `.env`, above all `OPENCTI_ENCRYPTION_KEY`. Without it, stored secrets cannot
be decrypted. Also back up the `esdata`, `s3data` and `caddydata` volumes. Stop the stack, or use
Elasticsearch snapshots, for a consistent copy.

**Changing the hostname:** run `./setup.sh --host new.example.org --email you@example.org`, then
`docker compose up -d`. Caddy requests the new certificate, and OpenCTI picks up the new base URL.

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

On a 16 GB host, lower the first two, for example `ELASTIC_MEMORY_SIZE=2G` and
`OPENCTI_NODE_MEMORY_MB=4096`.

## Troubleshooting HTTPS

- **Let's Encrypt fails** (`docker compose logs caddy` shows challenge errors). Check that the DNS
  A/AAAA record points at this server and that nothing upstream blocks ports 80/443, such as a
  cloud security group or a NAT that isn't forwarding. Let's Encrypt rate-limits failed attempts,
  so fix the cause before restarting repeatedly.
- **Port 80/443 already in use.** Stop the host's own nginx/apache, or merge this site into that
  proxy and remove the `caddy` service.
- **HSTS is not enabled.** It would lock browsers out of an internal-CA site whose root they don't
  trust. Once you use a Let's Encrypt certificate, you can add
  `Strict-Transport-Security "max-age=31536000"` to the `header` block in the `Caddyfile`.

## Production notes

- **Firewall:** Docker bypasses `ufw`/`firewalld` for published ports. Keep
  `OPENCTI_BIND_ADDRESS=127.0.0.1` so only Caddy (80/443) is exposed.
- **Change the admin password** after the first login, and create personal accounts.
