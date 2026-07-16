#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_root

CONFIG_FILE=""
NON_INTERACTIVE="no"

usage() {
    cat <<EOF
Usage:
  sudo bash $SCRIPT_DIR/deploy_project.sh
  sudo bash $SCRIPT_DIR/deploy_project.sh --config /root/project-configs/example.conf
  sudo bash $SCRIPT_DIR/deploy_project.sh --config /root/project-configs/example.conf --non-interactive
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --config)
            if (( $# < 2 )) || [[ -z "$2" ]]; then
                error "--config requires a file path."
                usage
                exit 1
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        --non-interactive) NON_INTERACTIVE="yes"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

PROJECT_NAME=""
REPO_URL=""
GIT_BRANCH="main"
GIT_AUTH_MODE="ssh"
GIT_USERNAME="x-access-token"
GIT_SSH_KEY=""
GITHUB_TOKEN_FILE=""
SITE_DIR=""
COMPOSE_FILE="docker-compose.yml"
SITE_PORT=""
DOMAIN=""
INCLUDE_WWW="yes"
ENABLE_SSL="yes"
SSL_EMAIL=""
APP_ENV_SOURCE=""
NEW_USER="${NEW_USER:-anand}"

if [[ -n "$CONFIG_FILE" ]]; then
    if [[ ! -r "$CONFIG_FILE" ]]; then
        error "Cannot read project configuration: $CONFIG_FILE"
        exit 1
    fi
    config_owner="$(stat -c '%u' "$CONFIG_FILE")"
    config_mode="$(stat -c '%a' "$CONFIG_FILE")"
    if [[ "$config_owner" != "0" ]] || (( (8#$config_mode & 022) != 0 )); then
        error "Project configuration must be owned by root and not writable by group/others."
        echo "Fix with: sudo chown root:root $CONFIG_FILE && sudo chmod 600 $CONFIG_FILE"
        exit 1
    fi
    # Project configurations are trusted root-owned shell files kept outside application repositories.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

prompt_value() {
    local variable_name="$1"
    local prompt_text="$2"
    local default_value="${!variable_name:-}"
    local entered_value=""

    if [[ "$NON_INTERACTIVE" == "yes" ]]; then
        return
    fi

    read -r -p "$prompt_text [$default_value]: " entered_value
    if [[ -n "$entered_value" ]]; then
        printf -v "$variable_name" '%s' "$entered_value"
    fi
}

if [[ -z "$CONFIG_FILE" || "$NON_INTERACTIVE" != "yes" ]]; then
    prompt_value PROJECT_NAME "Project name (lowercase, no spaces)"
    prompt_value REPO_URL "Git clone URL"
    prompt_value GIT_BRANCH "Git branch"
    prompt_value GIT_AUTH_MODE "Git authentication: public, ssh, or token"
    prompt_value SITE_PORT "Unique loopback port, such as 8081"
    prompt_value DOMAIN "Primary domain"
    prompt_value INCLUDE_WWW "Include www: yes or no"
    prompt_value ENABLE_SSL "Enable Let's Encrypt SSL: yes or no"
    if [[ "${ENABLE_SSL,,}" =~ ^(yes|y|1|true)$ ]]; then
        prompt_value SSL_EMAIL "Let's Encrypt email"
    fi
    prompt_value APP_ENV_SOURCE "Absolute path to the production .env source file"
fi

PROJECT_NAME="${PROJECT_NAME,,}"
GIT_AUTH_MODE="${GIT_AUTH_MODE,,}"
INCLUDE_WWW="${INCLUDE_WWW,,}"
ENABLE_SSL="${ENABLE_SSL,,}"
DOMAIN="${DOMAIN,,}"

normalize_yes_no() {
    local variable_name="$1"
    local current_value="${!variable_name}"

    case "$current_value" in
        yes|y|true|1) printf -v "$variable_name" '%s' "yes" ;;
        no|n|false|0) printf -v "$variable_name" '%s' "no" ;;
        *) error "$variable_name must be yes or no."; exit 1 ;;
    esac
}

contains_unsafe_path_segment() {
    local path="$1"
    [[ "$path" == *"//"* || "$path" == *"/../"* || "$path" == */.. || "$path" == *"/./"* || "$path" == */. ]]
}

require_root_secret_file() {
    local path="$1"
    local label="$2"
    local file_owner=""
    local file_mode=""

    if [[ ! -f "$path" || ! -r "$path" ]]; then
        error "$label is not a readable regular file: $path"
        exit 1
    fi
    file_owner="$(stat -c '%u' "$path")"
    file_mode="$(stat -c '%a' "$path")"
    if [[ "$file_owner" != "0" ]] || (( (8#$file_mode & 077) != 0 )); then
        error "$label must be owned by root and inaccessible to group/others."
        echo "Fix with: sudo chown root:root $path && sudo chmod 600 $path"
        exit 1
    fi
}

normalize_yes_no INCLUDE_WWW
normalize_yes_no ENABLE_SSL

if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; then
    error "Invalid PROJECT_NAME: $PROJECT_NAME"
    exit 1
fi
if [[ ! "$GIT_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
   [[ "$GIT_BRANCH" == *".."* || "$GIT_BRANCH" == *"//"* || "$GIT_BRANCH" == *"@{"* || "$GIT_BRANCH" == *.lock ]]; then
    error "Invalid GIT_BRANCH: $GIT_BRANCH"
    exit 1
fi
if [[ ! "$SITE_PORT" =~ ^[0-9]+$ ]] || (( SITE_PORT < 1024 || SITE_PORT > 65535 )); then
    error "SITE_PORT must be a number from 1024 through 65535."
    exit 1
fi
if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
    error "Invalid DOMAIN: $DOMAIN"
    exit 1
fi
if [[ ! "$GIT_AUTH_MODE" =~ ^(public|ssh|token)$ ]]; then
    error "GIT_AUTH_MODE must be public, ssh, or token."
    exit 1
fi
if [[ "$GIT_AUTH_MODE" == "ssh" && ! "$REPO_URL" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]]; then
    error "SSH mode requires a GitHub SSH URL such as git@github.com:OWNER/REPOSITORY.git"
    exit 1
fi
if [[ "$GIT_AUTH_MODE" =~ ^(public|token)$ && ! "$REPO_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]]; then
    error "Public/token mode requires a GitHub HTTPS URL."
    exit 1
fi
if [[ "$ENABLE_SSL" == "yes" && ! "$SSL_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    error "A valid SSL_EMAIL is required when ENABLE_SSL=yes."
    exit 1
fi
if [[ "$GIT_AUTH_MODE" == "token" && ( -z "$GIT_USERNAME" || "$GIT_USERNAME" =~ [[:space:]] ) ]]; then
    error "GIT_USERNAME cannot be empty or contain whitespace in token mode."
    exit 1
fi
if ! validate_username "$NEW_USER" || ! id "$NEW_USER" >/dev/null 2>&1; then
    error "Deployment user is missing or invalid: $NEW_USER"
    exit 1
fi

SITE_DIR="${SITE_DIR:-/srv/sites/$PROJECT_NAME}"
USER_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
GIT_SSH_KEY="${GIT_SSH_KEY:-$USER_HOME/.ssh/github_${PROJECT_NAME}}"

if [[ ! "$SITE_DIR" =~ ^/srv/sites/[A-Za-z0-9._/-]+$ ]] || contains_unsafe_path_segment "$SITE_DIR"; then
    error "SITE_DIR must be a safe absolute path below /srv/sites."
    exit 1
fi
if [[ "$COMPOSE_FILE" == /* || ! "$COMPOSE_FILE" =~ ^[A-Za-z0-9._/-]+$ ]] || contains_unsafe_path_segment "/$COMPOSE_FILE"; then
    error "COMPOSE_FILE must be a safe path relative to SITE_DIR."
    exit 1
fi
if [[ "$GIT_AUTH_MODE" == "ssh" ]]; then
    if [[ ! "$GIT_SSH_KEY" =~ ^/[A-Za-z0-9._/-]+$ ]] || contains_unsafe_path_segment "$GIT_SSH_KEY" || [[ "$GIT_SSH_KEY" != "$USER_HOME/.ssh/"* ]]; then
        error "GIT_SSH_KEY must be a safe path inside $USER_HOME/.ssh."
        exit 1
    fi
fi

for required_command in git docker nginx curl jq; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        error "Missing required command: $required_command. Run manage.sh bootstrap first."
        exit 1
    fi
done
if ! systemctl is-active --quiet docker || ! systemctl is-active --quiet nginx; then
    error "Docker and host Nginx must be active. Run manage.sh bootstrap first."
    exit 1
fi

mapfile -d '' -t site_metadata_files < <(find /etc/nginx/docker-sites -maxdepth 1 -type f -name '*.env' -print0 2>/dev/null || true)
for site_metadata_file in "${site_metadata_files[@]}"; do
    existing_domain="$(awk -F= '$1 == "DOMAIN" {print substr($0, index($0, "=") + 1); exit}' "$site_metadata_file")"
    existing_port="$(awk -F= '$1 == "PORT" {print substr($0, index($0, "=") + 1); exit}' "$site_metadata_file")"
    if [[ "$existing_port" == "$SITE_PORT" && "$existing_domain" != "$DOMAIN" ]]; then
        error "SITE_PORT $SITE_PORT is already assigned to $existing_domain."
        error "Choose a different loopback port for $DOMAIN."
        exit 1
    fi
done

temp_token_file=""
askpass_script=""
compose_json=""
known_hosts_temp=""
cleanup() {
    local temporary_file=""
    for temporary_file in "$temp_token_file" "$askpass_script" "$compose_json" "$known_hosts_temp"; do
        if [[ -n "$temporary_file" && -e "$temporary_file" ]]; then
            rm -f "$temporary_file"
        fi
    done
}
trap cleanup EXIT

GIT_ENV=(GIT_TERMINAL_PROMPT=0)

if [[ "$GIT_AUTH_MODE" == "ssh" ]]; then
    key_directory="$(dirname "$GIT_SSH_KEY")"
    install -d -m 0700 -o "$NEW_USER" -g "$NEW_USER" "$key_directory"

    if [[ ! -f "$GIT_SSH_KEY" ]]; then
        if [[ -e "$GIT_SSH_KEY.pub" ]]; then
            error "A public deploy key exists without its private half: $GIT_SSH_KEY.pub"
            exit 1
        fi
        ssh-keygen -t ed25519 -a 100 -N '' -C "github-deploy-$PROJECT_NAME@$(hostname)" -f "$GIT_SSH_KEY"
        chown "$NEW_USER:$NEW_USER" "$GIT_SSH_KEY" "$GIT_SSH_KEY.pub"
        chmod 0600 "$GIT_SSH_KEY"
        chmod 0644 "$GIT_SSH_KEY.pub"
        echo
        warning "A repository-specific GitHub deploy key was generated."
        echo "Add the following public key in GitHub: Repository Settings -> Deploy keys -> Add deploy key"
        echo "Keep it read-only unless this server must push code."
        echo
        cat "$GIT_SSH_KEY.pub"
        echo
        echo "After adding it, rerun the same deployment command."
        exit 20
    fi

    chown "$NEW_USER:$NEW_USER" "$GIT_SSH_KEY"
    chmod 0600 "$GIT_SSH_KEY"

    if [[ ! -f "$GIT_SSH_KEY.pub" ]]; then
        ssh-keygen -y -f "$GIT_SSH_KEY" > "$GIT_SSH_KEY.pub"
        chown "$NEW_USER:$NEW_USER" "$GIT_SSH_KEY.pub"
        chmod 0644 "$GIT_SSH_KEY.pub"
    fi

    known_hosts_file="$key_directory/known_hosts.github"
    known_hosts_temp="$(mktemp)"
    curl -fsSL https://api.github.com/meta | jq -er '.ssh_keys[] | "github.com " + .' > "$known_hosts_temp"
    install -m 0644 -o "$NEW_USER" -g "$NEW_USER" "$known_hosts_temp" "$known_hosts_file"
    rm -f "$known_hosts_temp"
    known_hosts_temp=""
    chown "$NEW_USER:$NEW_USER" "$known_hosts_file"
    chmod 0644 "$known_hosts_file"
    GIT_ENV+=("GIT_SSH_COMMAND=ssh -i $GIT_SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts_file")
fi

if [[ "$GIT_AUTH_MODE" == "token" ]]; then
    if [[ -z "$GITHUB_TOKEN_FILE" ]]; then
        if [[ "$NON_INTERACTIVE" == "yes" ]]; then
            error "Token mode requires GITHUB_TOKEN_FILE in non-interactive mode."
            exit 1
        fi
        read -r -s -p "GitHub fine-grained personal access token: " github_token
        echo
        temp_token_file="$(mktemp)"
        chmod 0600 "$temp_token_file"
        printf '%s' "$github_token" > "$temp_token_file"
        unset github_token
        GITHUB_TOKEN_FILE="$temp_token_file"
    fi

    if [[ ! -r "$GITHUB_TOKEN_FILE" ]]; then
        error "Cannot read GITHUB_TOKEN_FILE: $GITHUB_TOKEN_FILE"
        exit 1
    fi
    require_root_secret_file "$GITHUB_TOKEN_FILE" "GITHUB_TOKEN_FILE"

    askpass_script="$(mktemp)"
    cat > "$askpass_script" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    *Username*) printf '%s\n' "$DPM_GIT_USERNAME" ;;
    *Password*) cat "$DPM_GIT_TOKEN_FILE" ;;
    *) exit 1 ;;
esac
EOF
    chmod 0700 "$askpass_script"
    GIT_ENV+=("GIT_ASKPASS=$askpass_script" "DPM_GIT_USERNAME=$GIT_USERNAME" "DPM_GIT_TOKEN_FILE=$GITHUB_TOKEN_FILE")
fi

git_with_auth() {
    env "${GIT_ENV[@]}" git -c "safe.directory=$SITE_DIR" "$@"
}

git_local() {
    git -c "safe.directory=$SITE_DIR" -C "$SITE_DIR" "$@"
}

step "Cloning or updating $PROJECT_NAME"
if [[ -d "$SITE_DIR/.git" ]]; then
    if [[ -n "$(git_local status --porcelain --untracked-files=no)" ]]; then
        error "$SITE_DIR has uncommitted tracked changes. Commit or resolve them before deployment."
        exit 1
    fi
    existing_origin="$(git_local remote get-url origin)"
    if [[ "$existing_origin" != "$REPO_URL" ]]; then
        error "Existing origin does not match the configuration."
        echo "Existing: $existing_origin"
        echo "Expected: $REPO_URL"
        exit 1
    fi
    git_with_auth -C "$SITE_DIR" fetch --prune origin
    if git_local show-ref --verify --quiet "refs/heads/$GIT_BRANCH"; then
        git_local checkout "$GIT_BRANCH"
    else
        git_local checkout -b "$GIT_BRANCH" --track "origin/$GIT_BRANCH"
    fi
    git_local merge --ff-only "origin/$GIT_BRANCH"
elif [[ -e "$SITE_DIR" ]]; then
    error "$SITE_DIR exists but is not a Git repository."
    exit 1
else
    install -d -m 0750 "$(dirname "$SITE_DIR")"
    git_with_auth clone --branch "$GIT_BRANCH" --single-branch "$REPO_URL" "$SITE_DIR"
fi

chown -R "$NEW_USER:$NEW_USER" "$SITE_DIR"

if [[ -n "$APP_ENV_SOURCE" ]]; then
    require_root_secret_file "$APP_ENV_SOURCE" "APP_ENV_SOURCE"
    install -m 0600 -o "$NEW_USER" -g "$NEW_USER" "$APP_ENV_SOURCE" "$SITE_DIR/.env"
elif [[ ! -s "$SITE_DIR/.env" ]]; then
    error "No production .env exists. Set APP_ENV_SOURCE to a root-protected secrets file."
    exit 1
fi

upsert_env_value() {
    local key="$1"
    local value="$2"
    local env_file="$SITE_DIR/.env"
    sed -i "/^${key}=/d" "$env_file"
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
}

upsert_env_value COMPOSE_PROJECT_NAME "$PROJECT_NAME"
upsert_env_value SITE_PORT "$SITE_PORT"
chown "$NEW_USER:$NEW_USER" "$SITE_DIR/.env"
chmod 0600 "$SITE_DIR/.env"

COMPOSE_PATH="$SITE_DIR/$COMPOSE_FILE"
if [[ ! -f "$COMPOSE_PATH" ]]; then
    error "Compose file not found: $COMPOSE_PATH"
    exit 1
fi

step "Validating the production Compose network boundary"
compose_json="$(mktemp)"
chmod 0600 "$compose_json"
(
    cd "$SITE_DIR"
    docker compose -f "$COMPOSE_FILE" config --format json > "$compose_json"
)

if jq -e '.services[]?.ports[]? | select((.host_ip // "0.0.0.0") == "0.0.0.0" or (.host_ip // "") == "::")' "$compose_json" >/dev/null; then
    error "The Compose file publishes at least one container port on every network interface."
    error "Production website ports must bind to 127.0.0.1 only."
    exit 1
fi

if ! jq -e --arg port "$SITE_PORT" '.services[]?.ports[]? | select((.host_ip // "") == "127.0.0.1" and (.published | tostring) == $port and (.target | tostring) == "80")' "$compose_json" >/dev/null; then
    error "No container publishes 127.0.0.1:$SITE_PORT to container port 80."
    error "Apply the host-gateway Compose template before deploying."
    exit 1
fi
rm -f "$compose_json"
compose_json=""

step "Building and starting containers"
(
    cd "$SITE_DIR"
    docker compose -f "$COMPOSE_FILE" up -d --build
    docker compose -f "$COMPOSE_FILE" ps
)

step "Waiting for the website ingress"
site_ready="no"
for _ in {1..30}; do
    if curl -fsS --max-time 4 "http://127.0.0.1:$SITE_PORT/" >/dev/null; then
        site_ready="yes"
        break
    fi
    sleep 2
done
if [[ "$site_ready" != "yes" ]]; then
    error "The containers started, but 127.0.0.1:$SITE_PORT did not become healthy."
    echo "Inspect with: cd $SITE_DIR && docker compose logs --tail=100"
    exit 1
fi

site_args=(--domain "$DOMAIN" --port "$SITE_PORT")
if [[ "$INCLUDE_WWW" == "yes" ]]; then
    site_args+=(--www)
fi
if [[ "$ENABLE_SSL" == "yes" ]]; then
    site_args+=(--ssl --email "$SSL_EMAIL")
fi
bash "$SCRIPT_DIR/add_docker_site.sh" "${site_args[@]}"

success "$PROJECT_NAME is deployed from $REPO_URL"
echo "Project directory: $SITE_DIR"
if [[ "$ENABLE_SSL" == "yes" ]]; then
    echo "Domain: https://$DOMAIN"
else
    echo "Domain: http://$DOMAIN"
fi
