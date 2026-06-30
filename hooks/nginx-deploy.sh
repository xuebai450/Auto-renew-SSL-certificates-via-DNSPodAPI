#!/bin/bash
# nginx-deploy.sh — Certbot deploy hook: reload nginx after certificate renewal
#
# Place in /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
# Certbot passes these env vars: RENEWED_DOMAIN, RENEWED_LINEAGE
#
# This script:
#   1. Checks which nginx sites use the renewed certificate
#   2. Tests nginx config syntax
#   3. Reloads nginx only if config is valid

set -euo pipefail

log() {
    echo "[nginx-deploy] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

NGINX_CMD="${NGINX_CMD:-nginx}"
SITES_DIR="${NGINX_SITES_DIR:-/etc/nginx/sites-enabled}"

main() {
    local renewed_domain="${RENEWED_DOMAIN:-}"
    local renewed_lineage="${RENEWED_LINEAGE:-}"

    if [ -z "$renewed_domain" ] || [ -z "$renewed_lineage" ]; then
        log "RENEWED_DOMAIN or RENEWED_LINEAGE not set. This script must be called by certbot as a deploy hook."
        exit 1
    fi

    log "Certificate renewed for domain: $renewed_domain"
    log "Certificate lineage: $renewed_lineage"

    # Find nginx configs that reference the renewed lineage
    local matching_sites=""
    if [ -d "$SITES_DIR" ]; then
        matching_sites=$(grep -Rl "$renewed_lineage" "$SITES_DIR" 2>/dev/null || true)
    fi

    if [ -z "$matching_sites" ]; then
        log "No nginx sites reference $renewed_lineage — skipping reload"
        return 0
    fi

    log "Affected nginx sites:"
    echo "$matching_sites" >&2

    # Test nginx config
    log "Testing nginx configuration..."
    if ! "$NGINX_CMD" -t 2>&1; then
        log "ERROR: nginx config test FAILED. nginx will NOT be reloaded."
        log "Please fix the configuration and reload manually:"
        log "  nginx -t && systemctl reload nginx"
        exit 1
    fi

    # Reload nginx
    log "Reloading nginx..."
    if "$NGINX_CMD" -s reload 2>&1; then
        log "nginx reloaded successfully."
    elif systemctl reload nginx 2>/dev/null; then
        log "nginx reloaded via systemctl."
    else
        log "WARNING: nginx reload may have failed. Check nginx status."
        exit 1
    fi
}

main "$@"
