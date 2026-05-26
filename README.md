# cn-fitness

[SparkyFitness](https://github.com/CodeWithCJ/SparkyFitness) on `kaiser.lan` —
self-hosted fitness/nutrition/exercise tracker. Web at `fitness.kaiser.lan`
(LAN, step-ca cert) and `fitness.lab.gn.al` (tailnet, LE wildcard). Native
Android + iOS apps connect via the tailnet path (stock mobile devices don't
trust step-ca).

This is the 6th cooperating Compose project on kaiser. Closest analogue is
`cn-roms` — same `tag:svc` sidecar pattern with a DB pinned at a static
bridge IP, **but** the subnet is `172.30.1.0/24` (cn-roms owns
`172.30.0.0/24`). No NFS dependency → no systemd-gating.

## Stack

| Service | Image | Net | Port | Purpose |
|---|---|---|---|---|
| `ts-fitness` | `tailscale/tailscale` | kernel TUN | — | Tailnet sidecar (`fitness.ts.gn.al`, `tag:svc`) |
| `sparkyfitness-db` | `postgres:18.3-alpine` | bridge `172.30.1.10` | — | DB. `extra_hosts` doesn't work on `network_mode:service:X` and tailscaled rewrites resolv.conf, so we pin the IP. |
| `sparkyfitness-server` | `codewithcj/sparkyfitness_server` | `service:ts-fitness` | — | Node.js backend, `:3010` inside netns. `DB_HOST=172.30.1.10` (IP, not name). |
| `sparkyfitness-frontend` | `codewithcj/sparkyfitness` | `service:ts-fitness` | `127.0.0.1:3004` | nginx + SPA. Proxies `/api/*` to localhost:3010 (same netns). |
| `consul-register` | curl loop | `service:ts-fitness` | — | Registers `fitness` in VPS Consul → `fitness.lab.gn.al`. |
| `promtail` | `grafana/promtail` | `service:ts-fitness` | — | Logs → VPS Loki, `stack=cn-fitness`. |
| `node-exporter` | `prom/node-exporter` | `service:ts-fitness` | — | Host metrics, scraped as `fitness-node`. |
| `postgres-exporter` | `prometheuscommunity/postgres-exporter` | `service:ts-fitness` | — | DB metrics, scraped as `fitness-postgres`. **Uses superuser** (needs `pg_stat_*`). |
| `pg-dump` | `prodrigestivill/postgres-backup-local:18` | bridge | — | App-consistent dumps every 12h → `./backups/`. |
| `backup` | `offen/docker-volume-backup` | none | — | Weekly tar of `./backups` + `./uploads` → S3 + WebDAV + SMTP. |
| `ts-fitness-watchdog` | `docker:cli` | host socket | — | Recreates dependents on ts-fitness netns drift. |
| `watchtower` | `containrrr/watchtower` | host socket | — | Daily auto-update **with `sparkyfitness-*` images excluded** via `com.centurylinklabs.watchtower.enable=false` (upstream warns against blind upgrades). |

## Setup

```sh
# On kaiser (fresh clone):
git clone git@github.com:GonzaloAlvarez/cn-fitness.git ~/cn-fitness
cd ~/cn-fitness
./setup.sh --core
```

`--core` harvests SMTP/S3/WebDAV/ADMIN_EMAIL and other shared infra values from
`passwords.lan:~/cn-vaultwarden/.env` over SSH (same pattern as
`cn-netbox/seal-secrets.sh --core`). What setup.sh does:

1. Creates `.env` from `.env.example` if missing.
2. (`--core`) harvests shared values from `passwords.lan`.
3. Mints a Headscale preauth key if `FITNESS_AUTHKEY` is empty.
4. Auto-generates random secrets (`SPARKY_FITNESS_API_ENCRYPTION_KEY`,
   `BETTER_AUTH_SECRET`, DB passwords).
5. Fetches the step-ca root CA from `http://pki.lan/cert/ca.crt`.
6. Renders `promtail/promtail.yml` from the template.
7. `docker compose up -d --remove-orphans`.
8. **Auto-creates the admin user** via `POST /api/auth/sign-up/email` with a
   random temporary password, then flips `SPARKY_FITNESS_DISABLE_SIGNUP=true`
   and restarts `sparkyfitness-server` to enforce.
9. **Prints the temp password to stdout exactly once.** Paste it into
   Vaultwarden immediately, then log in at `https://fitness.kaiser.lan` and
   change it.

## Mobile apps

iOS app via TestFlight, Android via Google Play closed testing. Both trust
the LE wildcard cert on `*.lab.gn.al` out of the box. Required setup on the
phone:

1. Install Tailscale Mobile, log in, confirm tailnet connectivity (`tailscale
   ip` → 100.64.x.x).
2. Install SparkyFitness Mobile. In settings, set the server URL to
   `https://fitness.lab.gn.al`.
3. Sign in with the admin email + the password you set after first login.

**Do not** point mobile apps at `fitness.kaiser.lan` — step-ca certs aren't
in the device trust store. Browser-on-laptop is the only supported LAN client.

## Operations

- **Restart**: `docker compose restart sparkyfitness-server` (env reload).
- **Logs**: `docker compose logs -f --tail=100 sparkyfitness-server`.
- **DB shell**: `docker compose exec sparkyfitness-db psql -U $SPARKY_FITNESS_DB_USER -d $SPARKY_FITNESS_DB_NAME`.
- **Backups**:
  - Quick local: tarballs in `./backups/` (kept 14d/8w/6m by pg-dump).
  - Off-site: weekly Sun 03:00 → `s3://cloudnet-lab-storage/fitness/` + `https://raidnas.lan:5005/fitness/`. 56d retention. SMTP notify on success/fail.
- **Upgrades**: do NOT trust watchtower for `sparkyfitness-*` images
  (excluded by label). Check the upstream release notes
  ([CodeWithCJ/SparkyFitness/releases](https://github.com/CodeWithCJ/SparkyFitness/releases))
  before bumping image tags in `docker-compose.yml`. Postgres / exporter
  sidecars are safe to auto-update.

## Gotchas (read these once)

- **Subnet pin**. We use `172.30.1.0/24` because `cn-roms` already owns
  `172.30.0.0/24` on this host. Docker will refuse to bring up overlapping
  bridges.
- **DB hostname**. Any container in `service:ts-fitness` netns must use
  `DB_HOST=172.30.1.10` (IP, not `sparkyfitness-db`) — tailscaled rewrites
  `/etc/resolv.conf` to MagicDNS and `extra_hosts:` doesn't work on
  `network_mode:service:X`. Same constraint as cn-roms.
- **postgres-exporter superuser**. The `DATA_SOURCE_NAME` uses
  `SPARKY_FITNESS_DB_USER` (superuser), not `SPARKY_FITNESS_APP_DB_USER`.
  The limited app role lacks `pg_stat_*` view access and the exporter
  silently emits nothing.
- **Encryption key durability**. `SPARKY_FITNESS_API_ENCRYPTION_KEY`
  encrypts at-rest secrets in the DB. Losing it = unrecoverable OIDC/SMTP
  creds. Mirror it to `~/dev/secrets/` after first generation.
- **Watchtower exclusion**. Labels on the 3 `sparkyfitness-*` containers
  block watchtower from touching them. Bump these tags by hand.
- **Temp password is one-shot**. setup.sh prints it on stdout and never
  writes it to disk. If you miss it: use the SMTP-backed "forgot password"
  flow, or `docker exec` into the DB and replace the bcrypt hash.

## Observability

Wired into VPS observability (cn-root-docker):

- Prometheus scrape jobs `fitness-node` (host) + `fitness-postgres` (DB) +
  `blackbox-tailnet-http` (probe of `https://fitness.lab.gn.al/`).
- Alerts: `TailnetIngressProbeFailed`, `TailnetIngressSlow`,
  `FitnessPostgresDown`, `FitnessNodeDown`.
- Grafana dashboard at `https://grafana.lab.gn.al/d/fitness`.
- Loki: `{stack="cn-fitness"}`.
- Glance bookmark + monitor at `https://home.lab.gn.al`.
- Dashy tile at `https://home.kaiser.lan`.
