# AGENTS.md

Operational guidance for AI coding agents and autonomous workflows interacting with the Call Telemetry storefront and deployment repository.

Follows the open [agents.md format](https://github.com/agentsmd/agents.md).

---

## 1. System Role & Architecture

Call Telemetry is a carrier-grade telephony policy engine, real-time tool suite, and analytics platform for Cisco Unified Communications Manager (CUCM / CallManager).

### Key Subsystems
- **Policy Engine (CURRI / ECC)**: Evaluates incoming calls in real-time (<20ms) to block spam, inject announcements/greetings, or route calls via Cisco External Call Control.
- **TrueSpam Reputation**: Real-time scoring (0–100) and automated blocking/tagging of robocalls.
- **Phone Dashboard & Remote Control**: Device discovery, firmware inventory, switch port CDP/LLDP neighbors, and browser-based remote control of Cisco IP Phones.
- **CDR & CMR Analytics**: High-volume call detail record ingestion, low-duration spam hunting, and voice quality (MOS/jitter) reporting on TimescaleDB.
- **JTAPI Sidecar**: Java-based CTI sidecar communicating via NATS for announcement playback, BIB call recording, and active call monitoring.

### Repository Boundary
- **This Repo (`calltelemetry/calltelemetry`)**: Public storefront, customer distribution, documentation entrypoint, and reference deployment manifests.
- **Private Release Engine (`calltelemetry/ct-release`)**: Source of truth for compiled Go CLI binaries, appliance packaging, version manifests, and internal CI/CD release trains.
- **Do not attempt to rebuild internal appliance plumbing**: Always use the official distribution scripts rather than stitching together private container internals.

---

## 2. Getting Started (Deployment & Bootstrap)

### Option A: Turnkey VMware OVA Appliance (Fastest)
The OVA appliance is a pre-configured, hardened AlmaLinux 9 image with all dependencies, systemd services, and storage pre-configured.
- **Download Page**: [https://docs.calltelemetry.com/download](https://docs.calltelemetry.com/download)
- **Deployment Guide**: [https://docs.calltelemetry.com/deployment/ova.html](https://docs.calltelemetry.com/deployment/ova.html)

### Option B: Bring Your Own OS (Automated Linux / Docker Script)
For deployment on a fresh Linux server (Ubuntu, Debian, AlmaLinux, Rocky):

```bash
# 1. Download CLI and prepare host (installs Docker CE, required paths, and systemd service)
# Note: In automated/headless environments, set CT_NONINTERACTIVE=1 to auto-apply SSH port 2222
curl -fsSL https://get.calltelemetry.com | sudo CT_NONINTERACTIVE=1 sh -s -- build-appliance

# 2. Check appliance and container status
sudo ct status

# 3. Deploy or update to latest stable release
curl -fsSL https://get.calltelemetry.com | sudo sh -s -- update --stable --yes
```

### Option C: Advanced Manual Docker Compose
For homelabs or custom environments managing raw containers directly:
```bash
cp .env.example .env
# Edit .env with your domain name and credentials
docker compose up -d
```

---

## 3. Appliance CLI Commands (`ct`)

When operating on an installed host or appliance, always prefer the `ct` CLI over raw container commands:

| Command | Purpose |
| :--- | :--- |
| `ct status` | Display container status, versions, uptime, and database health |
| `ct start` | Start all Call Telemetry services |
| `ct stop` | Gracefully stop all services |
| `ct restart` | Restart all services |
| `ct update stable` | Pull and apply the latest stable release bundle |
| `ct logs [service]` | View logs (e.g. `ct logs web`, `ct logs db`, `ct logs caddy`) |
| `ct backup` | Create a full appliance database backup |
| `ct reclaim-disk` | Safely identify and prune historical call records if disk is full |
| `ct build-appliance` | Run host preparation script (`prep.sh`) |

---

## 4. Service Topology & Port Reference

| Service | Internal Port | Host Port | Purpose |
| :--- | :--- | :--- | :--- |
| `caddy` | `80`, `443` | `80`, `443` | Reverse proxy gateway, SSL termination, Web UI routing |
| `web` (Phoenix) | `4000` | — | Internal backend API, administration, WebSocket channels |
| `web` (CURRI) | `4080` | `4080` | Real-time Cisco CURRI policy evaluation & health check |
| `vue-web` | `8080` | — | Modern responsive dashboard web interface |
| `db` (TimescaleDB) | `5432` | `5432` | PostgreSQL 14/16 database with time-series chunking |
| `nats` | `4222` | `4222` | JetStream message broker for asynchronous event processing |
| `seaweedfs` | `8333` | `8333` | S3-compatible object storage for audio files and reports |
| `ct-syslog-ingest` | `514` | `514/udp`, `514/tcp` | Cisco device syslog listener |
| `ct-sftpd` | `3022` | `22` (or `$CT_SFTP_HOST_PORT`) | Secure FTP server for CUCM CDR collection |

---

## 5. Health Verification & Testing

### 1. Endpoint Health Checks
```bash
# Check CURRI / Policy Engine health (returns JSON { "status": "ok" })
curl -sf http://127.0.0.1:4080/healthz

# Check Web UI availability
curl -sfI http://127.0.0.1/
```

### 2. Testing CURRI Policy Evaluation
A ready-to-use sample Cisco CURRI request is provided in `testing/curri.xml`:
```bash
curl -X POST http://127.0.0.1:4080/curri \
  -H "Content-Type: application/xml" \
  --data-binary @testing/curri.xml
```
Expected response: XML policy directive containing `<allow/>` or `<deny/>` action with optional modified calling/called numbers.

---

## 6. Development & Contribution Standards

- **Strict Branding**: Always use **"Call Telemetry"** (two words, capitalized). Never use "CallTelemetry" or "calltelemetry" in user-facing copy.
- **Compose Linting**: All modifications to `docker-compose.yml` must validate against `docker compose config`. A GitHub Actions CI workflow (`.github/workflows/validate.yml`) verifies syntax on PRs.
- **No Secret Leaks**: Never commit `.env`, private keys, license keys, or appliance credentials.
