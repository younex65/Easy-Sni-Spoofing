#!/bin/bash

# ============================================================
# SNI-Spoof Rust Tunnel Manager + Web Panel
# ============================================================
# Version: 2.0 - Fixed Edit button & Modal UI
# ============================================================

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- Constants ----------
BINARY_URL="https://github.com/therealaleph/sni-spoofing-rust/releases/download/v1.0.2/sni-spoof-rs-linux-"
CONFIG_PATH="/root/config.json"
SERVICE_PATH="/etc/systemd/system/sni-spoof.service"
BINARY_PATH="/root/sni-spoof-rs-linux-"
WORKDIR="/root"
WEB_PANEL_SCRIPT="/root/web_panel.py"
WEB_PANEL_SERVICE="/etc/systemd/system/sni-webpanel.service"
DB_PATH="/root/web_panel_users.db"

# ---------- Helper Functions ----------
print_success() { echo -e "${GREEN}✔ $1${NC}"; }
print_error() { echo -e "${RED}✘ $1${NC}"; }
print_info() { echo -e "${CYAN}➜ $1${NC}"; }
print_warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

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

download_binary_only() {
    local arch=$(detect_arch)
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

create_config_interactive() {
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

        safe_read fake_sni "fake_sni (spoofed SNI, e.g., 198.41.194.170 or google.com)"

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

create_default_config() {
    cat > "$CONFIG_PATH" <<EOF
{
  "graceful_shutdown_sec": 0,
  "listeners": [
    {
      "listen": "0.0.0.0:40443",
      "connect": "198.41.194.170:443",
      "fake_sni": "198.41.194.170",
      "conn_timeout_sec": 5,
      "handshake_timeout_sec": 2,
      "keepalive_time_sec": 11,
      "keepalive_interval_sec": 2
    }
  ]
}
EOF
    print_success "Default configuration created at $CONFIG_PATH"
}

setup_service() {
    local arch=$(detect_arch)
    local binary="${BINARY_PATH}${arch}"
    
    if [[ ! -f "$binary" ]]; then
        print_error "Binary not found at $binary"
        print_info "Please run option 1 first to download the binary."
        return 1
    fi

    create_config_interactive

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
    local arch=$(detect_arch)
    print_info "Updating binary..."
    download_binary_only
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

    systemctl stop sni-spoof.service 2>/dev/null
    systemctl disable sni-spoof.service 2>/dev/null
    systemctl stop sni-webpanel.service 2>/dev/null
    systemctl disable sni-webpanel.service 2>/dev/null
    rm -f "$SERVICE_PATH" "$WEB_PANEL_SERVICE"
    rm -f "$CONFIG_PATH" "$WEB_PANEL_SCRIPT" "$DB_PATH"
    rm -f "${BINARY_PATH}"*
    systemctl daemon-reload
    print_success "All services and files removed."
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
    create_config_interactive
    systemctl restart sni-spoof.service
    print_success "Configuration updated and service restarted."
}

# ---------- Install Web Panel (NEW VERSION with fixed UI) ----------
install_web_panel() {
    print_info "Installing Web Panel (Flask)..."

    # Check and download binary if missing
    local arch=$(detect_arch)
    local binary="${BINARY_PATH}${arch}"
    if [[ ! -f "$binary" ]]; then
        print_warn "Binary not found. Downloading it now..."
        download_binary_only
    fi

    # Check and create default config if missing
    if [[ ! -f "$CONFIG_PATH" ]]; then
        print_warn "Config not found. Creating default config..."
        create_default_config
    fi

    # Setup service if not already installed
    if ! systemctl status sni-spoof.service &>/dev/null; then
        print_warn "Service not installed. Setting up service..."
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
    fi

    # Install Python3 if missing
    if ! command -v python3 &>/dev/null; then
        print_warn "Python3 not found, installing..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq python3 python3-pip
        elif command -v yum &>/dev/null; then
            yum install -y -q python3 python3-pip
        elif command -v dnf &>/dev/null; then
            dnf install -y -q python3 python3-pip
        else
            print_error "Cannot install Python3 automatically. Please install manually."
            return 1
        fi
        if ! command -v python3 &>/dev/null; then
            print_error "Python3 installation failed."
            return 1
        fi
        print_success "Python3 installed."
    fi

    # Ensure pip is available
    if ! python3 -m pip --version &>/dev/null; then
        print_warn "pip3 not found, installing..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq python3-pip
        elif command -v yum &>/dev/null; then
            yum install -y -q python3-pip
        elif command -v dnf &>/dev/null; then
            dnf install -y -q python3-pip
        else
            python3 -m ensurepip --upgrade 2>/dev/null
        fi
        if ! python3 -m pip --version &>/dev/null; then
            print_error "pip installation failed. Please install manually."
            return 1
        fi
    fi

    # Install Flask and bcrypt
    print_info "Installing Python packages (flask, bcrypt)..."
    python3 -m pip install --upgrade pip --quiet 2>/dev/null
    
    if ! python3 -m pip install flask bcrypt --ignore-installed --break-system-packages 2>&1 | tee /tmp/pip_install.log; then
        print_warn "First attempt failed. Trying alternative..."
        if ! python3 -m pip install flask bcrypt --ignore-installed 2>&1 | tee -a /tmp/pip_install.log; then
            if command -v apt-get &>/dev/null; then
                apt-get install -y -qq python3-flask python3-bcrypt
            else
                print_error "Failed to install Flask/bcrypt. Please run manually:"
                print_info "python3 -m pip install flask bcrypt --ignore-installed --break-system-packages"
                return 1
            fi
        fi
    fi

    if ! python3 -c "import flask, bcrypt" &>/dev/null; then
        print_error "Flask or bcrypt not installed correctly."
        return 1
    fi
    print_success "Python packages installed."

    # Get web panel port
    while true; do
        safe_read WEB_PORT "Enter port for web panel (default 5000)" "5000"
        if validate_port "$WEB_PORT"; then
            break
        else
            print_error "Invalid port (1-65535)."
        fi
    done

    # Get admin credentials
    safe_read ADMIN_USER "Admin username for web panel" "admin"
    while true; do
        safe_read ADMIN_PASS "Admin password (min 6 characters)" ""
        if [[ ${#ADMIN_PASS} -ge 6 ]]; then
            break
        else
            print_error "Password must be at least 6 characters."
        fi
    done

    SECRET_KEY=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)

    # ======================================================================
    # CREATE WEB_PANEL.PY - NEW VERSION WITH FIXED UI
    # ======================================================================
    print_info "Generating web panel script (NEW VERSION)..."
    
    # Remove old file if exists
    rm -f "$WEB_PANEL_SCRIPT"
    
    cat > "$WEB_PANEL_SCRIPT" <<'EOF'
#!/usr/bin/env python3
import os
import json
import subprocess
import sqlite3
import bcrypt
from flask import Flask, request, jsonify, render_template_string, session, redirect, url_for
from functools import wraps

app = Flask(__name__)
app.secret_key = "REPLACE_SECRET_KEY"

CONFIG_PATH = "/root/config.json"
SERVICE_NAME = "sni-spoof.service"
DB_PATH = "/root/web_panel_users.db"
WEB_PORT = 5000

def init_db():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS users
                 (id INTEGER PRIMARY KEY AUTOINCREMENT,
                  username TEXT UNIQUE,
                  password_hash TEXT,
                  is_admin INTEGER DEFAULT 0)''')
    conn.commit()
    conn.close()

def get_user(username):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT id, username, password_hash, is_admin FROM users WHERE username=?", (username,))
    user = c.fetchone()
    conn.close()
    return user

def get_user_by_id(user_id):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT id, username, password_hash, is_admin FROM users WHERE id=?", (user_id,))
    user = c.fetchone()
    conn.close()
    return user

def create_user(username, password, is_admin=0):
    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    try:
        c.execute("INSERT INTO users (username, password_hash, is_admin) VALUES (?, ?, ?)",
                  (username, hashed, is_admin))
        conn.commit()
        return True
    except sqlite3.IntegrityError:
        return False
    finally:
        conn.close()

def verify_user(username, password):
    user = get_user(username)
    if user:
        return bcrypt.checkpw(password.encode(), user[2].encode())
    return False

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'user_id' not in session:
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

def admin_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'user_id' not in session:
            return redirect(url_for('login'))
        user = get_user_by_id(session['user_id'])
        if not user or not user[3]:
            return "Access denied", 403
        return f(*args, **kwargs)
    return decorated_function

def read_config():
    try:
        with open(CONFIG_PATH, 'r') as f:
            return json.load(f)
    except:
        return {"graceful_shutdown_sec": 0, "listeners": []}

def write_config(config):
    with open(CONFIG_PATH, 'w') as f:
        json.dump(config, f, indent=2)

def restart_service():
    subprocess.run(["systemctl", "restart", SERVICE_NAME], check=False)

@app.route('/')
def index():
    return redirect(url_for('dashboard'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        if verify_user(username, password):
            user = get_user(username)
            session['user_id'] = user[0]
            session['username'] = user[1]
            session['is_admin'] = user[3]
            return redirect(url_for('dashboard'))
        else:
            return render_template_string(LOGIN_TEMPLATE, error="Invalid credentials")
    return render_template_string(LOGIN_TEMPLATE, error=None)

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/dashboard')
@login_required
def dashboard():
    config = read_config()
    return render_template_string(DASHBOARD_TEMPLATE, 
                                   config=config, 
                                   is_admin=session.get('is_admin', 0),
                                   username=session.get('username', ''))

@app.route('/add_listener', methods=['POST'])
@login_required
@admin_required
def add_listener():
    data = request.json
    config = read_config()
    new_listener = {
        "listen": f"{data['listen_ip']}:{data['listen_port']}",
        "connect": f"{data['connect_ip']}:{data['connect_port']}",
        "fake_sni": data['fake_sni'],
        "conn_timeout_sec": int(data.get('conn_timeout', 5)),
        "handshake_timeout_sec": int(data.get('handshake_timeout', 2)),
        "keepalive_time_sec": int(data.get('keepalive_time', 11)),
        "keepalive_interval_sec": int(data.get('keepalive_interval', 2))
    }
    config['listeners'].append(new_listener)
    write_config(config)
    restart_service()
    return jsonify({"status": "ok"})

@app.route('/delete_listener/<int:index>', methods=['DELETE'])
@login_required
@admin_required
def delete_listener(index):
    config = read_config()
    if 0 <= index < len(config['listeners']):
        del config['listeners'][index]
        write_config(config)
        restart_service()
        return jsonify({"status": "ok"})
    return jsonify({"status": "error", "message": "Invalid index"}), 400

@app.route('/update_listener/<int:index>', methods=['PUT'])
@login_required
@admin_required
def update_listener(index):
    data = request.json
    config = read_config()
    if 0 <= index < len(config['listeners']):
        config['listeners'][index] = {
            "listen": f"{data['listen_ip']}:{data['listen_port']}",
            "connect": f"{data['connect_ip']}:{data['connect_port']}",
            "fake_sni": data['fake_sni'],
            "conn_timeout_sec": int(data.get('conn_timeout', 5)),
            "handshake_timeout_sec": int(data.get('handshake_timeout', 2)),
            "keepalive_time_sec": int(data.get('keepalive_time', 11)),
            "keepalive_interval_sec": int(data.get('keepalive_interval', 2))
        }
        write_config(config)
        restart_service()
        return jsonify({"status": "ok"})
    return jsonify({"status": "error", "message": "Invalid index"}), 400

@app.route('/update_settings', methods=['POST'])
@login_required
@admin_required
def update_settings():
    data = request.json
    config = read_config()
    config['graceful_shutdown_sec'] = int(data.get('graceful_shutdown_sec', 0))
    write_config(config)
    restart_service()
    return jsonify({"status": "ok"})

@app.route('/change_password', methods=['POST'])
@login_required
def change_password():
    data = request.json
    old = data.get('old_password')
    new = data.get('new_password')
    if not old or not new:
        return jsonify({"status": "error", "message": "Missing fields"}), 400
    user = get_user_by_id(session['user_id'])
    if not bcrypt.checkpw(old.encode(), user[2].encode()):
        return jsonify({"status": "error", "message": "Invalid old password"}), 400
    hashed = bcrypt.hashpw(new.encode(), bcrypt.gensalt()).decode()
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("UPDATE users SET password_hash=? WHERE id=?", (hashed, session['user_id']))
    conn.commit()
    conn.close()
    return jsonify({"status": "ok"})

@app.route('/create_user', methods=['POST'])
@login_required
@admin_required
def create_user_route():
    data = request.json
    username = data.get('username')
    password = data.get('password')
    is_admin = int(data.get('is_admin', 0))
    if not username or not password:
        return jsonify({"status": "error", "message": "Missing fields"}), 400
    if create_user(username, password, is_admin):
        return jsonify({"status": "ok"})
    else:
        return jsonify({"status": "error", "message": "Username already exists"}), 400

# ================== HTML TEMPLATES ==================
LOGIN_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>SNI Spoof Panel - Login</title>
    <style>
        body { font-family: Arial, sans-serif; background: #1e1e2f; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .login-box { background: #2d2d44; padding: 40px; border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.5); width: 320px; }
        .login-box h2 { color: #fff; text-align: center; margin-bottom: 30px; }
        .login-box input { width: 100%; padding: 12px; margin: 8px 0; border: none; border-radius: 6px; background: #3d3d5c; color: #fff; }
        .login-box input[type="submit"] { background: #6c5ce7; cursor: pointer; font-weight: bold; }
        .login-box input[type="submit"]:hover { background: #5a4bd1; }
        .error { color: #ff6b6b; text-align: center; margin-top: 10px; }
    </style>
</head>
<body>
    <div class="login-box">
        <h2>🔐 SNI Spoof Panel</h2>
        <form method="POST">
            <input type="text" name="username" placeholder="Username" required>
            <input type="password" name="password" placeholder="Password" required>
            <input type="submit" value="Login">
        </form>
        {% if error %}<div class="error">{{ error }}</div>{% endif %}
    </div>
</body>
</html>
'''

DASHBOARD_TEMPLATE = '''
<!DOCTYPE html>
<html>
<head>
    <title>SNI Spoof Panel</title>
    <style>
        body { font-family: 'Segoe UI', Arial, sans-serif; background: #1a1a2e; color: #eee; margin: 0; padding: 20px; }
        .container { max-width: 1200px; margin: auto; }
        h1 { color: #a29bfe; }
        .card { background: #2d2d44; padding: 20px; border-radius: 10px; margin-bottom: 20px; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 10px; text-align: left; border-bottom: 1px solid #3d3d5c; }
        th { background: #3d3d5c; }
        .btn { background: #6c5ce7; border: none; color: #fff; padding: 8px 16px; border-radius: 6px; cursor: pointer; }
        .btn-danger { background: #e74c3c; }
        .btn-success { background: #27ae60; }
        .btn-sm { padding: 5px 10px; font-size: 0.9em; }
        .form-group { margin: 10px 0; }
        .form-group input, .form-group select { padding: 8px; border-radius: 4px; border: none; background: #3d3d5c; color: #fff; width: 100%; max-width: 300px; }
        .flex { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
        .nav { display: flex; justify-content: space-between; align-items: center; }
        .nav a { color: #a29bfe; text-decoration: none; margin-left: 15px; cursor: pointer; }
        .modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.7); justify-content: center; align-items: center; z-index: 1000; }
        .modal-content { background: #2d2d44; padding: 30px; border-radius: 12px; width: 450px; max-width: 90%; }
        .modal-content h2, .modal-content h3, .modal-content h4 { margin-top: 0; color: #a29bfe; }
        .modal-content input, .modal-content select { width: 100%; padding: 8px; margin: 5px 0; background: #3d3d5c; border: none; border-radius: 4px; color: #fff; }
        .modal-content .form-group { margin: 10px 0; }
        .modal-actions { display: flex; gap: 10px; margin-top: 15px; justify-content: flex-end; }
        .close-btn { float: right; background: none; border: none; color: #fff; font-size: 24px; cursor: pointer; }
        .nav-buttons { display: flex; gap: 10px; align-items: center; }
        .nav-buttons .btn { font-size: 0.85em; padding: 6px 14px; }
        hr { border-color: #3d3d5c; margin: 15px 0; }
    </style>
</head>
<body>
<div class="container">
    <div class="nav">
        <h1>🚀 SNI Spoof Panel</h1>
        <div class="nav-buttons">
            <span>👤 {{ username }} ({% if is_admin %}Admin{% else %}User{% endif %})</span>
            {% if is_admin %}
            <button class="btn btn-sm" onclick="openSettingsModal()">⚙️ Settings</button>
            <button class="btn btn-sm" onclick="openAdminModal()">👥 Admin</button>
            {% endif %}
            <a onclick="logout()">Logout</a>
        </div>
    </div>

    <div class="card">
        <h2>Listeners</h2>
        <button class="btn btn-success" onclick="showAddModal()">+ Add Listener</button>
        <table>
            <thead><tr><th>#</th><th>Listen</th><th>Connect</th><th>Fake SNI</th><th>Actions</th></tr></thead>
            <tbody id="listenerTable">
            {% for listener in config.listeners %}
            <tr>
                <td>{{ loop.index0 }}</td>
                <td>{{ listener.listen }}</td>
                <td>{{ listener.connect }}</td>
                <td>{{ listener.fake_sni }}</td>
                <td>
                    <button class="btn btn-sm" onclick="editListener({{ loop.index0 }})">✏️</button>
                    <button class="btn btn-danger btn-sm" onclick="deleteListener({{ loop.index0 }})">🗑️</button>
                </td>
            </tr>
            {% endfor %}
            </tbody>
        </table>
    </div>

    <!-- Add/Edit Listener Modal -->
    <div id="listenerModal" class="modal">
        <div class="modal-content">
            <span class="close-btn" onclick="closeModal('listenerModal')">&times;</span>
            <h3 id="modalTitle">Add Listener</h3>
            <input type="hidden" id="editIndex">
            <div class="form-group"><input id="listen_ip" placeholder="Listen IP (e.g. 0.0.0.0)"></div>
            <div class="form-group"><input id="listen_port" placeholder="Listen Port (e.g. 40443)"></div>
            <div class="form-group"><input id="connect_ip" placeholder="Connect IP (e.g. 198.41.194.170)"></div>
            <div class="form-group"><input id="connect_port" placeholder="Connect Port (e.g. 443)"></div>
            <div class="form-group"><input id="fake_sni" placeholder="Fake SNI (e.g. google.com)"></div>
            <div class="form-group"><input id="conn_timeout" placeholder="Conn Timeout (sec)" value="5"></div>
            <div class="form-group"><input id="handshake_timeout" placeholder="Handshake Timeout (sec)" value="2"></div>
            <div class="form-group"><input id="keepalive_time" placeholder="Keepalive Time (sec)" value="11"></div>
            <div class="form-group"><input id="keepalive_interval" placeholder="Keepalive Interval (sec)" value="2"></div>
            <div class="modal-actions">
                <button class="btn btn-success" onclick="saveListener()">Save</button>
                <button class="btn btn-danger" onclick="closeModal('listenerModal')">Cancel</button>
            </div>
        </div>
    </div>

    <!-- Settings Modal -->
    <div id="settingsModal" class="modal">
        <div class="modal-content">
            <span class="close-btn" onclick="closeModal('settingsModal')">&times;</span>
            <h2>⚙️ General Settings</h2>
            <div class="form-group">
                <label>Graceful Shutdown (sec):</label>
                <input type="number" id="graceful_shutdown" value="{{ config.graceful_shutdown_sec or 0 }}">
            </div>
            <div class="modal-actions">
                <button class="btn btn-success" onclick="updateSettings()">Save Settings</button>
                <button class="btn btn-danger" onclick="closeModal('settingsModal')">Cancel</button>
            </div>
        </div>
    </div>

    <!-- Admin Modal -->
    <div id="adminModal" class="modal">
        <div class="modal-content">
            <span class="close-btn" onclick="closeModal('adminModal')">&times;</span>
            <h2>👥 Admin Panel</h2>
            <h4>Create New User</h4>
            <div class="form-group"><input type="text" id="new_username" placeholder="Username"></div>
            <div class="form-group"><input type="password" id="new_password" placeholder="Password"></div>
            <div class="form-group">
                <select id="new_is_admin">
                    <option value="0">User</option>
                    <option value="1">Admin</option>
                </select>
            </div>
            <button class="btn btn-success" onclick="createUser()">Create User</button>
            <hr>
            <h4>Change Your Password</h4>
            <div class="form-group"><input type="password" id="old_pass" placeholder="Old password"></div>
            <div class="form-group"><input type="password" id="new_pass" placeholder="New password"></div>
            <button class="btn" onclick="changePassword()">Change Password</button>
            <div class="modal-actions">
                <button class="btn btn-danger" onclick="closeModal('adminModal')">Close</button>
            </div>
        </div>
    </div>
</div>

<script>
// ---------- Modal Helpers ----------
function closeModal(id) {
    document.getElementById(id).style.display = 'none';
}

function openModal(id) {
    document.getElementById(id).style.display = 'flex';
}

function openSettingsModal() {
    openModal('settingsModal');
}

function openAdminModal() {
    openModal('adminModal');
}

// ---------- Listener CRUD ----------
function showAddModal() {
    document.getElementById('modalTitle').innerText = 'Add Listener';
    document.getElementById('editIndex').value = '';
    document.querySelectorAll('#listenerModal input').forEach(el => el.value = '');
    document.getElementById('conn_timeout').value = 5;
    document.getElementById('handshake_timeout').value = 2;
    document.getElementById('keepalive_time').value = 11;
    document.getElementById('keepalive_interval').value = 2;
    openModal('listenerModal');
}

function editListener(idx) {
    document.getElementById('modalTitle').innerText = 'Edit Listener';
    document.getElementById('editIndex').value = idx;
    
    // Find the row - IMPORTANT: skip header row
    const rows = document.querySelectorAll('#listenerTable tr');
    if (rows.length <= idx + 1) {
        alert('Listener not found');
        return;
    }
    const row = rows[idx + 1];
    const cells = row.querySelectorAll('td');
    
    // cells[0]=index, cells[1]=listen, cells[2]=connect, cells[3]=fake_sni
    const listenParts = cells[1].innerText.split(':');
    const connectParts = cells[2].innerText.split(':');
    
    document.getElementById('listen_ip').value = listenParts[0] || '';
    document.getElementById('listen_port').value = listenParts[1] || '';
    document.getElementById('connect_ip').value = connectParts[0] || '';
    document.getElementById('connect_port').value = connectParts[1] || '';
    document.getElementById('fake_sni').value = cells[3].innerText;
    document.getElementById('conn_timeout').value = 5;
    document.getElementById('handshake_timeout').value = 2;
    document.getElementById('keepalive_time').value = 11;
    document.getElementById('keepalive_interval').value = 2;
    
    openModal('listenerModal');
}

function saveListener() {
    const data = {
        listen_ip: document.getElementById('listen_ip').value,
        listen_port: document.getElementById('listen_port').value,
        connect_ip: document.getElementById('connect_ip').value,
        connect_port: document.getElementById('connect_port').value,
        fake_sni: document.getElementById('fake_sni').value,
        conn_timeout: document.getElementById('conn_timeout').value,
        handshake_timeout: document.getElementById('handshake_timeout').value,
        keepalive_time: document.getElementById('keepalive_time').value,
        keepalive_interval: document.getElementById('keepalive_interval').value
    };
    const idx = document.getElementById('editIndex').value;
    const url = idx !== '' ? `/update_listener/${idx}` : '/add_listener';
    const method = idx !== '' ? 'PUT' : 'POST';

    fetch(url, {
        method: method,
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(data)
    }).then(res => res.json()).then(() => {
        location.reload();
    }).catch(err => {
        alert('Error: ' + err);
    });
}

function deleteListener(idx) {
    if (!confirm('Are you sure?')) return;
    fetch(`/delete_listener/${idx}`, { method: 'DELETE' })
        .then(res => res.json()).then(() => location.reload())
        .catch(err => alert('Error: ' + err));
}

// ---------- Settings ----------
function updateSettings() {
    const graceful = document.getElementById('graceful_shutdown').value;
    fetch('/update_settings', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ graceful_shutdown_sec: graceful })
    }).then(res => res.json()).then(() => {
        alert('Settings saved and service restarted');
        location.reload();
    }).catch(err => alert('Error: ' + err));
}

// ---------- Admin ----------
function createUser() {
    const username = document.getElementById('new_username').value;
    const password = document.getElementById('new_password').value;
    const is_admin = document.getElementById('new_is_admin').value;
    if (!username || !password) return alert('Fill all fields');
    fetch('/create_user', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ username, password, is_admin })
    }).then(res => res.json()).then(data => {
        if (data.status === 'ok') {
            alert('User created');
            document.getElementById('new_username').value = '';
            document.getElementById('new_password').value = '';
        } else {
            alert('Error: ' + data.message);
        }
    }).catch(err => alert('Error: ' + err));
}

function changePassword() {
    const old = document.getElementById('old_pass').value;
    const newp = document.getElementById('new_pass').value;
    if (!old || !newp) return alert('Fill all fields');
    fetch('/change_password', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ old_password: old, new_password: newp })
    }).then(res => res.json()).then(data => {
        if (data.status === 'ok') {
            alert('Password changed');
            document.getElementById('old_pass').value = '';
            document.getElementById('new_pass').value = '';
        } else {
            alert('Error: ' + data.message);
        }
    }).catch(err => alert('Error: ' + err));
}

function logout() {
    window.location.href = '/logout';
}

// Close modals when clicking outside
window.onclick = function(event) {
    if (event.target.classList.contains('modal')) {
        event.target.style.display = 'none';
    }
}
</script>
</body>
</html>
'''

if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=WEB_PORT, debug=False)
EOF

    # Replace placeholders
    sed -i "s/REPLACE_SECRET_KEY/$SECRET_KEY/g" "$WEB_PANEL_SCRIPT"
    sed -i "s/WEB_PORT = 5000/WEB_PORT = $WEB_PORT/g" "$WEB_PANEL_SCRIPT"
    chmod +x "$WEB_PANEL_SCRIPT"
    print_success "Web panel script generated."

    # Initialize database and create admin user
    print_info "Creating admin user in database..."
    cat > /tmp/init_db.py <<EOF
import sqlite3, bcrypt
DB_PATH = "$DB_PATH"
conn = sqlite3.connect(DB_PATH)
c = conn.cursor()
c.execute("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, password_hash TEXT, is_admin INTEGER DEFAULT 0)")
c.execute("SELECT id FROM users WHERE username=?", ("$ADMIN_USER",))
if not c.fetchone():
    hashed = bcrypt.hashpw(b"$ADMIN_PASS", bcrypt.gensalt()).decode()
    c.execute("INSERT INTO users (username, password_hash, is_admin) VALUES (?, ?, 1)", ("$ADMIN_USER", hashed))
    conn.commit()
    print("Admin user created.")
else:
    print("Admin user already exists.")
conn.close()
EOF
    python3 /tmp/init_db.py
    rm /tmp/init_db.py

    # Create systemd service for web panel
    print_info "Creating systemd service for web panel..."
    cat > "$WEB_PANEL_SERVICE" <<EOF
[Unit]
Description=SNI Spoof Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORKDIR
ExecStart=/usr/bin/python3 $WEB_PANEL_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sni-webpanel.service
    systemctl restart sni-webpanel.service
    print_success "Web panel service installed and restarted."

    # Show access info
    SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "your-server-ip")
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    print_success "Web Panel installed successfully!"
    echo -e "${CYAN}➜ Access URL: ${GREEN}http://$SERVER_IP:$WEB_PORT${NC}"
    echo -e "${CYAN}➜ Username: ${GREEN}$ADMIN_USER${NC}"
    echo -e "${CYAN}➜ Password: ${GREEN}(the one you entered)${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ---------- Main Menu ----------
main_menu() {
    local arch=$(detect_arch)
    while true; do
        echo ""
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        echo -e "${GREEN}    SNI-Spoof Tunnel Manager${NC}"
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        echo "1) Download Binary Only"
        echo "2) Setup Service (Create config + Start service)"
        echo "3) Update Binary and Restart"
        echo "4) Uninstall (Remove everything)"
        echo "5) Restart Service"
        echo "6) View Logs (live)"
        echo "7) Change Config Only"
        echo "8) Install Web Panel (management UI - no pre-config needed)"
        echo "9) Exit"
        echo -e "${BLUE}════════════════════════════════════════${NC}"
        safe_read choice "Your choice"
        
        case $choice in
            1) download_binary_only ;;
            2) setup_service ;;
            3) update_service ;;
            4) uninstall_service ;;
            5) restart_service ;;
            6) view_logs ;;
            7) change_config ;;
            8) install_web_panel ;;
            9) print_info "Exiting."; exit 0 ;;
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
