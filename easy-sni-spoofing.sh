#!/bin/bash

# ============================================================
# SNI-Spoof Rust Tunnel Manager
# ============================================================
# Features:
#   ✅ Auto-detect architecture (amd64 / arm64)
#   ✅ Auto-install curl/wget if missing
#   ✅ IP and port validation
#   ✅ Update existing service
#   ✅ Multiple listeners support
#   ✅ Full management menu
#   ✅ View logs via journalctl
#   ✅ Colored output
#   ✅ Works with curl | bash piping
# ============================================================

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------- Constants ----------
BINARY_URL="https://github.com/therealaleph/sni-spoofing-rust/releases/download/v1.0.2/sni-spoof-rs-linux-"
CONFIG_PATH="/root/config.json"
SERVICE_PATH="/etc/systemd/system/sni-spoof.service"
BINARY_PATH="/root/sni-spoof-rs-linux-"
WORKDIR="/root"

# ---------- Helper Functions ----------
print_success() { echo -e "${GREEN}✔ $1${NC}"; }
print_error() { echo -e "${RED}✘ $1${NC}"; }
print_info() { echo -e "${CYAN}➜ $1${NC}"; }
print_warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

# ---------- Safe read from terminal ----------
safe_read() {
    local var_name=$1
    local prompt=$2
    local default=$3
    if [[ -n "$prompt" ]]; then
        echo -n "$prompt"
    fi
    if [[ -n "$default" ]]; then
        echo -n " [$default]"
    fi
    echo -n ": "
    if [[ -t 0 ]]; then
        read -r "$var_name"
    else
        read -r "$var_name" < /dev/tty
    fi
    if [[ -n "$default" && -z "${!var_name}" ]]; then
        eval "$var_name=\"$default\""
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)."
        exit 1
    fi
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)       print_error "Unsupported architecture: $arch"; exit 1 ;;
    esac
}

check_dependencies() {
    local deps=("curl" "wget" "systemctl" "journalctl")
    for dep in "${deps[@]}"; do
        if ! command -v $dep &>/dev/null; then
            if [[ $dep == "curl" || $dep == "wget" ]]; then
                print_warn "$dep not found, installing..."
                apt-get update -qq && apt-get install -y -qq $dep 2>/dev/null || \
                yum install -y -q $dep 2>/dev/null || \
                dnf install -y -q $dep 2>/dev/null
            else
                print_error "$dep is not installed. Please install it manually."
                exit 1
            fi
        fi
    done
}

validate_ip_or_domain() {
    local input=$1
    if [[ $input =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ $input =~ ^[a-zA-Z0-9.-]+$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_port() {
    local port=$1
    if [[ $port =~ ^[0-9]+$ ]] && [ $port -ge 1 ] && [ $port -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

download_binary() {
    local arch=$1
    local url="${BINARY_URL}${arch}"
    local dest="${BINARY_PATH}${arch}"
    print_info "Downloading binary from $url"
    
    if command -v curl &>/dev/null; then
        curl -L -o "$dest" "$url" --progress-bar
    elif command -v wget &>/dev/null; then
        wget -O "$dest" "$url" -q --show-progress
    else
        print_error "No download tool available (curl/wget)."
        exit 1
    fi

    if [[ -f "$dest" && -s "$dest" ]]; then
        chmod +x "$dest"
        print_success "Binary downloaded successfully: $dest"
    else
        print_error "Binary download failed."
        exit 1
    fi
}

create_config() {
    local config="{
  \"graceful_shutdown_sec\": 0,
  \"listeners\": ["

    safe_read listener_count "How many listeners do you want? (default 1)" "1"
    if ! [[ $listener_count =~ ^[0-9]+$ ]] || [ $listener_count -lt 1 ]; then
        listener_count=1
    fi

    for ((i=1; i<=listener_count; i++)); do
        echo ""
        print_info "Listener #$i:"
        
        # listen
        while true; do
            safe_read listen_ip "Listen address (e.g., 0.0.0.0)"
            if validate_ip_or_domain "$listen_ip"; then
                break
            else
                print_error "Invalid address."
            fi
        done
        while true; do
            safe_read listen_port "Listen port (e.g., 40443)"
            if validate_port "$listen_port"; then
                break
            else
                print_error "Invalid port (1-65535)."
            fi
        done

        # connect
        while true; do
            safe_read connect_ip "Connect address (IP or domain, e.g., 198.41.194.170)"
            if validate_ip_or_domain "$connect_ip"; then
                break
            else
                print_error "Invalid address."
            fi
        done
        while true; do
            safe_read connect_port "Connect port (e.g., 443)"
            if validate_port "$connect_port"; then
                break
            else
                print_error "Invalid port."
            fi
        done

        # fake_sni
        safe_read fake_sni "fake_sni (spoofed SNI, e.g., 198.41.194.170 or google.com)"

        # add to JSON
        if [ $i -gt 1 ]; then
            config="$config,"
        fi
        config="$config
    {
      \"listen\": \"$listen_ip:$listen_port\",
      \"connect\": \"$connect_ip:$connect_port\",
      \"fake_sni\": \"$fake_sni\",
      \"conn_timeout_sec\": 5,
      \"handshake_timeout_sec\": 2,
      \"keepalive_time_sec\": 11,
      \"keepalive_interval_sec\": 2
    }"
    done

    config="$config
  ]
}"

    echo "$config" > "$CONFIG_PATH"
    print_success "Configuration saved to $CONFIG_PATH"
}

install_service() {
    local arch=$1
    download_binary "$arch"
    create_config
    local binary="${BINARY_PATH}${arch}"
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=SNI Spoof Rust Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORKDIR
ExecStart=$binary $CONFIG_PATH
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sni-spoof.service
    systemctl start sni-spoof.service
    print_success "Service installed and started."
    sleep 2
    systemctl status sni-spoof.service --no-pager
}

update_service() {
    local arch=$1
    print_info "Updating binary..."
    download_binary "$arch"
    print_info "Restarting service..."
    systemctl restart sni-spoof.service
    print_success "Update completed."
}

uninstall_service() {
    print_warn "Are you sure you want to remove the service and all files? (y/n)"
    if [[ -t 0 ]]; then
        read -r confirm
    else
        read -r confirm < /dev/tty
    fi
    [[ $confirm != "y" && $confirm != "Y" ]] && { print_info "Canceled."; return; }

    systemctl stop sni-spoof.service
    systemctl disable sni-spoof.service
    rm -f "$SERVICE_PATH"
    rm -f "$CONFIG_PATH"
    rm -f "${BINARY_PATH}"*
    systemctl daemon-reload
    print_success "Service and files removed."
}

restart_service() {
    systemctl restart sni-spoof.service
    print_success "Service restarted."
    sleep 2
    systemctl status sni-spoof.service --no-pager
}

view_logs() {
    journalctl -u sni-spoof.service -f -n 50
}

change_config() {
    create_config
    systemctl restart sni-spoof.service
    print_success "Configuration updated and service restarted."
}

main_menu() {
    local arch=$(detect_arch)
    while true; do
        echo ""
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        echo -e "${GREEN}    SNI-Spoof Tunnel Manager${NC}"
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        echo "1) Install (Download binary + Create config + Setup service)"
        echo "2) Update (Re-download binary and restart)"
        echo "3) Uninstall (Remove everything)"
        echo "4) Restart service"
        echo "5) View logs (live)"
        echo "6) Change config only (no reinstall)"
        echo "7) Exit"
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        safe_read choice "Your choice"
        
        case $choice in
            1) install_service "$arch" ;;
            2) update_service "$arch" ;;
            3) uninstall_service ;;
            4) restart_service ;;
            5) view_logs ;;
            6) change_config ;;
            7) print_info "Exiting."; exit 0 ;;
            *) print_error "Invalid option." ;;
        esac
    done
}

# ============================================================
# Main Execution
# ============================================================
check_root
check_dependencies
main_menu
