# Pilot backend deployment and phone connection

Recommended first host: an Ubuntu 24.04 LTS VPS with 2 vCPU, 4 GB RAM and at least
40 GB SSD, for example a DigitalOcean Droplet. This is a starting size for a small
pilot; actual capacity depends on concurrent recordings, site count and audio
retention. AI runs in Gemini/Groq, so a GPU is unnecessary. Check the provider's
current price before provisioning. Hosting has not been purchased or provisioned.

The API container runs without root privileges. PostgreSQL has no published port;
the API binds only to host loopback. The optional Caddy service provides public
HTTPS. PostgreSQL, private audio and TLS state use separate persistent volumes.

## Before deploying

You need a VPS with Docker Engine and Compose v2, SSH access, a DNS hostname you
control (for example `fieldops.your-company-domain.com`), and Gemini/Groq keys.
Point its DNS A record at the VPS's public IPv4 address. Add AAAA only if IPv6 is
actually configured. Allow inbound TCP 80 and 443, and restrict SSH to your admin
IP where practical. Keep 5432 and 8000 closed to the Internet. Do not open ports on
this development workspace as a substitute for a durable deployment.

Transfer the project to the VPS using a private repository or SSH/SFTP. Exclude
`.venv`, Flutter build outputs, `.env` files and local customer databases. The
Docker context allowlist copies only the locked requirements and backend source.

From the project root on the VPS:

```sh
python3 deploy/setup_env.py --host fieldops.your-company-domain.com
# Use a private editor to fill SMARTIVA_GEMINI_API_KEY and SMARTIVA_GROQ_API_KEY.
nano deploy/.env
cd deploy
docker compose config --quiet
docker compose --profile edge up --detach --build
```

Do not paste keys into chat, commit `.env`, or print `docker compose config` without
`--quiet`: expanded configuration contains secrets. Keep the generated PostgreSQL
password on subsequent deployments. Changing POSTGRES_PASSWORD in `.env` does not
change the password inside an existing database volume. Back up `.env` privately.

`init` initializes missing tables/history without resetting inventory, then exits.
The API starts after initialization. Caddy obtains/renews a trusted TLS certificate
for the DNS hostname. DNS and public inbound access must work for certificate
issuance. Do not bypass certificate checks or replace HTTPS with public HTTP.

Verify from another network:

```sh
curl --fail https://fieldops.your-company-domain.com/healthz
curl --fail https://fieldops.your-company-domain.com/readyz
```

`healthz` means the API process responds. `readyz` requires the PostgreSQL schema,
a writable audio volume and configured provider keys. It returns generic HTTP 503
when not ready. It does not make provider calls or confirm API-key validity, quota,
model access or Tamil transcription quality; those need the real phone test.

## Provision the Moto and connect

Run this privately from the VPS's `deploy` directory:

```sh
docker compose exec api python -m app.manage issue-device \
  --technician 'Field Engineer' --label 'Moto Edge 60 Fusion'
```

This prints a new device token once. Keep it private. It is different from the
internal SMARTIVA_API_TOKEN and from Gemini/Groq keys; provider keys stay on the
server. Follow [mobile/ANDROID_TESTING.md](../mobile/ANDROID_TESTING.md) for the
existing app's connection settings. Enter the HTTPS origin (no `/api/v1` suffix)
and this device token, then save/connect. The current 0.5.1 app supports these
settings; no new APK is needed for this backend stage.

The phone is bound to its server/device identity to prevent accidental cross-server
sync. If it already has a different binding, preserve local notes and resolve that
binding intentionally; do not uninstall or clear storage to switch servers.

On first connection the phone pushes locally created sites first, granting its
technician access. It then processes pending AI briefings and uploads voice files.
A green network icon alone does not establish server readiness or authorization.

## Phone acceptance test

1. Confirm the existing Rajrelax text and voice note survive reopening.
2. Connect to the provisioned backend. Tap sync/retry and wait for pending jobs.
3. Text: `Dahua la 16 ch NVR one, Dahua 32 ch NVR one`. Confirm the AI returns two
   recorders with capacities 16 and 32, and asks about missing camera/floor/switch
   details. Capacity alone must not imply 48 installed cameras.
4. Record Tamil/Tanglish speech, confirm transcription and the next question.
5. Review the extracted inventory before applying it. Sync again and confirm the
   inventory appears through the authenticated server change API.
6. Disable internet, save a new note/recording, reopen, restore internet and confirm
   queued work drains without duplicated sites/assets.

Real AI calls consume provider quota and send the technician's briefing to the
configured provider. First test with non-sensitive sample details. Do not speak
NVR passwords or API keys into a briefing.

## Updates, persistence and backups

After source changes, run `docker compose --profile edge up --detach --build`.
Keep the same `.env` and named volumes. `docker compose down` preserves named
volumes; never add `--volumes` to a production teardown. Future schema alterations
need explicit reviewed migrations; init-db only creates missing tables/history.

Before pilot data becomes business-critical, schedule encrypted off-server backups
and verify a restore. For a consistent maintenance-window backup, stop the API
and avoid operator writes while taking both the PostgreSQL dump and audio archive:

```sh
umask 077
mkdir -p backups
# Pause phone traffic and operator provisioning during this window.
docker compose stop api
docker compose exec -T db pg_dump -U smartiva -d smartiva -Fc > backups/database.dump
docker compose run --rm --no-deps -T api python -c \
  'import sys,tarfile; t=tarfile.open(fileobj=sys.stdout.buffer,mode="w|gz"); t.add("/var/lib/smartiva/audio",arcname="audio"); t.close()' \
  > backups/audio.tar.gz
docker compose start api
```

If a command fails, restart the API after investigating; preserve partial backup
files separately. Copy completed backups and `.env` securely off the VPS, timestamp
each backup set, and apply an appropriate retention policy. Restore only into a
separate test deployment first; verify authenticated site access and voice checksums.
Do not expose the audio volume or backups through Caddy.

## Local validation versus live deployment

The development workspace can build the image and test disposable PostgreSQL,
device authentication, sync, audio persistence and mocked AI output. It does not
supply your public hostname, persistent production hosting or provider keys.
Actual DNS/TLS and live Gemini/Groq calls remain pending until those are configured.
