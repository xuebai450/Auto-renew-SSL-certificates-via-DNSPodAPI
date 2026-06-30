#!/bin/bash
# dnspod-cleanup.sh — Certbot manual-cleanup-hook for DNSPod DNS-01 challenge
#
# Removes _acme-challenge TXT records after Let's Encrypt validation completes.
#
# Usage: Set as certbot's --manual-cleanup-hook, or in renewal config:
#   manual_cleanup_hook = /etc/letsencrypt/hooks/dnspod-cleanup.sh
#
# Configuration via environment variables:
#   DNSPOD_TOKEN   — "ID,Token" from https://console.dnspod.cn → 密钥管理
#   DOMAIN         — root domain (auto-detected from CERTBOT_DOMAIN if unset)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib-dnspod.sh"

main() {
    validate_env "cleanup"
    detect_domain

    local sub_domain
    sub_domain=$(get_sub_domain)

    log_info "Cleaning up TXT records: ${sub_domain}.${DOMAIN}"

    cleanup_challenge_records "$sub_domain"
}

main "$@"
