#!/bin/sh

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_link() {
    echo -e "${CYAN}$1${NC}"
}

# Check for required variables
if [ -z "$UUID" ]; then
    log_warn "UUID not provided, generating a random one..."
    UUID=$(cat /proc/sys/kernel/random/uuid)
    log_info "Generated UUID: $UUID"
fi

WSPATH="/$UUID"
WSPATH_LINK="/$UUID?ed=2048"
WSPATH_ENCODED="%2F${UUID}%3Fed%3D2048"
PORT=8080

log_info "---------------------------------------------------"
log_info "Starting VLESS-WS-ARGO Node"
log_info "UUID: $UUID"
log_info "WSPATH: $WSPATH"

# Quick Tunnel Mode (TryCloudflare)
if [ -z "$ARGO_TOKEN" ]; then
    log_warn "ARGO_TOKEN not provided. Using Quick Tunnel (trycloudflare.com)..."
    log_warn "Note: Quick Tunnels are temporary and unstable. Not recommended for production."
    USE_QUICK_TUNNEL=true
else
    USE_QUICK_TUNNEL=false
    if [ -n "$PUBLIC_HOSTNAME" ]; then
        log_info "PUBLIC_HOSTNAME: $PUBLIC_HOSTNAME"
    fi
fi
log_info "---------------------------------------------------"

# Generate sing-box configuration
cat > config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$WSPATH",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

log_info "Sing-box configuration generated."

# Start sing-box in background
log_info "Starting sing-box..."
sing-box run -c config.json &
SINGBOX_PID=$!

# Wait for sing-box to initialize
sleep 2

if ! kill -0 $SINGBOX_PID > /dev/null 2>&1; then
    log_error "sing-box failed to start."
    exit 1
fi

# Start cloudflared
if [ "$USE_QUICK_TUNNEL" = "true" ]; then
    log_info "Starting cloudflared (Quick Tunnel)..."
    # Start cloudflared and capture output to find the trycloudflare URL
    cloudflared tunnel --protocol http2 --url http://localhost:$PORT --no-autoupdate > /tmp/cloudflared.log 2>&1 &
    CLOUDFLARED_PID=$!
    
    # Wait for the URL to appear in the log
    log_info "Waiting for Quick Tunnel URL..."
    count=0
    while [ $count -lt 30 ]; do
        if grep -q "https://.*\.trycloudflare\.com" /tmp/cloudflared.log; then
            QUICK_URL=$(grep -o 'https://[-a-z0-9]*\.trycloudflare\.com' /tmp/cloudflared.log | head -n 1)
            if [ -n "$QUICK_URL" ]; then
                PUBLIC_HOSTNAME=$(echo "$QUICK_URL" | sed 's/https:\/\///')
                log_info "Quick Tunnel established: $PUBLIC_HOSTNAME"
                break
            fi
        fi
        sleep 1
        count=$((count+1))
    done
    
    if [ -z "$PUBLIC_HOSTNAME" ]; then
        log_error "Failed to obtain Quick Tunnel URL."
        cat /tmp/cloudflared.log
        kill $SINGBOX_PID $CLOUDFLARED_PID
        exit 1
    fi
else
    log_info "Starting cloudflared tunnel..."
    cloudflared tunnel --protocol http2 --no-autoupdate run --token "$ARGO_TOKEN" &
    CLOUDFLARED_PID=$!
fi

# Generate and Output Links
if [ -n "$PUBLIC_HOSTNAME" ]; then
    echo ""
    log_info "---------------------------------------------------"
    log_info "VLESS Share Links (Import to v2rayN / sing-box / Clash)"
    log_info "---------------------------------------------------"

    # Define best domains
    DOMAINS="cf.254301.xyz isp.254301.xyz run.254301.xyz adventure-x.org www.hltv.org"
    
    ALL_LINKS=""

    for DOMAIN in $DOMAINS; do
        LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${PUBLIC_HOSTNAME}&type=ws&host=${PUBLIC_HOSTNAME}&path=${WSPATH_ENCODED}#${DOMAIN}-Argo"
        
        echo -e "${YELLOW}Server: ${DOMAIN}${NC}"
        log_link "$LINK"
        echo ""
        
        ALL_LINKS="${ALL_LINKS}${LINK}\n"
    done
    
    # Base64 Encode
    if [ -n "$ALL_LINKS" ]; then
        BASE64_LINKS=$(echo -e "$ALL_LINKS" | base64 | tr -d '\n')
        log_info "---------------------------------------------------"
        log_info "Base64 Subscription Link (Copy content below)"
        log_info "---------------------------------------------------"
        log_link "$BASE64_LINKS"
    fi
    log_info "---------------------------------------------------"
else
    log_warn "PUBLIC_HOSTNAME not set. Skipping link generation."
    log_warn "Please set PUBLIC_HOSTNAME to your Cloudflare Tunnel domain (e.g. vless.example.com) to see share links."
fi

# Trap signals to kill both processes
trap "kill $SINGBOX_PID $CLOUDFLARED_PID; exit" SIGINT SIGTERM

# Wait for any process to exit
wait -n $SINGBOX_PID $CLOUDFLARED_PID

# Exit with the status of the process that exited first
exit $?
