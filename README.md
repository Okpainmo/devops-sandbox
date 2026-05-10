# devops-sandbox

`devops-sandbox` is a single-VM self-service platform for short-lived Docker environments. Users can create an isolated environment, reach it through Nginx, inspect logs and health checks, simulate outages, recover, and destroy everything manually or by TTL.

The bundled workload is a tiny Python HTTP app. The platform behavior is the point: lifecycle automation, routing, log shipping, health monitoring, chaos controls, and an API wrapped around the same scripts used by `make`.

## Architecture

```text
                           operator
                   make targets or curl API
                             |
                             v
                  FastAPI control API :5000
                             |
            +----------------+----------------+
            |                |                |
            v                v                v
   lifecycle scripts   outage script    envs/<id>.json
 create / destroy     crash / pause     atomic state
            |                |
            v                v
       Docker daemon with labels: sandbox.env=<env-id>
            |
            +--> app container: sandbox-<env-id>
            |    labels: sandbox.env=<env-id>, sandbox.role=app
            |    networks: sandbox-<env-id>, devops-sandbox-proxy
            |
            +--> per-env network: sandbox-<env-id>
            |
            +--> shared proxy network: devops-sandbox-proxy
                             |
                             v
                 Nginx container :8080
          includes /etc/nginx/conf.d/*.conf
          /env/<env-id>/ -> sandbox-<env-id>:8000

   cleanup daemon: checks TTL every 60s -> destroy_env.sh
   health poller: checks /health every 30s -> logs/<env-id>/health.log
   log shipper: docker logs -f -> logs/<env-id>/app.log
```

## Repository Layout

```text
devops-sandbox/
├── platform/          # lifecycle scripts, cleanup daemon, outage script, FastAPI API
├── nginx/             # nginx.conf and generated conf.d/<env-id>.conf routes
├── monitor/           # health poller and health status CLI
├── logs/              # runtime logs, gitignored except .gitkeep
├── envs/              # runtime state files, gitignored except .gitkeep
├── demo-app/          # bundled app image deployed into each environment
├── docker-compose.yml # Nginx front door
├── Makefile
└── README.md
```

All local settings and secrets belong in `.env`. The repo includes `.env.example`; `.env` is gitignored.

## Prerequisites

- A Linux VM or Linux workstation
- Docker Engine with the Docker Compose plugin
- Python 3.10+
- `bash`, `make`, and `curl`
- A user account that can run Docker commands

No cloud services are required. Everything runs on one host.

## Quick Start

From a fresh clone, an operator can get to the first running environment in fewer than five commands:

```bash
cp .env.example .env
make up
make create
```

When prompted by `make create`, enter a name such as `demo` and a TTL such as `10m`. The command prints:

```text
environment: env-abc123def456
url: http://localhost:8080/env/env-abc123def456/
ttl_seconds: 600
```

Open the URL or run:

```bash
curl http://localhost:8080/env/<env-id>/
```

`make up` is the main one-command platform startup. It creates the Python virtualenv, installs API dependencies, starts the Nginx container, then starts the cleanup daemon, health poller, and API in the background with `nohup`.

## Configuration

Copy `.env.example` to `.env` and edit values as needed:

```env
SANDBOX_HOST=localhost
SANDBOX_HTTP_PORT=8080
SANDBOX_API_PORT=5000
DEFAULT_TTL_SECONDS=1800
NGINX_CONTAINER=devops-sandbox-nginx
PROXY_NETWORK=devops-sandbox-proxy
DEMO_IMAGE=devops-sandbox-demo-app:latest
```

TTL values can be plain seconds or use `s`, `m`, `h`, or `d`, for example `300`, `30m`, `2h`, or `1d`.

## Make Targets

```bash
make up                      # start Nginx + daemon + health poller + API
make down                    # stop platform processes, destroy active envs, stop Nginx
make create                  # create a new env; prompts for name + TTL
make destroy ENV=env-...     # destroy one environment
make logs ENV=env-...        # tail active logs, or print archived logs if destroyed
make health                  # show all env statuses and latest health rows
make simulate ENV=env-... MODE=crash
make clean                   # wipe state, logs, archives, and generated routes
```

Simulation modes:

```bash
make simulate ENV=env-... MODE=crash    # docker kill the app container
make simulate ENV=env-... MODE=pause    # docker pause the app container
make simulate ENV=env-... MODE=network  # disconnect from the proxy network
make simulate ENV=env-... MODE=stress   # start a CPU busy loop in the app container
make simulate ENV=env-... MODE=recover  # undo crash, pause, network, or stress
```

The outage script validates environment IDs and refuses to target Nginx or daemon-like platform containers.

## Full Demo Walkthrough

1. Start the platform:

   ```bash
   make up
   ```

2. Create a short-lived environment:

   ```bash
   make create
   # Environment name: demo
   # TTL (default 30m): 10m
   ```

3. Save the printed environment ID:

   ```bash
   export ENV_ID=env-abc123def456
   ```

4. Check the deployed app and health endpoint:

   ```bash
   curl http://localhost:8080/env/$ENV_ID/
   curl http://localhost:8080/env/$ENV_ID/health
   make health
   ```

5. Watch app logs by environment ID:

   ```bash
   make logs ENV=$ENV_ID
   ```

6. Simulate an outage:

   ```bash
   make simulate ENV=$ENV_ID MODE=network
   ```

7. Observe health degradation. The poller runs every 30 seconds, so after three failed checks the state becomes `degraded` within about 90 seconds:

   ```bash
   make health
   tail -n 10 logs/$ENV_ID/health.log
   ```

8. Recover and confirm health returns:

   ```bash
   make simulate ENV=$ENV_ID MODE=recover
   make health
   curl http://localhost:8080/env/$ENV_ID/health
   ```

9. Destroy manually, or wait for TTL cleanup:

   ```bash
   make destroy ENV=$ENV_ID
   ```

   After destroy, active state is removed and logs are archived under `logs/archived/$ENV_ID/`.

## Control API

The API listens on `SANDBOX_API_PORT`, default `5000`.

```bash
curl -X POST http://localhost:5000/envs \
  -H 'Content-Type: application/json' \
  -d '{"name":"api-demo","ttl":"15m"}'

curl http://localhost:5000/envs
curl http://localhost:5000/envs/<env-id>/logs
curl http://localhost:5000/envs/<env-id>/health

curl -X POST http://localhost:5000/envs/<env-id>/outage \
  -H 'Content-Type: application/json' \
  -d '{"mode":"crash"}'

curl -X POST http://localhost:5000/envs/<env-id>/outage \
  -H 'Content-Type: application/json' \
  -d '{"mode":"recover"}'

curl -X DELETE http://localhost:5000/envs/<env-id>
```

Endpoints:

```text
POST   /envs              create an environment
GET    /envs              list active envs with TTL remaining
DELETE /envs/<id>         destroy an environment
GET    /envs/<id>/logs    last 100 lines of app.log
GET    /envs/<id>/health  last 10 health check results
POST   /envs/<id>/outage  trigger crash, pause, network, stress, or recover
```

## Lifecycle Details

`platform/create_env.sh <name> [ttl]`:

- Generates an ID like `env-abc123def456`
- Creates a dedicated Docker network named `sandbox-<env-id>`
- Builds the bundled demo image if needed
- Starts an app container named `sandbox-<env-id>`
- Applies labels `sandbox.env=<env-id>` and `sandbox.role=app`
- Connects the app to the shared proxy network
- Writes `nginx/conf.d/<env-id>.conf`
- Reloads Nginx with `nginx -t` followed by `nginx -s reload`
- Starts log shipping with `docker logs -f`
- Writes `envs/<env-id>.json` atomically using a temp file and `mv`
- Prints the URL and TTL

`platform/destroy_env.sh <env-id>`:

- Validates the env ID
- Stops the log shipper PID
- Removes all containers labeled `sandbox.env=<env-id>`
- Removes the dedicated Docker network
- Deletes the generated Nginx route and reloads Nginx
- Copies logs to `logs/archived/<env-id>/`
- Deletes `envs/<env-id>.json`

## Nginx and Network Approach

Nginx runs as a Docker container managed by `docker-compose.yml`. It has a bind mount for `nginx/nginx.conf` and a read-only bind mount for generated route files in `nginx/conf.d/`.

The main `nginx/nginx.conf` includes:

```nginx
include /etc/nginx/conf.d/*.conf;
```

Each environment gets one generated location block:

```nginx
location /env/<env-id>/ {
    proxy_pass http://sandbox-<env-id>:8000/;
}
```

The app container is attached to two networks:

- `sandbox-<env-id>` for per-environment isolation
- `devops-sandbox-proxy` so Nginx can resolve and route to the app by container name

No app ports are published directly to the host.

## Log Shipping

This project uses the simple log-shipping approach:

```bash
docker logs -f <container-id> >> logs/<env-id>/app.log &
```

The PID is stored in `logs/<env-id>/log_shipper.pid` and in the state file. Destroy kills the PID before removing the container, which prevents orphaned log-follow processes. Query logs with:

```bash
make logs ENV=<env-id>
```

Destroyed environment logs remain queryable from `logs/archived/<env-id>/app.log`.

## Health Monitoring

`monitor/health_poller.py` loops every 30 seconds. For each active state file, it calls:

```text
GET http://localhost:8080/env/<env-id>/health
```

It appends health rows to `logs/<env-id>/health.log`:

```text
2026-05-10T09:00:00Z status=200 latency_ms=12.4
```

After three consecutive failures, the poller sets `status` to `degraded` in `envs/<env-id>.json` and prints a warning to `logs/health_poller.log`. A successful check moves a degraded environment back to `running`.

## Auto Cleanup

`platform/cleanup_daemon.sh` checks `envs/*.json` every 60 seconds. If:

```text
now > created_at + ttl
```

it calls `platform/destroy_env.sh <env-id>`. All cleanup actions are timestamped in `logs/cleanup.log`.

`make up` starts the daemon in the background. You can inspect it with:

```bash
tail -f logs/cleanup.log
```

## Remote Deployment Guide

This guide explains how to deploy `devops-sandbox` to a single AWS EC2 instance while staying within the original project scope:

- Nginx runs in Docker through `docker-compose.yml`
- Each sandbox environment runs as a Docker app container on its own Docker network
- The API, cleanup daemon, and health poller run on the EC2 host through the Python virtualenv and Bash scripts started by `make up`
- systemd keeps the platform services running across reboots
- Runtime state remains local to the instance in `envs/`, `logs/`, and `nginx/conf.d/`

### 1. EC2 Instance Recommendation

Use a normal Linux EC2 instance with Docker installed. Ubuntu is the simplest option for this project because Docker's official installation docs provide a direct apt repository flow.

Recommended demo instance:

```text
AMI:           Ubuntu Server 24.04 LTS or 22.04 LTS
Architecture:  x86_64
Instance type: t3.small or larger
Storage:       20 GiB gp3 minimum
Public IP:     Enabled
```

`t3.micro` can work for a very small demo, but image builds, multiple sandbox containers, and outage simulation are more comfortable on `t3.small` or `t3.medium`.

### 2. Security Group Rules

Create a dedicated EC2 security group. Security groups act as the instance-level firewall, so only expose the ports needed for the demo.

Recommended inbound rules:

```text
Type             Port   Source
SSH              22     Your IP only, for example 203.0.113.10/32
Custom TCP       8080   Your IP, office CIDR, or 0.0.0.0/0 for a public demo
Custom TCP       5000   Your IP only
```

Recommended outbound rule:

```text
Type             Port   Destination
All traffic      All    0.0.0.0/0
```

Port `8080` is the Nginx front door by default. Port `5000` is the FastAPI control API by default. Keep `5000` restricted because the API can create environments, destroy environments, read logs, and trigger outage simulations.

If you change `SANDBOX_HTTP_PORT` or `SANDBOX_API_PORT` in `.env`, update the security group to match.

### 3. Launch the Instance

In the AWS console:

1. Open EC2.
2. Choose **Launch instance**.
3. Select Ubuntu Server 24.04 LTS or 22.04 LTS.
4. Choose `t3.small` or larger.
5. Create or select an SSH key pair.
6. Attach the security group from the previous step.
7. Allocate at least `20 GiB` of storage.
8. Launch the instance and wait for status checks to pass.

For the examples below, set these variables on your local machine:

```bash
export EC2_HOST=ec2-203-0-113-10.compute-1.amazonaws.com
export KEY=~/Downloads/devops-sandbox.pem
```

Use your actual EC2 public DNS name or public IPv4 address.

### 4. SSH Into the Instance

Set the private key permissions:

```bash
chmod 400 "$KEY"
```

Connect:

```bash
ssh -i "$KEY" ubuntu@$EC2_HOST
```

If you use Amazon Linux instead of Ubuntu, the SSH username is usually `ec2-user`, and the package commands differ.

### 5. Install Dependencies on Ubuntu

Install base packages:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git make python3 python3-venv python3-pip
```

Install Docker Engine and the Docker Compose plugin from Docker's official apt repository:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Allow the `ubuntu` user to run Docker:

```bash
sudo usermod -aG docker ubuntu
```

Log out and reconnect so the new Docker group membership is active:

```bash
exit
ssh -i "$KEY" ubuntu@$EC2_HOST
```

Verify the installation:

```bash
docker version
docker compose version
docker run --rm hello-world
```

### 6. Clone or Upload the Project

For a public GitHub repo:

```bash
git clone https://github.com/<your-user>/devops-sandbox.git
cd devops-sandbox
```

For a private repo, use an SSH deploy key, GitHub CLI, a short-lived HTTPS token, or upload the working tree from your laptop.

Example upload from your local machine:

```bash
rsync -az --exclude .git --exclude .venv --exclude logs --exclude envs \
  -e "ssh -i $KEY" \
  ./ ubuntu@$EC2_HOST:~/devops-sandbox/
```

Then reconnect and enter the project:

```bash
ssh -i "$KEY" ubuntu@$EC2_HOST
cd ~/devops-sandbox
```

### 7. Configure `.env`

Create the runtime config:

```bash
cp .env.example .env
```

Edit it:

```bash
nano .env
```

For EC2, set `SANDBOX_HOST` to the public DNS name, public IPv4 address, or a domain that points to the instance:

```env
SANDBOX_HOST=ec2-203-0-113-10.compute-1.amazonaws.com
SANDBOX_HTTP_PORT=8080
SANDBOX_API_PORT=5000
DEFAULT_TTL_SECONDS=1800
NGINX_CONTAINER=devops-sandbox-nginx
PROXY_NETWORK=devops-sandbox-proxy
DEMO_IMAGE=devops-sandbox-demo-app:latest
```

`SANDBOX_HOST` controls the URLs printed by `create_env.sh` and returned by the API. If you leave it as `localhost`, the platform can still run, but the printed environment URLs will only make sense from inside the EC2 instance.

### 8. Start the Platform

Run:

```bash
make up
```

This does four things:

1. Creates `.venv/` and installs Python dependencies from `requirements.txt`
2. Starts the Nginx container with Docker Compose
3. Starts `cleanup_daemon.sh` in the background
4. Starts the health poller and FastAPI API in the background

Expected output:

```text
cleanup_daemon started
health_poller started
api started
nginx: http://localhost:8080
api:   http://localhost:5000
```

From your laptop, use the EC2 host instead of `localhost`:

```text
http://<ec2-public-dns>:8080
http://<ec2-public-dns>:5000
```

Check the platform:

```bash
docker ps
cat logs/api.pid logs/cleanup_daemon.pid logs/health_poller.pid
tail -n 40 logs/api.log
tail -n 40 logs/cleanup.log
tail -n 40 logs/health_poller.log
```

### 9. Add Service Persistence With systemd

`make up` starts the long-running API, cleanup daemon, and health poller with `nohup`, which is fine for a manual demo. On EC2, use systemd for persistence so the platform starts after reboot and each long-running process can be supervised independently.

The units below match this project scope: Nginx still runs in Docker, while the API, cleanup daemon, and health poller run on the host through the repo scripts and Python virtualenv.

Confirm the project path:

```bash
cd ~/devops-sandbox
pwd
```

Prepare the virtualenv and directories once:

```bash
make deps chmod
mkdir -p logs envs nginx/conf.d logs/archived
```

If you already started the platform manually with `make up`, stop the manual background processes before handing control to systemd:

```bash
platform/stop_services.sh
docker compose stop nginx
```

Create a systemd service for the Nginx front door:

```bash
sudo tee /etc/systemd/system/devops-sandbox-nginx.service >/dev/null <<'EOF'
[Unit]
Description=devops-sandbox Nginx front door
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
PartOf=devops-sandbox.target

[Service]
Type=oneshot
WorkingDirectory=/home/ubuntu/devops-sandbox
RemainAfterExit=yes
ExecStartPre=/usr/bin/mkdir -p /home/ubuntu/devops-sandbox/logs /home/ubuntu/devops-sandbox/envs /home/ubuntu/devops-sandbox/nginx/conf.d /home/ubuntu/devops-sandbox/logs/archived
ExecStart=/usr/bin/docker compose up -d nginx
ExecStop=-/usr/bin/docker compose stop nginx
User=ubuntu
Group=ubuntu
SupplementaryGroups=docker
TimeoutStartSec=0

[Install]
WantedBy=devops-sandbox.target
EOF
```

Create a service for the API:

```bash
sudo tee /etc/systemd/system/devops-sandbox-api.service >/dev/null <<'EOF'
[Unit]
Description=devops-sandbox API
Requires=devops-sandbox-nginx.service
After=devops-sandbox-nginx.service
PartOf=devops-sandbox.target

[Service]
WorkingDirectory=/home/ubuntu/devops-sandbox
EnvironmentFile=/home/ubuntu/devops-sandbox/.env
ExecStart=/home/ubuntu/devops-sandbox/.venv/bin/python -m uvicorn api:app --app-dir /home/ubuntu/devops-sandbox/platform --host 0.0.0.0 --port ${SANDBOX_API_PORT}
Restart=always
RestartSec=5
User=ubuntu
Group=ubuntu
SupplementaryGroups=docker

[Install]
WantedBy=devops-sandbox.target
EOF
```

Create a service for TTL cleanup:

```bash
sudo tee /etc/systemd/system/devops-sandbox-cleanup.service >/dev/null <<'EOF'
[Unit]
Description=devops-sandbox cleanup daemon
After=devops-sandbox-nginx.service
PartOf=devops-sandbox.target

[Service]
WorkingDirectory=/home/ubuntu/devops-sandbox
EnvironmentFile=/home/ubuntu/devops-sandbox/.env
ExecStart=/home/ubuntu/devops-sandbox/platform/cleanup_daemon.sh
Restart=always
RestartSec=5
User=ubuntu
Group=ubuntu
SupplementaryGroups=docker

[Install]
WantedBy=devops-sandbox.target
EOF
```

Create a service for health polling:

```bash
sudo tee /etc/systemd/system/devops-sandbox-health.service >/dev/null <<'EOF'
[Unit]
Description=devops-sandbox health poller
After=devops-sandbox-nginx.service
PartOf=devops-sandbox.target

[Service]
WorkingDirectory=/home/ubuntu/devops-sandbox
EnvironmentFile=/home/ubuntu/devops-sandbox/.env
ExecStart=/home/ubuntu/devops-sandbox/.venv/bin/python /home/ubuntu/devops-sandbox/monitor/health_poller.py
Restart=always
RestartSec=5
User=ubuntu
Group=ubuntu
SupplementaryGroups=docker

[Install]
WantedBy=devops-sandbox.target
EOF
```

Create a target to manage all platform services together:

```bash
sudo tee /etc/systemd/system/devops-sandbox.target >/dev/null <<'EOF'
[Unit]
Description=devops-sandbox platform
Requires=devops-sandbox-nginx.service devops-sandbox-api.service devops-sandbox-cleanup.service devops-sandbox-health.service
After=network-online.target docker.service
Wants=network-online.target

[Install]
WantedBy=multi-user.target
EOF
```

If your repo is not at `/home/ubuntu/devops-sandbox`, update every `WorkingDirectory`, `EnvironmentFile`, and `ExecStart` path. If your user is not `ubuntu`, update every `User` and `Group`.

Enable and start the platform target:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now devops-sandbox.target
sudo systemctl status devops-sandbox.target
```

Useful commands:

```bash
sudo systemctl restart devops-sandbox.target
sudo systemctl stop devops-sandbox.target
sudo systemctl status devops-sandbox-api
sudo systemctl status devops-sandbox-cleanup
sudo systemctl status devops-sandbox-health
sudo journalctl -u devops-sandbox-api -n 100 --no-pager
sudo journalctl -u devops-sandbox-cleanup -f
sudo journalctl -u devops-sandbox-health -f
```

These units intentionally do not call `make down`, because `make down` destroys all active environments. If you want a full destructive shutdown, run:

```bash
make down
```

Important limitation: active sandbox app containers are temporary by design and are not configured as persistent systemd services. After an EC2 reboot, the platform services come back, but any previously running short-lived app container should be treated as disposable and recreated.

### 10. Create a Remote Environment

From the EC2 shell:

```bash
make create
```

Example prompt values:

```text
Environment name: remote-demo
TTL (default 30m): 15m
```

The script prints:

```text
environment: env-abc123def456
url: http://ec2-203-0-113-10.compute-1.amazonaws.com:8080/env/env-abc123def456/
ttl_seconds: 900
```

From your laptop:

```bash
curl http://$EC2_HOST:8080/env/env-abc123def456/
curl http://$EC2_HOST:8080/env/env-abc123def456/health
```

From the EC2 instance:

```bash
make health
make logs ENV=env-abc123def456
```

### 11. Use the Remote API

If your security group allows your IP to reach port `5000`, create an environment from your laptop:

```bash
curl -X POST http://$EC2_HOST:5000/envs \
  -H 'Content-Type: application/json' \
  -d '{"name":"api-remote-demo","ttl":"10m"}'
```

List environments:

```bash
curl http://$EC2_HOST:5000/envs
```

Read logs and health:

```bash
curl http://$EC2_HOST:5000/envs/<env-id>/logs
curl http://$EC2_HOST:5000/envs/<env-id>/health
```

Simulate and recover an outage:

```bash
curl -X POST http://$EC2_HOST:5000/envs/<env-id>/outage \
  -H 'Content-Type: application/json' \
  -d '{"mode":"network"}'

curl -X POST http://$EC2_HOST:5000/envs/<env-id>/outage \
  -H 'Content-Type: application/json' \
  -d '{"mode":"recover"}'
```

Destroy:

```bash
curl -X DELETE http://$EC2_HOST:5000/envs/<env-id>
```

### 12. Optional Domain Name

For a cleaner URL:

1. Allocate an Elastic IP and associate it with the EC2 instance.
2. Create an `A` record such as `sandbox.example.com` pointing to the Elastic IP.
3. Set `.env`:

   ```env
   SANDBOX_HOST=sandbox.example.com
   ```

4. Restart the platform:

   ```bash
   sudo systemctl restart devops-sandbox.target
   ```

New environments will print URLs like:

```text
http://sandbox.example.com:8080/env/<env-id>/
```

This project does not configure TLS. For HTTPS, put an AWS Application Load Balancer, Caddy, Traefik, or a host-level reverse proxy in front of port `8080`. Keep the project Nginx container as the internal environment router.

### 13. Updating the EC2 Deployment

From the instance:

```bash
cd ~/devops-sandbox
git pull
sudo systemctl restart devops-sandbox.target
```

If you are not using systemd:

```bash
platform/stop_services.sh
docker compose stop nginx
git pull
make up
```

If you want a clean slate before updating:

```bash
make down
git pull
make up
```

### 14. Backups and Cleanup

Runtime state is local to the instance:

```text
envs/                 active environment state files
logs/<env-id>/        active app and health logs
logs/archived/        destroyed environment logs
nginx/conf.d/         generated Nginx routes
```

Archive logs before terminating the instance if you need them:

```bash
tar -czf devops-sandbox-logs.tgz logs/
```

Wipe runtime state:

```bash
make clean
```

Stop the platform and destroy active environments:

```bash
make down
```

When you are done, terminate the EC2 instance. If you allocated an Elastic IP, release it to avoid ongoing charges.

### 15. EC2 Troubleshooting

- SSH times out: confirm the instance passed status checks, port `22` is open from your IP, and you are using the correct key and username.
- `docker: permission denied`: run `sudo usermod -aG docker ubuntu`, then log out and reconnect.
- `make up` cannot pull images: confirm the instance has outbound internet access through a public subnet, internet gateway, NAT gateway, or proxy.
- Nginx is unreachable from your laptop: confirm the security group allows inbound `SANDBOX_HTTP_PORT`, default `8080`.
- API is unreachable from your laptop: confirm the security group allows inbound `SANDBOX_API_PORT`, default `5000`, from your IP only.
- Printed URLs show `localhost`: set `SANDBOX_HOST` in `.env` to the EC2 public DNS, public IP, or domain.
- Health checks stay empty: wait at least 30 seconds, then check `logs/health_poller.log`.
- TTL cleanup does not happen: wait at least 60 seconds, then check `logs/cleanup.log`.
- Nginx route returns 502: inspect the app container with `docker ps`, `docker logs <container>`, and verify the container is connected to `devops-sandbox-proxy`.

References:

- AWS EC2 security groups: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html
- AWS SSH guide for Linux instances: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-to-linux-instance.html
- Docker Engine on Ubuntu: https://docs.docker.com/installation/ubuntulinux/

## Testing and Validation

Static checks:

```bash
bash -n platform/*.sh
shellcheck platform/*.sh
python3 -m py_compile platform/api.py monitor/health_poller.py monitor/health_status.py demo-app/app.py
docker compose config
```

End-to-end smoke test:

```bash
make up
make create
make health
make simulate ENV=<env-id> MODE=network
make simulate ENV=<env-id> MODE=recover
make destroy ENV=<env-id>
make down
```

The included GitHub Actions workflow runs ShellCheck and Python syntax compilation on push and pull request.

## Troubleshooting

- `docker: permission denied`: add your user to the `docker` group or run from a shell that can access Docker.
- `port is already allocated`: change `SANDBOX_HTTP_PORT` or `SANDBOX_API_PORT` in `.env`.
- Nginx route returns 404: confirm `nginx/conf.d/<env-id>.conf` exists, then run `docker exec devops-sandbox-nginx nginx -t`.
- Health stays empty: the poller runs every 30 seconds; check `logs/health_poller.log`.
- Logs do not stream: check `logs/<env-id>/log_shipper.pid` and `logs/<env-id>/app.log`.
- Cleanup did not run yet: the daemon checks every 60 seconds; check `logs/cleanup.log`.

## Known Limitations

- The deployed app is the bundled demo app. Arbitrary user app upload/build pipelines are outside this compact implementation.
- The API shells out to local scripts and has no authentication, authorization, quota system, or rate limiting.
- `stress` mode uses a simple CPU busy loop rather than `stress-ng`.
- The platform is intentionally single-host. It does not provide clustering, TLS automation, persistent databases, or multi-tenant hardening.
- Runtime state in `envs/` and logs in `logs/` are local files. They are not durable across `make clean` or host loss.
