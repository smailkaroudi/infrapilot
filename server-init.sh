#!/bin/bash

# Simple Single-App Deployment System
# Usage: curl -fsSL https://my-domain.com/server-init.sh | bash
#
# Deploys one application at a time with interactive prompts.
# Run the script multiple times for multiple apps.

set -euo pipefail

# ============================================================================
# CONFIGURATION & CONSTANTS
# ============================================================================

DEPLOY_DIR="/opt/deployment"
ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"
ENV="${ENV:-prod}"

# App configuration variables (set via prompts)
APP_NAME=""
REPO_URL=""
BRANCH=""
DOMAIN_URL=""
IMAGE_NAME=""
APP_PORT=""
GIT_TOKEN=""
GIT_USERNAME=""
GIT_PASSWORD=""
declare -A ENV_OVERRIDES

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS. This script supports Ubuntu/Debian only."
        exit 1
    fi
    
    . /etc/os-release
    
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        log_error "This script supports Ubuntu/Debian only. Detected: $ID"
        exit 1
    fi
    
    log_info "Detected OS: $PRETTY_NAME"
}

# ============================================================================
# PROMPT FUNCTIONS
# ============================================================================

prompt_input() {
    local prompt_text="$1"
    local default_value="${2:-}"
    local is_secret="${3:-false}"
    local var_name="$4"
    
    local input=""
    if [[ "$is_secret" == "true" ]]; then
        read -sp "$prompt_text${default_value:+ [default: $default_value]}${default_value:+]: }" input < /dev/tty
        echo ""
    else
        read -p "$prompt_text${default_value:+ [default: $default_value]}${default_value:+]: }" input < /dev/tty
    fi
    
    if [[ -z "$input" ]] && [[ -n "$default_value" ]]; then
        input="$default_value"
    fi
    
    eval "$var_name='$input'"
}

prompt_git_credentials() {
    local repo_url="$1"
    
    if ! GIT_TERMINAL_PROMPT=0 timeout 5 git ls-remote --heads "$repo_url" > /dev/null 2>&1; then
        log_warn "Repository appears to be private or requires authentication."
        echo ""
        echo "Choose authentication method:"
        echo "  1) Personal Access Token (Recommended)"
        echo "  2) Username and Password"
        echo "  3) Skip (will try without credentials)"
        read -p "Enter choice [1-3]: " auth_choice < /dev/tty
        
        case "$auth_choice" in
            1)
                prompt_input "Personal Access Token: " "" true "GIT_TOKEN"
                ;;
            2)
                prompt_input "Git Username: " "" false "GIT_USERNAME"
                prompt_input "Git Password: " "" true "GIT_PASSWORD"
                ;;
            3)
                log_info "Skipping credentials. Will attempt without authentication."
                ;;
        esac
    fi
}

prompt_app_config() {
    log_info "Step 2/3: Application Configuration"
    log_info "Deploy one application at a time. Run this script again for additional apps."
    echo ""
    
    prompt_input "App Name: " "" false "APP_NAME"
    [[ -z "$APP_NAME" ]] && { log_error "App name is required"; exit 1; }
    
    prompt_input "Repository URL (HTTPS, e.g., https://github.com/user/repo.git): " "" false "REPO_URL"
    [[ -z "$REPO_URL" ]] && { log_error "Repository URL is required"; exit 1; }
    
    if [[ "$REPO_URL" == git@* ]] || [[ "$REPO_URL" == ssh://* ]]; then
        log_error "SSH URLs are not supported. Please use HTTPS URL."
        exit 1
    fi
    
    # Validate URL format
    if [[ ! "$REPO_URL" =~ ^https:// ]]; then
        log_error "Repository URL must start with https://"
        exit 1
    fi
    
    # Extract username from URL if present
    if [[ "$REPO_URL" =~ ^https://([^@]+)@ ]]; then
        EXTRACTED_USERNAME="${BASH_REMATCH[1]}"
        # Store extracted username for later use with token
        if [[ -z "$GIT_USERNAME" ]]; then
            GIT_USERNAME="$EXTRACTED_USERNAME"
        fi
    fi
    
    prompt_input "Branch: " "main" false "BRANCH"
    
    prompt_input "Domain URL (e.g., app.example.com): " "" false "DOMAIN_URL"
    [[ -z "$DOMAIN_URL" ]] && { log_error "Domain URL is required"; exit 1; }
    
    # Remove protocol and path if user included them
    DOMAIN_URL=$(echo "$DOMAIN_URL" | sed 's|^https://||' | sed 's|^http://||' | sed 's|/.*||')
    
    # Validate domain format (basic check)
    if [[ "$DOMAIN_URL" =~ / ]]; then
        log_warn "Domain URL should not include paths. Using only domain: ${DOMAIN_URL%%/*}"
        DOMAIN_URL="${DOMAIN_URL%%/*}"
    fi
    
    prompt_input "Docker Image Name (e.g., myapp): " "$APP_NAME" false "IMAGE_NAME"
    [[ -z "$IMAGE_NAME" ]] && IMAGE_NAME="$APP_NAME"
    
    prompt_input "Application Port: " "3000" false "APP_PORT"
    if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then
        log_error "Port must be a number"
        exit 1
    fi
    
    echo ""
    echo "Environment options:"
    echo "  1) prod (Production)"
    echo "  2) staging (Staging)"
    echo "  3) dev (Development)"
    read -p "Select environment [1-3, default: prod]: " env_choice < /dev/tty
    case "$env_choice" in
        1|"") ENV="prod" ;;
        2) ENV="staging" ;;
        3) ENV="dev" ;;
        *) ENV="prod" ;;
    esac
    
    prompt_input "Email for SSL certificates (Let's Encrypt): " "$ACME_EMAIL" false "ACME_EMAIL"
    
    echo ""
    log_info "Checking repository access..."
    prompt_git_credentials "$REPO_URL"
    
    echo ""
    log_info "Environment Variables"
    log_info "You can override variables from .env.example. Leave empty to skip."
    log_info "Press Enter after each variable, or type 'done' to finish."
    echo ""
    
    while true; do
        read -p "Environment variable (KEY=VALUE or 'done' to finish): " env_var < /dev/tty
        if [[ "$env_var" == "done" ]] || [[ -z "$env_var" ]]; then
            break
        fi
        if [[ "$env_var" == *"="* ]]; then
            key="${env_var%%=*}"
            value="${env_var#*=}"
            ENV_OVERRIDES["$key"]="$value"
            log_info "  Added: $key=$value"
        else
            log_warn "Invalid format. Use KEY=VALUE"
        fi
    done
    
    echo ""
    log_info "Configuration Summary:"
    log_info "  App Name: $APP_NAME"
    log_info "  Repository: $REPO_URL"
    log_info "  Branch: $BRANCH"
    log_info "  Domain: $DOMAIN_URL"
    log_info "  Image Name: $IMAGE_NAME"
    log_info "  Port: $APP_PORT"
    log_info "  Environment: $ENV"
    log_info "  ACME Email: $ACME_EMAIL"
    if [[ ${#ENV_OVERRIDES[@]} -gt 0 ]]; then
        log_info "  Environment Overrides:"
        for key in "${!ENV_OVERRIDES[@]}"; do
            log_info "    $key=${ENV_OVERRIDES[$key]}"
        done
    fi
    
    echo ""
    read -p "Continue with deployment? [Y/n]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        log_info "Deployment cancelled by user"
        exit 0
    fi
}

# ============================================================================
# SYSTEM SETUP FUNCTIONS
# ============================================================================

setup_system_packages() {
    log_info "Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
    
    log_info "Installing essential packages..."
    apt-get install -y -qq \
        curl \
        wget \
        git \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        ufw \
        jq
}

setup_docker() {
    if command -v docker &> /dev/null; then
        log_info "Docker is already installed"
        return 0
    fi
    
    log_info "Installing Docker..."
    
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    systemctl start docker
    systemctl enable docker
    
    log_info "Docker installed successfully"
}

verify_docker_compose() {
    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose is not available"
        exit 1
    fi
    log_info "Docker Compose version: $(docker compose version)"
}

setup_firewall() {
    log_info "Configuring UFW firewall..."
    if ! command -v ufw &> /dev/null; then
        log_warn "UFW not available, skipping firewall configuration"
        return 0
    fi
    
    if ufw status | grep -q "Status: active"; then
        log_info "UFW is already active, ensuring rules are present..."
        ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
        ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true
        ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || true
    else
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 22/tcp comment 'SSH'
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
        ufw --force enable
        log_info "Firewall configured: ports 22, 80, 443 allowed"
    fi
}

setup_server() {
    log_info "Step 1/3: Setting up server environment..."
    echo ""
    
    setup_system_packages
    setup_docker
    verify_docker_compose
    setup_firewall
    
    echo ""
    log_info "✅ Server setup complete!"
    echo ""
}

# ============================================================================
# GIT FUNCTIONS
# ============================================================================

prepare_repo_url() {
    local repo_url="$1"
    local auth_url="$repo_url"
    
    # Extract domain and path from URL (may include username)
    if [[ "$repo_url" =~ ^https://([^/]+)/(.+)$ ]]; then
        local domain_with_user="${BASH_REMATCH[1]}"
        local path="${BASH_REMATCH[2]}"
        
        # Extract username and domain
        local username=""
        local domain=""
        if [[ "$domain_with_user" =~ ^([^@]+)@(.+)$ ]]; then
            username="${BASH_REMATCH[1]}"
            domain="${BASH_REMATCH[2]}"
        else
            domain="$domain_with_user"
        fi
        
        # Remove .git suffix if present for path manipulation
        path=$(echo "$path" | sed 's|\.git$||')
        
        if [[ -n "$GIT_TOKEN" ]]; then
            # Token provided - use it for authentication
            if [[ -n "$username" ]]; then
                # If username is in URL, use username:token format (Bitbucket App Password style)
                auth_url="https://${username}:${GIT_TOKEN}@${domain}/${path}.git"
            elif [[ "$domain" == *"bitbucket.org"* ]] || [[ "$domain" == *"bitbucket"* ]]; then
                # Bitbucket without username in URL - use x-token-auth format
                auth_url="https://x-token-auth:${GIT_TOKEN}@${domain}/${path}.git"
            else
                # GitHub/GitLab format: https://TOKEN@domain/path.git
                auth_url="https://${GIT_TOKEN}@${domain}/${path}.git"
            fi
        elif [[ -n "$GIT_USERNAME" ]] && [[ -n "$GIT_PASSWORD" ]]; then
            # Use provided username and password
            auth_url="https://${GIT_USERNAME}:${GIT_PASSWORD}@${domain}/${path}.git"
        elif [[ -n "$username" ]]; then
            # URL has username but no credentials provided - keep as-is
            # Git will prompt for password if needed
            if [[ ! "$auth_url" =~ \.git$ ]]; then
                auth_url="${auth_url}.git"
            fi
            echo "$auth_url"
            return 0
        fi
        
        # Ensure .git suffix
        if [[ ! "$auth_url" =~ \.git$ ]]; then
            auth_url="${auth_url}.git"
        fi
    fi
    
    echo "$auth_url"
}

configure_git() {
    if [[ -n "$GIT_TOKEN" ]] || [[ -n "$GIT_USERNAME" ]]; then
        git config --global credential.helper store
        git config --global credential.helper 'cache --timeout=3600'
    fi
}

clone_or_update_repo() {
    local app_dir="$1"
    local repo_url="$2"
    local branch="$3"
    
    cd "$app_dir"
    
    if [[ -d ".git" ]]; then
        log_info "Repository exists, updating..."
        local current_remote=$(git remote get-url origin 2>/dev/null || echo "")
        local auth_url=$(prepare_repo_url "$repo_url")
        
        if [[ "$current_remote" != "$auth_url" ]] && [[ "$auth_url" != "$repo_url" ]]; then
            git remote set-url origin "$auth_url"
        fi
        
        GIT_TERMINAL_PROMPT=0 git fetch origin || {
            log_error "Failed to fetch from repository"
            exit 1
        }
        
        if git ls-remote --heads origin "$branch" | grep -q "$branch"; then
            git checkout "$branch" 2>/dev/null || git checkout -b "$branch" "origin/$branch"
            git reset --hard "origin/$branch"
            git clean -fd
            log_info "Repository updated to branch: $branch"
        else
            log_error "Branch $branch does not exist"
            exit 1
        fi
    else
        log_info "Cloning repository..."
        local auth_url=$(prepare_repo_url "$repo_url")
        GIT_TERMINAL_PROMPT=0 git clone -b "$branch" "$auth_url" . || {
            log_error "Failed to clone repository"
            exit 1
        }
        log_info "Repository cloned successfully"
    fi
}

# ============================================================================
# ENVIRONMENT FILE FUNCTIONS
# ============================================================================

create_env_file() {
    local app_dir="$1"
    
    log_info "Creating .env file..."
    
    if [[ -f "$app_dir/.env.example" ]]; then
        cp "$app_dir/.env.example" "$app_dir/.env"
        log_info "Copied .env.example to .env"
        
        for key in "${!ENV_OVERRIDES[@]}"; do
            local value="${ENV_OVERRIDES[$key]}"
            if grep -q "^${key}=" "$app_dir/.env" 2>/dev/null; then
                sed -i "s|^${key}=.*|${key}=${value}|" "$app_dir/.env"
                log_info "  Updated: $key=$value"
            else
                echo "${key}=${value}" >> "$app_dir/.env"
                log_info "  Added: $key=$value"
            fi
        done
    else
        log_warn "No .env.example found, creating empty .env"
        touch "$app_dir/.env"
        for key in "${!ENV_OVERRIDES[@]}"; do
            echo "${key}=${ENV_OVERRIDES[$key]}" >> "$app_dir/.env"
        done
    fi
    
    if ! grep -q "^ENV=" "$app_dir/.env" 2>/dev/null; then
        echo "ENV=$ENV" >> "$app_dir/.env"
    fi
}

# ============================================================================
# DOCKER COMPOSE FUNCTIONS
# ============================================================================

generate_docker_compose() {
    local app_dir="$1"
    local app_name="$2"
    local image_name="$3"
    local domain_url="$4"
    local app_port="$5"
    local acme_email="$6"
    
    log_info "Generating docker-compose.yml..."
    
    # Find an available port on host
    local host_port=$(find_available_port)
    
    cat > "$app_dir/docker-compose.yml" << EOF
version: '3.8'

services:
  ${app_name}:
    build:
      context: .
      dockerfile: Dockerfile
    image: ${image_name}:latest
    container_name: ${app_name}
    restart: unless-stopped
    ports:
      - "${host_port}:${app_port}"
    env_file:
      - .env
    environment:
      - VIRTUAL_HOST=${domain_url}
      - VIRTUAL_PORT=${app_port}
      - LETSENCRYPT_HOST=${domain_url}
      - LETSENCRYPT_EMAIL=${acme_email}
    networks:
      - nginx-proxy-network
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:${app_port}/health || wget --no-verbose --tries=1 --spider http://localhost:${app_port}/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  nginx-proxy-network:
    external: true
    name: nginx_nginx-proxy-network
EOF
    
    # Store host port for Nginx config
    echo "$host_port" > "$app_dir/.host_port"
    
    log_info "docker-compose.yml generated (host port: $host_port)"
}

find_available_port() {
    local port=8000
    while netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "; do
        port=$((port + 1))
        if [[ $port -gt 9999 ]]; then
            log_error "Could not find available port"
            exit 1
        fi
    done
    echo "$port"
}

# ============================================================================
# NGINX PROXY FUNCTIONS
# ============================================================================

setup_nginx_proxy() {
    local deploy_dir="$1"
    local acme_email="$2"
    
    if [[ -d "$deploy_dir/nginx" ]]; then
        return 0
    fi
    
    log_info "Setting up Nginx reverse proxy with automatic SSL..."
    mkdir -p "$deploy_dir/nginx"
    
    cat > "$deploy_dir/nginx/docker-compose.yml" << NGINX_COMPOSE
version: '3.8'

services:
  nginx-proxy:
    image: nginxproxy/nginx-proxy:latest
    container_name: nginx-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/tmp/docker.sock:ro
      - ./certs:/etc/nginx/certs:ro
      - ./vhost.d:/etc/nginx/vhost.d
      - ./html:/usr/share/nginx/html
      - ./conf.d:/etc/nginx/conf.d
    networks:
      - nginx-proxy-network
    labels:
      - "com.github.nginx-proxy.nginx-proxy"

  acme-companion:
    image: nginxproxy/acme-companion:latest
    container_name: nginx-proxy-acme
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./certs:/etc/nginx/certs:rw
      - ./vhost.d:/etc/nginx/vhost.d
      - ./acme.sh:/etc/acme.sh
      - ./html:/usr/share/nginx/html
    networks:
      - nginx-proxy-network
    depends_on:
      - nginx-proxy
    environment:
      - DEFAULT_EMAIL=${acme_email}
      - NGINX_PROXY_CONTAINER=nginx-proxy

networks:
  nginx-proxy-network:
    driver: bridge
NGINX_COMPOSE
    
    mkdir -p "$deploy_dir/nginx"/{certs,vhost.d,html,conf.d,acme.sh}
    
    log_info "Starting Nginx reverse proxy..."
    cd "$deploy_dir/nginx"
    
    if docker ps | grep -q nginx-proxy; then
        log_info "Nginx proxy is already running, updating..."
        docker compose pull
        docker compose up -d
    else
        docker compose pull
        docker compose up -d
    fi
    
    log_info "Waiting for Nginx proxy to be ready..."
    for i in {1..30}; do
        if docker ps | grep -q nginx-proxy; then
            log_info "Nginx proxy is running"
            break
        fi
        sleep 1
    done
}

get_nginx_network_name() {
    local network_name=$(docker network ls --format "{{.Name}}" | grep -E "nginx.*proxy.*network|nginx-proxy-network" | head -n 1)
    if [[ -z "$network_name" ]]; then
        network_name="nginx_nginx-proxy-network"
    fi
    echo "$network_name"
}

setup_nginx_server_block() {
    local domain_url="$1"
    local host_port="$2"
    local app_name="$3"
    
    log_info "Creating Nginx server block for $domain_url..."
    
    # Install Nginx if not installed
    if ! command -v nginx &> /dev/null; then
        log_info "Installing Nginx..."
        apt-get update -qq
        apt-get install -y -qq nginx
    fi
    
    # Create server block configuration
    local config_file="/etc/nginx/sites-available/${app_name}"
    
    cat > "$config_file" << NGINX_CONFIG
server {
    listen 80;
    server_name ${domain_url};

    location / {
        proxy_pass http://127.0.0.1:${host_port}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_CONFIG
    
    # Enable site
    if [[ ! -L "/etc/nginx/sites-enabled/${app_name}" ]]; then
        ln -s "$config_file" "/etc/nginx/sites-enabled/${app_name}"
        log_info "Enabled Nginx site: ${app_name}"
    fi
    
    # Test Nginx configuration
    if nginx -t &> /dev/null; then
        systemctl reload nginx
        log_info "Nginx configuration reloaded"
    else
        log_warn "Nginx configuration test failed, but continuing..."
    fi
}

# ============================================================================
# DEPLOYMENT FUNCTIONS
# ============================================================================

deploy_application() {
    local app_dir="$1"
    local app_name="$2"
    local image_name="$3"
    local domain_url="$4"
    local app_port="$5"
    local nginx_network="$6"
    
    log_info "Building Docker image..."
    cd "$app_dir"
    
    docker compose build --pull || {
        log_error "Failed to build Docker image"
        exit 1
    }
    
    log_info "Starting application container..."
    docker compose up -d || {
        log_error "Failed to start container"
        exit 1
    }
    
    local container_id=$(docker compose ps -q)
    if [[ -n "$container_id" ]]; then
        docker network connect "$nginx_network" "$container_id" 2>/dev/null || true
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Header
    echo ""
    log_info "=========================================="
    log_info "Server Setup & Deployment System"
    log_info "=========================================="
    echo ""
    
    # Validation
    check_root
    check_os
    
    # Step 1: Server Setup
    setup_server
    
    # Step 2: Application Configuration
    prompt_app_config
    
    # Step 3: Deployment
    log_info "Step 3/3: Deploying application..."
    echo ""
    
    # Configure Git
    configure_git
    
    # Setup directories
    log_info "Setting up deployment directory: $DEPLOY_DIR"
    mkdir -p "$DEPLOY_DIR"
    
    local app_dir="$DEPLOY_DIR/apps/$APP_NAME"
    mkdir -p "$app_dir"
    
    # Clone repository
    clone_or_update_repo "$app_dir" "$REPO_URL" "$BRANCH"
    
    # Check for Dockerfile
    if [[ ! -f "$app_dir/Dockerfile" ]]; then
        log_error "Dockerfile not found in repository"
        exit 1
    fi
    
    # Create .env file
    create_env_file "$app_dir"
    
    # Generate docker-compose.yml
    generate_docker_compose "$app_dir" "$APP_NAME" "$IMAGE_NAME" "$DOMAIN_URL" "$APP_PORT" "$ACME_EMAIL"
    
    # Setup Nginx proxy (Docker container for SSL)
    setup_nginx_proxy "$DEPLOY_DIR" "$ACME_EMAIL"
    
    # Get Nginx network name and update docker-compose.yml
    local nginx_network=$(get_nginx_network_name)
    sed -i "s|name: nginx_nginx-proxy-network|name: ${nginx_network}|" "$app_dir/docker-compose.yml"
    
    # Deploy application
    deploy_application "$app_dir" "$APP_NAME" "$IMAGE_NAME" "$DOMAIN_URL" "$APP_PORT" "$nginx_network"
    
    # Get host port and setup Nginx server block
    local host_port=$(cat "$app_dir/.host_port" 2>/dev/null || echo "$APP_PORT")
    setup_nginx_server_block "$DOMAIN_URL" "$host_port" "$APP_NAME"
    
    # Success message
    echo ""
    log_info "=========================================="
    log_info "Deployment completed successfully!"
    log_info "=========================================="
    log_info "Application: $APP_NAME"
    log_info "Domain: https://$DOMAIN_URL"
    log_info "Image: $IMAGE_NAME:latest"
    log_info "Port: $APP_PORT"
    log_info "Environment: $ENV"
    log_info ""
    log_info "To view logs: docker logs $APP_NAME"
    log_info "To restart: docker restart $APP_NAME"
    log_info "=========================================="
}

# Run main function
main
