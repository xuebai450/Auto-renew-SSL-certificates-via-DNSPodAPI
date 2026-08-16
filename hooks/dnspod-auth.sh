#!/bin/bash
# dnspod-auth.sh — Certbot manual-auth-hook for DNSPod DNS-01 challenge
#
# Creates a _acme-challenge TXT record so Let's Encrypt can verify domain ownership.
#
# Usage: Set as certbot's --manual-auth-hook, or in renewal config:
#   manual_auth_hook = /etc/letsencrypt/hooks/dnspod-auth.sh
#
# Configuration via environment variables (set in certbot's environment,
# or source a config file at the top of this script):
#   DNSPOD_TOKEN   — "ID,Token" from https://console.dnspod.cn → 密钥管理
#   DOMAIN         — root domain (auto-detected from CERTBOT_DOMAIN if unset)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib-dnspod.sh"

main() {
    validate_env "auth"
    detect_domain

    local sub_domain
    sub_domain=$(get_sub_domain)

    log_info "Creating TXT record: ${sub_domain}.${DOMAIN} = ${CERTBOT_VALIDATION}"

    # NOTE: Do NOT delete existing _acme-challenge TXT records here.
    # When requesting both "example.com" and "*.example.com", certbot issues
    # two DNS-01 challenges that share the SAME _acme-challenge.<domain> record
    # name. If we removed prior records, the second challenge's auth-hook call
    # would clobber the first challenge's TXT, causing LE to report
    # "Incorrect TXT record" for the first domain. We append instead and let
    # dnspod-cleanup.sh remove all records once validation completes.
    # (Multiple TXT values may temporarily coexist on the same name; this is
    # valid DNS and Let's Encrypt accepts whichever one matches.)

    # Create new challenge record (append; do NOT clean up first)
    local record_id
    record_id=$(create_challenge_record "$sub_domain" "$CERTBOT_VALIDATION") || {
        log_error "Failed to create TXT record"
        exit 1
    }

    if [ -z "$record_id" ]; then
        log_error "No record ID returned — TXT record may not have been created"
        exit 1
    fi

    log_info "Created TXT record ID: $record_id"

    # Wait for DNS propagation (optional; skip if dig not available)
    if command -v dig &>/dev/null; then
        wait_for_dns_propagation "$sub_domain" "$CERTBOT_VALIDATION"
    else
        log_warn "dig not found — using fixed 15s sleep for DNS propagation"
        sleep 15
    fi
}

main "$@"
