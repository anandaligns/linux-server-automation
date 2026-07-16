# Linux Server Automation Toolkit

Keep this toolkit once per server. Do not copy `bash_scripts` into every website repository, and do not upload the complete `digitalphy-media` folder to deploy it.

Recommended layout:

```text
/root/bash_scripts/                 shared server toolkit
/root/project-configs/              root-only deployment configurations
/root/project-secrets/              root-only tokens and production .env files
/srv/sites/digitalphy/              cloned DigitalPhy repository
/srv/sites/events-by-smaya/         cloned Smaya repository
/srv/sites/future-client/           cloned future repository
```

The single entry point is `manage.sh`:

- `bootstrap` prepares a fresh Ubuntu server.
- `deploy` clones, builds, starts, and updates one website.
- `sync-keys` installs any new server-login `.pub` keys.
- `status` checks the shared server services.

## Put the toolkit in its own GitHub repository

Create a small repository such as `linux-server-automation` containing only the files inside this `bash_scripts` folder. The website repositories remain separate.

The toolkit repository must never contain:

- production `.env` files
- GitHub access tokens
- database passwords
- private SSH keys
- real per-server project configuration files

The supplied `.gitignore` excludes the normal secret locations. Public keys ending in `.pub` are not private keys and may be included if you want the bootstrap process to authorize them.

For the easiest first setup, the toolkit repository can be public because it contains no secrets. If it is private, the fresh server needs a one-time GitHub authentication method before it can clone the toolkit; in that case, copying only `bash_scripts` once is often simpler.

## Case 1: fresh server and first website

Open the DigitalOcean web console as `root`, then install Git and clone the standalone toolkit:

```bash
apt-get update
apt-get install -y git ca-certificates
git clone https://github.com/YOUR_ACCOUNT/linux-server-automation.git /root/bash_scripts
cd /root/bash_scripts
chmod 700 *.sh
bash manage.sh bootstrap
```

The bootstrap asks whether the hostname, timezone, admin username, and displayed server IP are correct. It installs Docker, host Nginx, Certbot, UFW, Fail2Ban, and all server-login public keys found beside the scripts.

Keep the first root session open. Before allowing SSH hardening, test the new login in a second Mac Terminal:

```bash
ssh -i ~/.ssh/dpm_do anand@YOUR_SERVER_IP
```

After the server setup is complete, create the website's deployment config and deploy it using the instructions below.

## Case 2: existing prepared server and another website

Do not bootstrap the server again. Add another project config with a different project name, directory, domain, and loopback port, then run:

```bash
sudo bash /root/bash_scripts/manage.sh deploy \
  --config /root/project-configs/NEW_PROJECT.conf \
  --non-interactive
```

Use a unique port for every project, for example DigitalPhy `8081`, Smaya `8082`, and the next client `8083`.

## Configure a project

Copy the safe template outside all website repositories:

```bash
sudo install -d -m 700 /root/project-configs /root/project-secrets
sudo install -m 600 \
  /root/bash_scripts/projects/project.template.conf \
  /root/project-configs/digitalphy.conf
sudo nano /root/project-configs/digitalphy.conf
```

Important project values are:

```bash
PROJECT_NAME="digitalphy"
REPO_URL="git@github.com:YOUR_ACCOUNT/digitalphy-media.git"
GIT_BRANCH="main"
GIT_AUTH_MODE="ssh"
SITE_DIR="/srv/sites/digitalphy"
COMPOSE_FILE="docker-compose.yml"
SITE_PORT="8081"
DOMAIN="digitalphymedia.com"
INCLUDE_WWW="yes"
ENABLE_SSL="yes"
SSL_EMAIL="you@example.com"
APP_ENV_SOURCE="/root/project-secrets/digitalphy.env"
```

The config contains paths and deployment settings, not passwords or token values. It is sourced by a root process, so the deployer requires root ownership and rejects a config writable by another user.

Place the production application environment in the configured secret path:

```bash
sudo nano /root/project-secrets/digitalphy.env
sudo chown root:root /root/project-secrets/digitalphy.env
sudo chmod 600 /root/project-secrets/digitalphy.env
```

Then deploy:

```bash
sudo bash /root/bash_scripts/manage.sh deploy \
  --config /root/project-configs/digitalphy.conf \
  --non-interactive
```

Running that same command later safely fetches the configured branch, accepts only a fast-forward update, rebuilds the containers, checks the local ingress, and refreshes the host Nginx route.

You may also run `sudo bash /root/bash_scripts/manage.sh` without arguments for an interactive menu. Running `deploy` without a config asks for the project values at the beginning.

## GitHub authentication choices

GitHub account passwords are not supported for command-line Git HTTPS authentication. Do not put a password or token directly in `REPO_URL` or a project config.

### SSH deploy key — recommended for private repositories

Use:

```bash
GIT_AUTH_MODE="ssh"
REPO_URL="git@github.com:OWNER/REPOSITORY.git"
GIT_SSH_KEY=""
```

On the first run, the deployer generates a unique key for that one project and displays its public half. Add it in that GitHub repository under **Settings → Deploy keys → Add deploy key**, leave write access disabled, and rerun the same command. Future deployments are unattended.

This one-time pause cannot be removed safely because GitHub must authorize the newly generated public key. A different key is generated for every repository.

### Public repository

Use:

```bash
GIT_AUTH_MODE="public"
REPO_URL="https://github.com/OWNER/REPOSITORY.git"
```

No GitHub username, password, token, or pause is required.

### Fine-grained token for a private HTTPS repository

Use a fine-grained, read-only token only when SSH deploy keys are unsuitable. Save it once in a root-only file without putting the token in shell history:

```bash
sudo -i
install -d -m 700 /root/project-secrets
umask 077
read -r -s -p "GitHub token: " GH_TOKEN
printf '%s' "$GH_TOKEN" > /root/project-secrets/github-token
unset GH_TOKEN
echo
exit
```

Configure only the path:

```bash
GIT_AUTH_MODE="token"
REPO_URL="https://github.com/OWNER/REPOSITORY.git"
GIT_USERNAME="x-access-token"
GITHUB_TOKEN_FILE="/root/project-secrets/github-token"
```

The deployer provides the token to Git only for the clone/fetch process and never stores it in the repository URL. Once the token file and project config exist, `--non-interactive` deploys without asking questions.

## Required production Docker layout

Host Nginx owns public ports `80` and `443` and all Let's Encrypt certificates. Every website retains its own application, PostgreSQL, and internal Nginx containers. The internal Nginx must publish only one unique loopback port:

```yaml
services:
  nginx:
    ports:
      - "127.0.0.1:${SITE_PORT}:80"
```

Remove public website mappings such as `80:80` and `443:443` from every project Compose file. Do not publish PostgreSQL `5432` or the application port `3000` in production. The deployer rejects a Compose configuration that exposes a container port on all server interfaces.

Each project `.env` receives unique values:

```dotenv
COMPOSE_PROJECT_NAME=digitalphy
SITE_PORT=8081
```

Avoid explicit `container_name` values. Docker Compose then prefixes containers, networks, and named database volumes with `COMPOSE_PROJECT_NAME`, keeping projects and databases separate.

Use `templates/container-nginx.conf` for the project's internal HTTP-only Nginx. The host gateway handles domains and HTTPS.

## Shared reverse-proxy architecture

| Website | Internal address | Public address |
| --- | --- | --- |
| DigitalPhy Media | `127.0.0.1:8081` | `https://digitalphymedia.com` |
| Events by Smaya | `127.0.0.1:8082` | `https://eventsbysmaya.com` |
| Future website | `127.0.0.1:8083` | its own domain |

Visitors never type `:8081` or another internal port. Host Nginx routes each domain to the correct project.

## Server-login SSH keys

Place every administrator's `.pub` file beside `manage.sh` before bootstrapping. The included `dpm_do.pub` is the public half of the Mac key `~/.ssh/dpm_do`.

Never place `~/.ssh/dpm_do` or any other private key in this folder. Private keys have no `.pub` extension.

To add new administrator public keys later, put the `.pub` files beside the scripts and run:

```bash
sudo bash /root/bash_scripts/manage.sh sync-keys
```

These server-login keys grant access to the server account. They are different from the per-repository GitHub deploy keys created by `deploy`.

## DigitalOcean firewall

Allow inbound TCP:

- `22` for SSH, preferably restricted to your own IP when practical
- `80` for HTTP and certificate validation
- `443` for HTTPS

Do not expose `3000`, `5432`, `8081`, `8082`, or future internal site ports in the DigitalOcean Cloud Firewall.

## Maintenance

Update the shared toolkit:

```bash
sudo git -C /root/bash_scripts pull --ff-only
```

Check the server:

```bash
sudo bash /root/bash_scripts/manage.sh status
sudo nginx -t
sudo fail2ban-client status
sudo ufw status verbose
```

Inspect one website:

```bash
cd /srv/sites/digitalphy
docker compose ps
docker compose logs --tail=100
```

Disable a domain proxy without deleting its containers or certificate:

```bash
sudo bash /root/bash_scripts/remove_docker_site.sh example.com
```
