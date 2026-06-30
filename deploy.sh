#!/bin/bash
# deploy.sh — One-click deployment for certbot + DNSPod SSL auto-renewal
#
# Usage:
#   chmod +x deploy.sh
#   export DNSPOD_TOKEN="ID,Token"    # or: source dnspod.env
#   sudo -E ./deploy.sh your-domain.com   # -E preserves env vars
#
# What it does:
#   1. Installs certbot and dependencies
#   2. Deploys DNSPod hook scripts to /etc/letsencrypt/hooks/
#   3. Deploys nginx reload deploy hook
#   4. Installs systemd timer (or enables the built-in certbot.timer)
#   5. Requests the initial certificate

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
CERTBOT_HOOKS_DIR="/etc/letsencrypt/hooks"
CERTBOT_DEPLOY_DIR="/etc/letsencrypt/renewal-hooks/deploy"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[deploy]${NC} $(date '+%H:%M:%S') $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }

# ── Pre-flight checks ──────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "This script must be run as root (or with sudo)."
        exit 1
    fi
}

usage() {
    echo "Usage: $0 <domain> [email]"
    echo ""
    echo "  domain   — Domain name for the SSL certificate (e.g. example.com)"
    echo "  email    — Email for Let's Encrypt notifications (optional but recommended)"
    echo ""
    echo "Environment variables:"
    echo "  DNSPOD_TOKEN — DNSPod API token in 'ID,Token' format (REQUIRED)"
    echo ""
    echo "Example:"
    echo "  export DNSPOD_TOKEN='12345,abcdef...'"
    echo "  sudo ./deploy.sh example.com admin@example.com"
    exit 1
}

# ── Main ────────────────────────────────────────────────────────
main() {
    check_root

    local domain="${1:-}"
    local email="${2:-}"

    [ -z "$domain" ] && usage

    if [ -z "${DNSPOD_TOKEN:-}" ]; then
        err "DNSPOD_TOKEN environment variable is not set."
        echo ""
        echo "  Get your token from: https://console.dnspod.cn → 密钥管理"
        echo "  Then run:"
        echo "    export DNSPOD_TOKEN='ID,Token'"
        echo "    sudo -E ./deploy.sh your-domain.com   # -E preserves DNSPOD_TOKEN"
        exit 1
    fi

    log "Deploying SSL auto-renewal for: $domain"

    # 1. Install dependencies
    log "Step 1/6: Installing dependencies..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq certbot python3-certbot curl python3 dnsutils
    elif command -v yum &>/dev/null; then
        yum install -y epel-release
        yum install -y certbot python3-certbot curl python3 bind-utils
    else
        warn "Unsupported package manager. Install certbot, curl, python3, and dnsutils manually."
    fi

    # 2. Deploy hook scripts
    log "Step 2/6: Deploying DNSPod hook scripts..."
    mkdir -p "$CERTBOT_HOOKS_DIR"

    for script in dnspod-auth.sh dnspod-cleanup.sh lib-dnspod.sh; do
        if [ -f "${SCRIPT_DIR}/hooks/${script}" ]; then
            cp "${SCRIPT_DIR}/hooks/${script}" "${CERTBOT_HOOKS_DIR}/${script}"
            chmod 755 "${CERTBOT_HOOKS_DIR}/${script}"
            log "  Installed: ${CERTBOT_HOOKS_DIR}/${script}"
        else
            err "  Missing script: hooks/${script}"
            exit 1
        fi
    done

    # 3. Deploy nginx reload hook
    log "Step 3/6: Deploying nginx reload deploy hook..."
    mkdir -p "$CERTBOT_DEPLOY_DIR"
    cp "${SCRIPT_DIR}/hooks/nginx-deploy.sh" "${CERTBOT_DEPLOY_DIR}/nginx-reload.sh"
    chmod 755 "${CERTBOT_DEPLOY_DIR}/nginx-reload.sh"
    log "  Installed: ${CERTBOT_DEPLOY_DIR}/nginx-reload.sh"

    # 4. Install certbot cli.ini (backup existing if any)
    log "Step 4/6: Configuring certbot..."
    if [ -f "${SCRIPT_DIR}/examples/cli.ini" ]; then
        [ -f /etc/letsencrypt/cli.ini ] && cp /etc/letsencrypt/cli.ini /etc/letsencrypt/cli.ini.bak-$(date +%Y%m%d)
        cp "${SCRIPT_DIR}/examples/cli.ini" /etc/letsencrypt/cli.ini
    fi

    # 5. Enable certbot timer
    log "Step 5/6: Enabling certbot systemd timer..."
    if command -v systemctl &>/dev/null; then
        systemctl enable certbot.timer 2>/dev/null || {
            warn "Could not enable certbot.timer, it may not be installed."
            warn "Install certbot via apt/yum first, or use the provided systemd files:"
            warn "  cp systemd/certbot.* $SYSTEMD_DIR/"
            warn "  systemctl daemon-reload && systemctl enable --now certbot.timer"
        }
        systemctl start certbot.timer 2>/dev/null || true
        log "  certbot.timer enabled and started."
    fi

    # 6. Request initial certificate
    log "Step 6/6: Requesting initial certificate for $domain..."
    local certbot_args=(
        certonly
        --manual
        --preferred-challenges dns
        --manual-auth-hook "${CERTBOT_HOOKS_DIR}/dnspod-auth.sh"
        --manual-cleanup-hook "${CERTBOT_HOOKS_DIR}/dnspod-cleanup.sh"
        -d "$domain"
        --agree-tos
        --non-interactive
    )

    if [ -n "$email" ]; then
        certbot_args+=(-m "$email")
    else
        certbot_args+=(--register-unsafely-without-email)
        warn "No email provided — Let's Encrypt won't be able to notify you about expiry."
    fi

    # Pass DNSPOD_TOKEN to certbot so hooks can access it
    # certbot preserves environment; we just need to make sure it's exported
    export DNSPOD_TOKEN

    if certbot "${certbot_args[@]}"; then
        log "Certificate obtained successfully!"
        log ""
        log "Certificate files: /etc/letsencrypt/live/${domain}/"
        log ""
        log "Next steps:"
        log "  1. Configure nginx to use:"
        log "       ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem"
        log "       ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem"
        log "  2. Test auto-renewal:   certbot renew --dry-run"
        log "  3. Check timer status:  systemctl status certbot.timer"
    else
        err "Certificate request failed. Check the error output above."
        err "Common issues:"
        err "  - DNSPOD_TOKEN is invalid or expired"
        err "  - Domain name doesn't match the DNS zone"
        err "  - DNS API rate limited — try again later"
        exit 1
    fi
}

main "$@"
