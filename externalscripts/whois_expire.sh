#!/bin/bash

# Configuration - tuned for speed
WHOIS_TIMEOUT=3  # seconds (reduced from 5)
RDAP_TIMEOUT=1   # seconds (very aggressive)
CACHE_FILE="/tmp/rdap_cache.$USER"

# Pre-cached RDAP servers for instant lookups (updated)
declare -A RDAP_SERVERS=(
    ["dev"]="https://pubapi.registry.google/rdap/domain/"
    ["app"]="https://pubapi.registry.google/rdap/domain/"
    ["page"]="https://pubapi.registry.google/rdap/domain/"
    ["com"]="https://rdap.verisign.com/com/v1/domain/"
    ["net"]="https://rdap.verisign.com/net/v1/domain/"
    ["org"]="https://rdap.publicinterestregistry.org/v1/domain/"
    
)

# Load server cache if exists
[ -f "$CACHE_FILE" ] && source "$CACHE_FILE"

# Check arguments
[ $# -ne 1 ] && { echo "usage: $0 domain_name"; exit 1; }
domain=$1
tld=${domain##*.}

# Fast RDAP lookup (for known TLDs)
get_rdap_expiration() {
    local url="${RDAP_SERVERS[$tld]}${domain}"
    [ -z "$url" ] && return 1
    
    # Ultra-fast lookup with aggressive timeout
    local response=$(curl -s --max-time $RDAP_TIMEOUT -H "Accept: application/rdap+json" "$url" 2>/dev/null)
    local expiration=$(echo "$response" | jq -r '.events[]? | select(.eventAction=="expiration") | .eventDate' 2>/dev/null)
    
    [ -n "$expiration" ] && date -d "$expiration" "+%Y-%m-%d" 2>/dev/null
}

# Optimized WHOIS lookup
get_whois_expiration() {
    local output=$(timeout $WHOIS_TIMEOUT whois "$domain" 2>&1)
    echo "$output" | grep -oE 'Expir.*date:[[:space:]]*[0-9-]+|paid-till:[[:space:]]*[0-9-]+' | \
        head -n1 | awk '{print $NF}' | grep -E '[0-9]{4}-[0-9]{2}-[0-9]{2}'
}

# Main execution flow
{
    # 1. First try RDAP if we have a cached server
    if [ -n "${RDAP_SERVERS[$tld]}" ]; then
        if expiration_date=$(get_rdap_expiration); then
            expiration_epoch=$(date -d "$expiration_date" +%s)
            echo $(( (expiration_epoch - $(date +%s)) / 86400 ))
            exit 0
        fi
    fi

    # 2. Fall back to WHOIS
    if expiration_date=$(get_whois_expiration); then
        expiration_epoch=$(date -d "$expiration_date" +%s)
        echo $(( (expiration_epoch - $(date +%s)) / 86400 ))
        exit 0
    fi

    # 3. Final fallback: Try discovering RDAP server
    if [ -z "${RDAP_SERVERS[$tld]}" ]; then
        # Try common RDAP pattern (only once per TLD)
        potential_url="https://rdap.nic.$tld/v1/domain/$domain"
        if curl -s --max-time 1 --head "$potential_url" | grep -q "HTTP.*200"; then
            RDAP_SERVERS["$tld"]="https://rdap.nic.$tld/v1/domain/"
            declare -p RDAP_SERVERS > "$CACHE_FILE"
            
            if expiration_date=$(get_rdap_expiration); then
                expiration_epoch=$(date -d "$expiration_date" +%s)
                echo $(( (expiration_epoch - $(date +%s)) / 86400 ))
                exit 0
            fi
        fi
    fi

    echo "ERROR: Could not determine expiration date for $domain"
    exit 1
}