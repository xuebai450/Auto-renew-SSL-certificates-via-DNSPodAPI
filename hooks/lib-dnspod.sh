#!/bin/bash
# lib-dnspod.sh — Shared DNSPod API functions for certbot DNS-01 hooks
# Source this file from auth/cleanup hooks:
#   source "$(dirname "$0")/lib-dnspod.sh"

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
# DNSPod API token in format "ID,Token" (from console.dnspod.cn → 密钥管理)
# Priority: 1) environment variable  2) /etc/letsencrypt/dnspod.conf
DNSPOD_TOKEN="${DNSPOD_TOKEN:-}"

# Auto-source config file if token not already set in environment
if [ -z "${DNSPOD_TOKEN:-}" ] && [ -f /etc/letsencrypt/dnspod.conf ]; then
    # shellcheck source=/dev/null
    source /etc/letsencrypt/dnspod.conf
fi

# Root domain (e.g. "example.com"). Auto-detected from CERTBOT_DOMAIN if unset.
DOMAIN="${DOMAIN:-}"

# API endpoint
DNSPOD_API="https://dnsapi.cn"

# Max retries for API calls
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-2}"

# DNS propagation: max wait seconds, check interval
DNS_WAIT_MAX="${DNS_WAIT_MAX:-120}"
DNS_WAIT_INTERVAL="${DNS_WAIT_INTERVAL:-5}"

# ── Logging ────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    echo "[DNSPod] $(date '+%Y-%m-%d %H:%M:%S') [${level}] $*" >&2
}
log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# ── Validation ─────────────────────────────────────────────────
validate_env() {
    if [ -z "${DNSPOD_TOKEN:-}" ]; then
        log_error "DNSPOD_TOKEN environment variable is not set."
        log_error "Set it before running certbot:"
        log_error "  export DNSPOD_TOKEN='ID,Token'"
        log_error "Or add to /etc/letsencrypt/dnspod.conf and source it in hooks."
        exit 1
    fi

    if [ -z "${CERTBOT_DOMAIN:-}" ]; then
        log_error "CERTBOT_DOMAIN is not set. This script must be called by certbot."
        exit 1
    fi

    if [ -z "${CERTBOT_VALIDATION:-}" ] && [ "${1:-}" != "cleanup" ]; then
        log_error "CERTBOT_VALIDATION is not set. This script must be called by certbot."
        exit 1
    fi
}

# ── Domain helpers ─────────────────────────────────────────────
detect_domain() {
    if [ -z "${DOMAIN:-}" ]; then
        # Auto-detect the registrable domain from CERTBOT_DOMAIN.
        # Handles common multi-part public suffixes (example.com.cn,
        # example.co.uk, ...) so the zone is detected correctly; for
        # other unusual suffixes set DOMAIN explicitly.
        local name="$CERTBOT_DOMAIN"
        case "$name" in
            *.com.cn|*.net.cn|*.org.cn|*.gov.cn|*.edu.cn|*.co.uk|*.org.uk|*.ac.uk|*.co.jp|*.com.au|*.com.br|*.com.tw|*.com.hk|*.co.nz|*.com.sg|*.com.mx)
                DOMAIN=$(echo "$name" | awk -F. '{print $(NF-2)"."$(NF-1)"."$NF}')
                ;;
            *.*.*)
                DOMAIN=$(echo "$name" | awk -F. '{print $(NF-1)"."$NF}')
                ;;
            *)
                DOMAIN="$name"
                ;;
        esac
        log_info "Auto-detected DOMAIN=$DOMAIN from CERTBOT_DOMAIN=$CERTBOT_DOMAIN"
    fi
}

get_sub_domain() {
    # Returns the challenge record name relative to the zone, e.g.
    # "_acme-challenge" for the bare domain, "_acme-challenge.www" for
    # www.example.com. Returns an empty string on unexpected input.
    local sub
    case "$CERTBOT_DOMAIN" in
        "$DOMAIN")   sub="" ;;
        *".$DOMAIN") sub="${CERTBOT_DOMAIN%.$DOMAIN}" ;;
        *)           sub="$CERTBOT_DOMAIN" ;;
    esac
    if [ -n "$sub" ]; then
        echo "_acme-challenge.${sub}"
    else
        echo "_acme-challenge"
    fi
}

# ── DNSPod API helpers ─────────────────────────────────────────
# Call DNSPod API with retry logic
# Usage: api_call "Action" "param1=val1&param2=val2"
api_call() {
    local action="$1"
    local data="login_token=${DNSPOD_TOKEN}&format=json&${2}"
    local url="${DNSPOD_API}/${action}"
    local attempt=1

    while [ $attempt -le "$MAX_RETRIES" ]; do
        local resp
        resp=$(curl -s --connect-timeout 10 --max-time 30 -X POST "$url" -d "$data" 2>&1) || {
            log_warn "curl failed on attempt $attempt/$MAX_RETRIES: $resp"
            attempt=$((attempt + 1))
            [ $attempt -le "$MAX_RETRIES" ] && sleep "$RETRY_DELAY"
            continue
        }

        # Check if response contains status code
        local code
        code=$(echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('status', {}).get('code', 'unknown'))
except Exception:
    print('parse_error')
" 2>/dev/null) || code="parse_error"

        if [ "$code" = "1" ]; then
            echo "$resp"
            return 0
        elif [ "$code" = "parse_error" ]; then
            log_warn "Failed to parse API response on attempt $attempt/$MAX_RETRIES"
        else
            log_warn "API returned code=$code on attempt $attempt/$MAX_RETRIES"
            echo "$resp" >&2
        fi

        attempt=$((attempt + 1))
        [ $attempt -le "$MAX_RETRIES" ] && sleep "$RETRY_DELAY"
    done

    log_error "API call to $action failed after $MAX_RETRIES attempts"
    return 1
}

# List TXT records for the challenge subdomain
# Note: uses direct curl (not api_call) because DNSPod returns code=10 for
# empty lists, which is a normal result, not an error.
list_challenge_records() {
    local sub_domain="$1"
    local resp
    resp=$(curl -s --connect-timeout 10 --max-time 30 -X POST \
        "${DNSPOD_API}/Record.List" \
        -d "login_token=${DNSPOD_TOKEN}&format=json&domain=${DOMAIN}&sub_domain=${sub_domain}&record_type=TXT") || {
        log_warn "Curl failed for Record.List"; return 0
    }

    local code
    code=$(echo "$resp" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('status', {}).get('code', '10'))
except Exception:
    print('10')
") || code="10"

    # Code 1 = has records, Code 10 = list is empty (both are success)
    if [ "$code" != "1" ] && [ "$code" != "10" ]; then
        log_warn "Record.List returned unexpected code=$code: $(echo "$resp" | head -c 200)"
        return 0
    fi

    echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for r in d.get('records', []):
        rid = r.get('id', '')
        if rid:
            print(rid)
except (KeyError, json.JSONDecodeError) as e:
    pass
" 2>/dev/null
}

# Remove a DNS record by ID
remove_record() {
    local record_id="$1"
    api_call "Record.Remove" "domain=${DOMAIN}&record_id=${record_id}" > /dev/null
}

# Remove all existing challenge TXT records
cleanup_challenge_records() {
    local sub_domain="$1"
    log_info "Cleaning up old TXT records for ${sub_domain}.${DOMAIN}"

    list_challenge_records "$sub_domain" | while read -r rid; do
        [ -n "$rid" ] && {
            log_info "Removing record ID: $rid"
            remove_record "$rid" || log_warn "Failed to remove record $rid, continuing"
        }
    done || true  # pipefail safe: cleanup is best-effort, never fatal
}

# Create a new TXT challenge record
create_challenge_record() {
    local sub_domain="$1"
    local value="$2"

    # URL-encode the challenge value. certbot currently uses base64url
    # (URL-safe), but encode defensively in case the format ever changes.
    local value_enc
    value_enc=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$value" 2>/dev/null) || value_enc="$value"

    # record_line is pre-encoded: %E9%BB%98%E8%AE%A4 = "默认" (default line)
    local resp
    resp=$(api_call "Record.Create" \
        "domain=${DOMAIN}&sub_domain=${sub_domain}&record_type=TXT&record_line=%E9%BB%98%E8%AE%A4&value=${value_enc}&ttl=600") || return 1

    log_info "Create response: $resp"

    local record_id
    record_id=$(echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    rid = d.get('record', {}).get('id', '')
    if rid:
        print(rid)
except (KeyError, json.JSONDecodeError):
    pass
" 2>/dev/null)

    echo "$record_id"
}

# ── DNS propagation helpers ────────────────────────────────────
# Wait for DNS propagation by querying public DNS
wait_for_dns_propagation() {
    local sub_domain="$1"
    local expected_value="$2"
    local nameserver="${DNS_CHECK_NS:-223.5.5.5}"  # AliDNS by default

    log_info "Waiting for DNS propagation (max ${DNS_WAIT_MAX}s)..."

    local elapsed=0
    local resolved=""

    while [ $elapsed -lt "$DNS_WAIT_MAX" ]; do
        resolved=$(dig +short TXT "${sub_domain}.${DOMAIN}" @"$nameserver" 2>/dev/null | tr -d '"' || true)

        if echo "$resolved" | grep -qF "$expected_value"; then
            log_info "DNS propagated after ${elapsed}s: $resolved"
            return 0
        fi

        sleep "$DNS_WAIT_INTERVAL"
        elapsed=$((elapsed + DNS_WAIT_INTERVAL))
    done

    log_warn "DNS propagation check timed out after ${elapsed}s. Last resolved: $resolved"
    log_warn "Proceeding anyway — Let's Encrypt will retry if validation fails."
    return 0  # Don't fail; LE will retry on its side
}
