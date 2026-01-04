#!/bin/bash

#
# Maillayer One-Command Installer
# https://maillayer.com
#
# Usage:
#   curl -fsSL https://get.maillayer.com/install.sh | sudo bash
#
# The installer will prompt for your license key and domain.
#
# Or with options (non-interactive):
#   curl -fsSL https://get.maillayer.com/install.sh | sudo bash -s -- \
#     --license XXXX-XXXX-XXXX-XXXX \
#     --domain mail.example.com
#

set -e

# ============================================================================
# Configuration
# ============================================================================

MAILLAYER_VERSION="${MAILLAYER_VERSION:-latest}"
INSTALL_DIR="/opt/maillayer"
LICENSE_API="https://maillayer.com/api/license"
# Public repo where releases are hosted (not source code)
GITHUB_REPO="mddanishyusuf/maillayer-releases"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download"
NODE_VERSION="20"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ============================================================================
# Helper Functions
# ============================================================================

print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
    __  ___      _ ____
   /  |/  /___ _(_) / /___ ___  _____  _____
  / /|_/ / __ `/ / / / __ `/ / / / _ \/ ___/
 / /  / / /_/ / / / / /_/ / /_/ /  __/ /
/_/  /_/\__,_/_/_/_/\__,_/\__, /\___/_/
                         /____/
EOF
    echo -e "${NC}"
    echo -e "${BOLD}One-Command Installer${NC}"
    echo ""
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}[$1/$TOTAL_STEPS]${NC} ${BOLD}$2${NC}"
}

generate_secret() {
    openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================================
# License Verification
# ============================================================================

verify_license() {
    log_info "Verifying license key..."

    # Get server info
    local server_ip=$(curl -s ifconfig.me 2>/dev/null || echo "unknown")
    local hostname=$(hostname)

    # Call license API
    local response=$(curl -s -X POST "${LICENSE_API}/verify" \
        -H "Content-Type: application/json" \
        -d "{
            \"license_key\": \"${LICENSE_KEY}\",
            \"domain\": \"${DOMAIN:-$hostname}\",
            \"ip\": \"${server_ip}\",
            \"action\": \"install\"
        }" 2>&1)

    # Check if curl failed
    if [[ $? -ne 0 ]]; then
        log_error "Failed to connect to license server"
        log_error "Please check your internet connection and try again"
        exit 1
    fi

    # Parse response
    local valid=$(echo "$response" | grep -o '"valid":\s*true' || echo "")
    local error=$(echo "$response" | grep -o '"error":"[^"]*"' | cut -d'"' -f4 || echo "")
    local message=$(echo "$response" | grep -o '"message":"[^"]*"' | cut -d'"' -f4 || echo "")

    if [[ -z "$valid" ]]; then
        log_error "License verification failed"
        if [[ -n "$message" ]]; then
            log_error "$message"
        fi
        if [[ -n "$error" ]]; then
            case "$error" in
                "invalid_license")
                    echo -e "\n${YELLOW}Your license key was not found.${NC}"
                    echo "Please check your key and try again."
                    echo "Purchase a license at: https://maillayer.com/pricing"
                    ;;
                "license_already_used")
                    echo -e "\n${YELLOW}This license is already activated on another server.${NC}"
                    echo "Each license can only be used on one server."
                    echo "To move your license, deactivate it first at: https://maillayer.com/account"
                    ;;
                "license_expired")
                    echo -e "\n${YELLOW}Your license has expired.${NC}"
                    echo "Renew your license at: https://maillayer.com/account"
                    ;;
                "license_suspended")
                    echo -e "\n${YELLOW}Your license has been suspended.${NC}"
                    echo "Please contact support: support@maillayer.com"
                    ;;
                *)
                    echo -e "\nError: $error"
                    ;;
            esac
        fi
        exit 1
    fi

    # Extract info from response
    LICENSED_EMAIL=$(echo "$response" | grep -o '"email":"[^"]*"' | cut -d'"' -f4 || echo "")
    DOWNLOAD_TOKEN=$(echo "$response" | grep -o '"download_token":"[^"]*"' | cut -d'"' -f4 || echo "")

    log_success "License verified successfully"
    if [[ -n "$LICENSED_EMAIL" ]]; then
        log_info "Licensed to: $LICENSED_EMAIL"
    fi
}

# ============================================================================
# System Checks
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

prompt_license() {
    if [[ -z "$LICENSE_KEY" ]]; then
        echo ""
        echo -e "${BOLD}License Key${NC}"
        echo "Enter your Maillayer license key."
        echo "Don't have one? Purchase at: https://maillayer.com/pricing"
        echo ""
        read -p "License Key (XXXX-XXXX-XXXX-XXXX): " LICENSE_KEY

        if [[ -z "$LICENSE_KEY" ]]; then
            log_error "License key is required"
            exit 1
        fi
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. This installer supports Ubuntu 20.04+ and Debian 11+"
        exit 1
    fi

    case $OS in
        ubuntu)
            if [[ "${VERSION%%.*}" -lt 20 ]]; then
                log_error "Ubuntu 20.04 or higher is required"
                exit 1
            fi
            ;;
        debian)
            if [[ "${VERSION%%.*}" -lt 11 ]]; then
                log_error "Debian 11 or higher is required"
                exit 1
            fi
            ;;
        *)
            log_warning "Untested OS: $OS $VERSION. Proceeding anyway..."
            ;;
    esac
}

check_memory() {
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $TOTAL_MEM -lt 1800 ]]; then
        log_warning "Less than 2GB RAM detected (${TOTAL_MEM}MB). Performance may be affected."
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

check_ports() {
    for port in 80 443; do
        if ss -tuln | grep -q ":$port "; then
            log_error "Port $port is already in use. Please stop the service using it."
            log_info "You can check what's using it with: sudo lsof -i :$port"
            exit 1
        fi
    done
}

# ============================================================================
# Installation Functions
# ============================================================================

install_dependencies() {
    log_info "Installing system dependencies..."
    apt-get update -qq
    apt-get install -y -qq curl wget git openssl ca-certificates gnupg >/dev/null
    log_success "Dependencies installed"
}

install_nodejs() {
    if command_exists node; then
        local current_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [[ "$current_version" -ge "$NODE_VERSION" ]]; then
            log_success "Node.js $(node -v) is already installed"
            return
        fi
    fi

    log_info "Installing Node.js ${NODE_VERSION}..."

    # Install Node.js via NodeSource
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - >/dev/null 2>&1
    apt-get install -y -qq nodejs >/dev/null

    log_success "Node.js $(node -v) installed"
}

install_pm2() {
    if command_exists pm2; then
        log_success "PM2 is already installed"
        return
    fi

    log_info "Installing PM2..."
    npm install -g pm2 >/dev/null 2>&1
    log_success "PM2 installed"
}

install_mongodb() {
    if command_exists mongod; then
        log_success "MongoDB is already installed"
        return
    fi

    log_info "Installing MongoDB..."

    # Import MongoDB public GPG key
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
        gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor

    # Add MongoDB repository
    echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | \
        tee /etc/apt/sources.list.d/mongodb-org-7.0.list >/dev/null

    # Install MongoDB
    apt-get update -qq
    apt-get install -y -qq mongodb-org >/dev/null

    # Start and enable MongoDB
    systemctl start mongod
    systemctl enable mongod

    log_success "MongoDB installed and started"
}

install_redis() {
    if command_exists redis-server; then
        log_success "Redis is already installed"
        return
    fi

    log_info "Installing Redis..."

    apt-get install -y -qq redis-server >/dev/null

    # Configure Redis
    sed -i 's/supervised no/supervised systemd/' /etc/redis/redis.conf

    # Start and enable Redis
    systemctl restart redis-server
    systemctl enable redis-server

    log_success "Redis installed and started"
}

install_caddy() {
    if command_exists caddy; then
        log_success "Caddy is already installed"
        return
    fi

    log_info "Installing Caddy..."

    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https >/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null

    apt-get update -qq
    apt-get install -y -qq caddy >/dev/null

    # Stop default Caddy service (we'll configure it manually)
    systemctl stop caddy

    log_success "Caddy installed"
}

get_latest_version() {
    if [[ "$MAILLAYER_VERSION" == "latest" ]]; then
        log_info "Fetching latest version..."
        MAILLAYER_VERSION=$(curl -s "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | \
            grep '"tag_name"' | cut -d'"' -f4)

        if [[ -z "$MAILLAYER_VERSION" ]]; then
            log_error "Failed to fetch latest version"
            exit 1
        fi
    fi
    log_info "Version: $MAILLAYER_VERSION"
}

download_maillayer() {
    log_info "Downloading Maillayer..."

    local download_url="${DOWNLOAD_URL}/${MAILLAYER_VERSION}/maillayer.tar.gz"

    # Create temp directory
    local temp_dir=$(mktemp -d)

    # Download tarball
    if ! curl -fsSL "$download_url" -o "$temp_dir/maillayer.tar.gz"; then
        log_error "Failed to download Maillayer"
        log_error "URL: $download_url"
        rm -rf "$temp_dir"
        exit 1
    fi

    # Extract to install directory
    mkdir -p "$INSTALL_DIR"
    tar -xzf "$temp_dir/maillayer.tar.gz" -C "$INSTALL_DIR" --strip-components=1

    # Cleanup
    rm -rf "$temp_dir"

    log_success "Maillayer downloaded and extracted"
}

install_npm_dependencies() {
    log_info "Installing application dependencies..."

    cd "$INSTALL_DIR"
    npm ci --only=production --silent

    log_success "Dependencies installed"
}

create_env_file() {
    log_info "Generating environment configuration..."

    NEXTAUTH_SECRET=$(generate_secret)
    TRACKING_SECRET=$(generate_secret)

    if [[ "$SKIP_SSL" == "true" || "$DOMAIN" == "localhost" ]]; then
        BASE_URL="http://${DOMAIN:-localhost}"
    else
        BASE_URL="https://${DOMAIN}"
    fi

    cat > "$INSTALL_DIR/.env" << ENVFILE
# Maillayer Configuration
# Generated on $(date)

# Application
NODE_ENV=production
BASE_URL=${BASE_URL}

# License
LICENSE_KEY=${LICENSE_KEY}

# Database
MONGODB_URI=mongodb://127.0.0.1:27017/maillayer
REDIS_URL=redis://127.0.0.1:6379

# Security Secrets (auto-generated, do not share)
NEXTAUTH_SECRET=${NEXTAUTH_SECRET}
TRACKING_SECRET=${TRACKING_SECRET}

# Version
MAILLAYER_VERSION=${MAILLAYER_VERSION}
ENVFILE

    chmod 600 "$INSTALL_DIR/.env"

    log_success "Environment file created"
}

create_caddyfile() {
    log_info "Creating Caddy configuration..."

    if [[ "$SKIP_SSL" == "true" || "$DOMAIN" == "localhost" ]]; then
        cat > /etc/caddy/Caddyfile << CADDYFILE
:80 {
    reverse_proxy 127.0.0.1:3000
}
CADDYFILE
    else
        cat > /etc/caddy/Caddyfile << CADDYFILE
${DOMAIN} {
    reverse_proxy 127.0.0.1:3000

    encode gzip

    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
    }
}
CADDYFILE
    fi

    log_success "Caddy configuration created"
}

setup_pm2() {
    log_info "Setting up PM2..."

    cd "$INSTALL_DIR"

    # Start with PM2
    pm2 start ecosystem.config.js --env production

    # Save PM2 process list
    pm2 save

    # Setup PM2 startup script
    pm2 startup systemd -u root --hp /root >/dev/null 2>&1

    log_success "PM2 configured"
}

start_services() {
    log_info "Starting services..."

    # Start Caddy
    systemctl start caddy
    systemctl enable caddy

    log_success "All services started"
}

create_cli() {
    log_info "Creating maillayer CLI command..."

    cat > /usr/local/bin/maillayer << 'CLIMD'
#!/bin/bash

INSTALL_DIR="/opt/maillayer"

case "$1" in
    start)
        echo "Starting Maillayer..."
        cd $INSTALL_DIR && pm2 start ecosystem.config.js --env production
        sudo systemctl start caddy
        echo "Maillayer started!"
        ;;
    stop)
        echo "Stopping Maillayer..."
        pm2 stop all
        sudo systemctl stop caddy
        echo "Maillayer stopped."
        ;;
    restart)
        echo "Restarting Maillayer..."
        pm2 restart all
        sudo systemctl restart caddy
        echo "Maillayer restarted!"
        ;;
    status)
        echo "=== PM2 Processes ==="
        pm2 status
        echo ""
        echo "=== Services ==="
        systemctl status mongod --no-pager -l | head -5
        systemctl status redis-server --no-pager -l | head -5
        systemctl status caddy --no-pager -l | head -5
        ;;
    logs)
        shift
        if [[ -z "$1" ]]; then
            pm2 logs
        else
            pm2 logs "$1"
        fi
        ;;
    update)
        echo "Checking license..."
        source $INSTALL_DIR/.env

        # Verify license before update
        response=$(curl -s -X POST "https://maillayer.com/api/license/verify" \
            -H "Content-Type: application/json" \
            -d "{\"license_key\": \"$LICENSE_KEY\", \"domain\": \"$(hostname)\", \"action\": \"update\"}")

        valid=$(echo "$response" | grep -o '"valid":\s*true' || echo "")
        if [[ -z "$valid" ]]; then
            echo "License verification failed. Please check your license."
            exit 1
        fi

        echo "Fetching latest version..."
        LATEST=$(curl -s "https://api.github.com/repos/maillayer/maillayer/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)

        if [[ -z "$LATEST" ]]; then
            echo "Failed to fetch latest version."
            exit 1
        fi

        echo "Updating to $LATEST..."

        # Stop services
        pm2 stop all

        # Backup current version
        cp -r $INSTALL_DIR $INSTALL_DIR.backup.$(date +%Y%m%d%H%M%S)

        # Download and extract new version
        curl -fsSL "https://github.com/maillayer/maillayer/releases/download/$LATEST/maillayer.tar.gz" | \
            tar -xz -C $INSTALL_DIR --strip-components=1

        # Reinstall dependencies
        cd $INSTALL_DIR && npm ci --only=production --silent

        # Restart
        pm2 restart all

        echo "Updated to $LATEST!"
        ;;
    backup)
        BACKUP_NAME="maillayer-backup-$(date +%Y%m%d-%H%M%S)"
        BACKUP_DIR="$INSTALL_DIR/backups/$BACKUP_NAME"
        echo "Creating backup at $BACKUP_DIR..."

        mkdir -p "$BACKUP_DIR"

        # Backup MongoDB
        mongodump --out "$BACKUP_DIR/mongo" --quiet

        # Backup env
        cp "$INSTALL_DIR/.env" "$BACKUP_DIR/"
        cp /etc/caddy/Caddyfile "$BACKUP_DIR/"

        # Create archive
        cd "$INSTALL_DIR/backups"
        tar -czf "$BACKUP_NAME.tar.gz" "$BACKUP_NAME"
        rm -rf "$BACKUP_NAME"

        echo "Backup created: $INSTALL_DIR/backups/$BACKUP_NAME.tar.gz"
        ;;
    restore)
        if [[ -z "$2" ]]; then
            echo "Usage: maillayer restore <backup-file.tar.gz>"
            exit 1
        fi

        BACKUP_FILE="$2"
        if [[ ! -f "$BACKUP_FILE" ]]; then
            BACKUP_FILE="$INSTALL_DIR/backups/$2"
        fi

        if [[ ! -f "$BACKUP_FILE" ]]; then
            echo "Backup file not found: $2"
            exit 1
        fi

        echo "Restoring from $BACKUP_FILE..."
        echo "WARNING: This will overwrite current data!"
        read -p "Continue? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi

        # Stop app
        pm2 stop all

        # Extract backup
        TEMP_DIR=$(mktemp -d)
        tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"
        BACKUP_DIR=$(ls "$TEMP_DIR")

        # Restore MongoDB
        mongorestore "$TEMP_DIR/$BACKUP_DIR/mongo" --drop --quiet

        # Restart
        pm2 restart all

        rm -rf "$TEMP_DIR"
        echo "Restore complete!"
        ;;
    license)
        source $INSTALL_DIR/.env
        echo "License Key: ${LICENSE_KEY:0:4}****${LICENSE_KEY: -4}"
        echo "Version: ${MAILLAYER_VERSION}"
        echo "Base URL: ${BASE_URL}"

        # Check license status
        response=$(curl -s -X POST "https://maillayer.com/api/license/check" \
            -H "Content-Type: application/json" \
            -d "{\"license_key\": \"$LICENSE_KEY\", \"domain\": \"$(hostname)\"}")

        echo ""
        if echo "$response" | grep -q '"valid":\s*true'; then
            echo "Status: Active ✓"
        else
            echo "Status: Invalid ✗"
        fi
        ;;
    uninstall)
        echo "This will remove Maillayer."
        read -p "Are you sure? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi

        read -p "Also remove database and all data? [y/N] " -n 1 -r
        echo
        REMOVE_DATA=$REPLY

        echo "Stopping services..."
        pm2 stop all
        pm2 delete all
        sudo systemctl stop caddy

        if [[ $REMOVE_DATA =~ ^[Yy]$ ]]; then
            echo "Removing data..."
            rm -rf "$INSTALL_DIR"
            # Optionally drop MongoDB database
            mongosh maillayer --eval "db.dropDatabase()" --quiet
        fi

        rm -f /usr/local/bin/maillayer

        echo "Maillayer uninstalled."
        echo "Note: MongoDB, Redis, Node.js, and Caddy are still installed."
        ;;
    config)
        ${EDITOR:-nano} "$INSTALL_DIR/.env"
        echo "Restart Maillayer for changes to take effect: maillayer restart"
        ;;
    *)
        echo "Maillayer CLI"
        echo ""
        echo "Usage: maillayer <command>"
        echo ""
        echo "Commands:"
        echo "  start      Start all services"
        echo "  stop       Stop all services"
        echo "  restart    Restart services"
        echo "  status     Show service status"
        echo "  logs       View logs (optionally specify process name)"
        echo "  update     Update to latest version"
        echo "  backup     Create a backup"
        echo "  restore    Restore from a backup"
        echo "  license    Show license information"
        echo "  config     Edit configuration"
        echo "  uninstall  Remove Maillayer"
        echo ""
        ;;
esac
CLIMD

    chmod +x /usr/local/bin/maillayer

    log_success "CLI command created: maillayer"
}

create_directories() {
    log_info "Setting up directories..."
    mkdir -p "$INSTALL_DIR"/{logs,backups}
    log_success "Directories created"
}

# ============================================================================
# Interactive Setup
# ============================================================================

prompt_domain() {
    if [[ -z "$DOMAIN" ]]; then
        echo ""
        echo -e "${BOLD}Domain Configuration${NC}"
        echo "Enter the domain where Maillayer will be accessible."
        echo "Make sure DNS A record points to this server's IP."
        echo ""
        read -p "Domain (e.g., mail.yourdomain.com): " DOMAIN

        if [[ -z "$DOMAIN" ]]; then
            log_warning "No domain provided. Using localhost (SSL disabled)"
            DOMAIN="localhost"
            SKIP_SSL="true"
        fi
    fi
}

# ============================================================================
# Parse Arguments
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --license)
                LICENSE_KEY="$2"
                shift 2
                ;;
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            --no-ssl)
                SKIP_SSL="true"
                shift
                ;;
            --version)
                MAILLAYER_VERSION="$2"
                shift 2
                ;;
            -h|--help)
                echo "Maillayer Installer"
                echo ""
                echo "Usage: curl -fsSL https://get.maillayer.com/install.sh | sudo bash"
                echo ""
                echo "The installer will prompt for your license key and domain."
                echo ""
                echo "Options (for non-interactive install):"
                echo "  --license <key>      Your Maillayer license key"
                echo "  --domain <domain>    Domain name for Maillayer"
                echo "  --no-ssl             Skip SSL setup"
                echo "  --version <version>  Maillayer version (default: latest)"
                echo "  -h, --help           Show this help message"
                echo ""
                echo "Example (non-interactive):"
                echo "  curl -fsSL https://get.maillayer.com/install.sh | sudo bash -s -- \\"
                echo "    --license XXXX-XXXX-XXXX-XXXX \\"
                echo "    --domain mail.example.com"
                echo ""
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# ============================================================================
# Main Installation
# ============================================================================

main() {
    TOTAL_STEPS=10

    print_banner

    parse_args "$@"

    log_step 1 "Checking requirements"
    check_root
    check_os
    check_memory
    check_ports
    log_success "System requirements met"

    log_step 2 "Verifying license"
    prompt_license
    verify_license

    prompt_domain

    log_step 3 "Installing system dependencies"
    install_dependencies

    log_step 4 "Installing Node.js"
    install_nodejs

    log_step 5 "Installing databases"
    install_mongodb
    install_redis

    log_step 6 "Installing PM2 and Caddy"
    install_pm2
    install_caddy

    log_step 7 "Downloading Maillayer"
    get_latest_version
    create_directories
    download_maillayer
    install_npm_dependencies

    log_step 8 "Configuring Maillayer"
    create_env_file
    create_caddyfile

    log_step 9 "Starting services"
    setup_pm2
    start_services

    log_step 10 "Finalizing"
    create_cli

    # Success message
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  Maillayer installed successfully!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [[ "$SKIP_SSL" == "true" || "$DOMAIN" == "localhost" ]]; then
        echo -e "  ${BOLD}Access Maillayer at:${NC} http://${DOMAIN}"
    else
        echo -e "  ${BOLD}Access Maillayer at:${NC} https://${DOMAIN}"
    fi

    echo ""
    echo -e "  ${BOLD}License:${NC} ${LICENSE_KEY:0:4}****${LICENSE_KEY: -4}"
    echo -e "  ${BOLD}Version:${NC} ${MAILLAYER_VERSION}"
    echo ""
    echo -e "  ${BOLD}Useful commands:${NC}"
    echo "    maillayer status    - Check service status"
    echo "    maillayer logs      - View application logs"
    echo "    maillayer restart   - Restart services"
    echo "    maillayer backup    - Create a backup"
    echo "    maillayer update    - Update to latest version"
    echo "    maillayer license   - Check license status"
    echo ""
    echo -e "  ${BOLD}Configuration:${NC} $INSTALL_DIR/.env"
    echo ""

    if [[ "$SKIP_SSL" != "true" && "$DOMAIN" != "localhost" ]]; then
        log_info "SSL certificate will be automatically provisioned by Caddy"
    fi

    log_success "Installation complete! Create your admin account at your domain."
}

main "$@"
