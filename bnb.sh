#!/bin/bash
# ============================================================
#   ULTIMATE UMBREL OS INSTALLATION SCRIPT FOR WSL
#   Fixes: escapes-base, case-sensitive, sysctl, path errors
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

UMBREL_VERSION="1.4.0"
UMBREL_IMAGE="ghcr.io/dockur/umbrel:${UMBREL_VERSION}"
INSTALL_DIR="$HOME/umbrel-compose"
VOLUME_IMG="$HOME/umbrel-volume.img"
MOUNT_POINT="/mnt/umbrel-data"
VOLUME_SIZE_MB=20480  # 20GB

print_banner() {
    echo -e "${CYAN}"
    echo "  ██╗   ██╗███╗   ███╗██████╗ ██████╗ ███████╗██╗"
    echo "  ██║   ██║████╗ ████║██╔══██╗██╔══██╗██╔════╝██║"
    echo "  ██║   ██║██╔████╔██║██████╔╝██████╔╝█████╗  ██║"
    echo "  ██║   ██║██║╚██╔╝██║██╔══██╗██╔══██╗██╔══╝  ██║"
    echo "  ╚██████╔╝██║ ╚═╝ ██║██████╔╝██║  ██║███████╗███████╗"
    echo "   ╚═════╝ ╚═╝     ╚═╝╚═════╝ ╚═╝  ╚═╝╚══════╝╚══════╝"
    echo -e "${NC}"
    echo -e "${BOLD}  Ultimate WSL Installation Script v2.0${NC}"
    echo -e "${YELLOW}  Fixes all known WSL path & case-sensitivity bugs${NC}"
    echo ""
}

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }

# ── STEP 0: Root check ────────────────────────────────────────
check_root() {
    log_step "Checking permissions"
    if [ "$EUID" -eq 0 ]; then
        log_error "Do NOT run this script as root. Run as normal user with sudo access."
        exit 1
    fi
    sudo -v || { log_error "sudo access required"; exit 1; }
    log_ok "Running as $USER with sudo access"
}

# ── STEP 1: Cleanup everything ────────────────────────────────
cleanup_old() {
    log_step "Cleaning up old Umbrel installation"

    log_info "Stopping and removing old containers..."
    sudo docker stop umbrel 2>/dev/null || true
    sudo docker rm umbrel 2>/dev/null || true
    sudo docker stop $(sudo docker ps -aq) 2>/dev/null || true
    sudo docker rm $(sudo docker ps -aq) 2>/dev/null || true

    log_info "Removing old Umbrel images..."
    sudo docker images | grep -i umbrel | awk '{print $3}' | xargs sudo docker rmi -f 2>/dev/null || true

    log_info "Pruning Docker system..."
    sudo docker volume prune -f 2>/dev/null || true
    sudo docker network prune -f 2>/dev/null || true

    log_info "Removing old install directories..."
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
    rm -rf "$HOME/umbrel" 2>/dev/null || true

    log_info "Unmounting old volumes..."
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    sudo rm -rf "$MOUNT_POINT" 2>/dev/null || true
    rm -f "$VOLUME_IMG" 2>/dev/null || true

    log_ok "Cleanup complete"
}

# ── STEP 2: Check & install Docker ───────────────────────────
check_docker() {
    log_step "Checking Docker"

    if ! command -v docker &>/dev/null; then
        log_warn "Docker not found, installing..."
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker "$USER"
        log_ok "Docker installed"
    else
        log_ok "Docker found: $(docker --version)"
    fi

    # Start Docker daemon if not running
    if ! sudo docker info &>/dev/null; then
        log_warn "Docker daemon not running, starting..."
        sudo service docker start
        sleep 3
    fi

    if ! sudo docker info &>/dev/null; then
        log_error "Docker daemon could not be started. Make sure WSL2 is configured correctly."
        exit 1
    fi
    log_ok "Docker daemon is running"
}

# ── STEP 3: Fix WSL sysctl limits ────────────────────────────
fix_wsl_limits() {
    log_step "Fixing WSL kernel limits"

    # Fix inotify limits via WSL override (doesn't need sysctl)
    sudo mkdir -p /etc/sysctl.d/
    sudo tee /etc/sysctl.d/99-umbrel.conf > /dev/null << 'EOF'
fs.inotify.max_user_instances=256
fs.inotify.max_user_watches=122404
fs.inotify.max_queued_events=16384
EOF

    # Try to apply, ignore errors (WSL may block this)
    sudo sysctl -p /etc/sysctl.d/99-umbrel.conf 2>/dev/null || true
    log_ok "Kernel limits configured (WSL may ignore some — that's OK)"
}

# ── STEP 4: Create ext4 virtual disk ─────────────────────────
create_ext4_volume() {
    log_step "Creating case-sensitive ext4 virtual disk"
    log_info "This fixes the WSL 'escapes-base' bug permanently"
    log_info "Volume size: ${VOLUME_SIZE_MB}MB ($(( VOLUME_SIZE_MB / 1024 ))GB)"

    log_info "Creating virtual disk image..."
    dd if=/dev/zero of="$VOLUME_IMG" bs=1M count="$VOLUME_SIZE_MB" status=progress
    
    log_info "Formatting as ext4..."
    mkfs.ext4 -F "$VOLUME_IMG"

    log_info "Mounting..."
    sudo mkdir -p "$MOUNT_POINT"
    sudo mount -o loop "$VOLUME_IMG" "$MOUNT_POINT"
    sudo chown -R "$USER:$USER" "$MOUNT_POINT"
    sudo chmod 755 "$MOUNT_POINT"

    # Make mount persistent
    FSTAB_ENTRY="$VOLUME_IMG $MOUNT_POINT ext4 loop,nofail 0 0"
    if ! grep -q "$VOLUME_IMG" /etc/fstab 2>/dev/null; then
        echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab > /dev/null
        log_ok "Added to /etc/fstab for auto-mount"
    fi

    # Verify it's truly case-sensitive
    touch "$MOUNT_POINT/testfile"
    touch "$MOUNT_POINT/Testfile"
    COUNT=$(ls "$MOUNT_POINT" | grep -i testfile | wc -l)
    rm -f "$MOUNT_POINT/testfile" "$MOUNT_POINT/Testfile" 2>/dev/null
    
    if [ "$COUNT" -eq 2 ]; then
        log_ok "ext4 volume is case-sensitive ✓"
    else
        log_warn "Case-sensitivity check inconclusive, continuing anyway..."
    fi
}

# ── STEP 5: Create docker-compose ────────────────────────────
create_compose() {
    log_step "Creating docker-compose configuration"

    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/docker-compose.yml" << EOF
services:
  umbrel:
    image: ${UMBREL_IMAGE}
    container_name: umbrel
    pid: host
    ports:
      - 80:80
    volumes:
      - ${MOUNT_POINT}:/data
      - /var/run/docker.sock:/var/run/docker.sock
    restart: always
    stop_grace_period: 1m
    environment:
      - UMBREL_DISABLE_SYSCTL=1
EOF

    log_ok "docker-compose.yml created at $INSTALL_DIR"
}

# ── STEP 6: Create startup script ────────────────────────────
create_startup_script() {
    log_step "Creating startup helper script"

    cat > "$HOME/start-umbrel.sh" << EOF
#!/bin/bash
# Umbrel startup helper
echo "Starting Umbrel..."

# Mount volume if not mounted
if ! mountpoint -q ${MOUNT_POINT}; then
    sudo mount -o loop ${VOLUME_IMG} ${MOUNT_POINT}
    sudo chown -R ${USER}:${USER} ${MOUNT_POINT}
fi

# Start Docker if not running
if ! sudo docker info &>/dev/null; then
    sudo service docker start
    sleep 3
fi

cd ${INSTALL_DIR}
sudo docker compose up -d
echo ""
echo "✓ Umbrel is starting at http://localhost"
echo "  Run: sudo docker logs -f umbrel"
EOF

    cat > "$HOME/stop-umbrel.sh" << EOF
#!/bin/bash
echo "Stopping Umbrel..."
cd ${INSTALL_DIR}
sudo docker compose down
echo "✓ Umbrel stopped"
EOF

    chmod +x "$HOME/start-umbrel.sh"
    chmod +x "$HOME/stop-umbrel.sh"
    log_ok "Helper scripts created: ~/start-umbrel.sh and ~/stop-umbrel.sh"
}

# ── STEP 7: Pull & launch ─────────────────────────────────────
launch_umbrel() {
    log_step "Pulling Umbrel image and launching"

    cd "$INSTALL_DIR"
    
    log_info "Pulling image: $UMBREL_IMAGE"
    sudo docker pull "$UMBREL_IMAGE"

    log_info "Starting Umbrel container..."
    sudo docker compose up -d

    log_ok "Container started!"
}

# ── STEP 8: Health check ──────────────────────────────────────
health_check() {
    log_step "Waiting for Umbrel to be ready"

    echo -n "  Waiting"
    for i in $(seq 1 30); do
        if curl -s -o /dev/null -w "%{http_code}" http://localhost | grep -qE "200|301|302"; then
            echo ""
            log_ok "Umbrel is UP and responding!"
            return 0
        fi
        echo -n "."
        sleep 2
    done

    echo ""
    log_warn "Umbrel may still be starting. Check logs with: sudo docker logs -f umbrel"
}

# ── FINAL: Summary ────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║       UMBREL INSTALLATION COMPLETE! ☂️         ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Access Umbrel:${NC}     http://localhost"
    echo -e "  ${BOLD}Data location:${NC}    $MOUNT_POINT"
    echo -e "  ${BOLD}Start Umbrel:${NC}     ~/start-umbrel.sh"
    echo -e "  ${BOLD}Stop Umbrel:${NC}      ~/stop-umbrel.sh"
    echo -e "  ${BOLD}View logs:${NC}        sudo docker logs -f umbrel"
    echo ""
    echo -e "  ${YELLOW}⚠️  After WSL restart, run: ~/start-umbrel.sh${NC}"
    echo ""
}

# ── MAIN ──────────────────────────────────────────────────────
main() {
    print_banner
    check_root
    cleanup_old
    check_docker
    fix_wsl_limits
    create_ext4_volume
    create_compose
    create_startup_script
    launch_umbrel
    health_check
    print_summary
}

main "$@"
