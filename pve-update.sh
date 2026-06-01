#!/bin/bash
# pve-update.sh — Weekly Proxmox cluster update script
# Runs on the primary node via cron. See README for setup instructions.
# Dry-run mode: DRY_RUN=1 ./pve-update.sh

set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

SHUTDOWN_TIMEOUT=300    # seconds to wait for guests to stop
REBOOT_TIMEOUT=600      # seconds to wait for node SSH + quorum
PVESH_RETRY=3
PVESH_RETRY_DELAY=5
DRY_RUN="${DRY_RUN:-0}"

# --- CONFIGURE THESE FOR YOUR ENVIRONMENT ---

# IPs of all nodes except the one running this script
REMOTE_NODES=("10.0.0.2" "10.0.0.3" "10.0.0.4")

# Human-readable labels for each remote node (must match Proxmox node names)
REMOTE_LABELS=("node2" "node3" "node4")

# Total number of nodes in your cluster (including the one running this script)
CLUSTER_NODE_COUNT=4

SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

# Map Proxmox node names to SSH IPs (empty string = local node running this script)
declare -A NODE_SSH=(
    ["node1"]=""
    ["node2"]="10.0.0.2"
    ["node3"]="10.0.0.3"
    ["node4"]="10.0.0.4"
)

GUEST_UPDATE_TIMEOUT=300  # seconds per guest package update run

# VMs to update via direct SSH instead of the guest agent.
# Key = vmid, value = "user@ip:ssh_key_path"
# Use for VMs where qemu-guest-agent is unavailable (e.g. Amazon Linux 2023).
# Leave empty if all your VMs have the guest agent installed.
declare -A VM_SSH_OVERRIDE=(
    # ["100"]="admin@10.0.0.50:/root/.ssh/id_rsa_vm100"
)

# --- END CONFIGURATION ---

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "FATAL: $*"; exit 1; }

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

pvesh_retry() {
    local attempt=0
    local output
    while [[ $attempt -lt $PVESH_RETRY ]]; do
        if output=$(pvesh "$@" 2>&1); then
            echo "$output"
            return 0
        fi
        attempt=$((attempt + 1))
        if [[ $attempt -lt $PVESH_RETRY ]]; then
            log "pvesh $* failed (attempt $attempt/$PVESH_RETRY), retrying in ${PVESH_RETRY_DELAY}s..."
            sleep "$PVESH_RETRY_DELAY"
        fi
    done
    die "pvesh $* failed after $PVESH_RETRY attempts"
}

preflight_check() {
    log "=== Step 0: Pre-flight quorum check ==="
    local quorate
    quorate=$(pvecm status | awk '/^Quorate/{print $2}')
    [[ "$quorate" == "Yes" ]] || die "Cluster not quorate (Quorate: $quorate). Aborting."

    local online
    online=$(pvesh get /nodes --output-format json | \
        python3 -c "import sys,json; nodes=json.load(sys.stdin); print(sum(1 for n in nodes if n['status']=='online'))")
    [[ "$online" -eq "$CLUSTER_NODE_COUNT" ]] || die "Only $online/$CLUSTER_NODE_COUNT nodes online. Aborting."
    log "Pre-flight OK: $online nodes online, cluster quorate."
}

update_guests() {
    log "=== Step 1: Updating packages in all running guests ==="

    local all_nodes
    mapfile -t all_nodes < <(pvesh get /nodes --output-format json | \
        python3 -c "import sys,json; [print(n['node']) for n in json.load(sys.stdin)]")

    # Base64-encode the update command to survive multiple SSH quoting layers.
    # Detects apt (Debian/Ubuntu) vs dnf (Amazon Linux/RHEL) vs yum (older RHEL).
    local encoded_cmd
    encoded_cmd=$(cat << 'GUESTSCRIPT' | base64 -w0
if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -q && \
    DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade && \
    apt-get autoremove --purge -y
elif command -v dnf &>/dev/null; then
    dnf upgrade -y && dnf autoremove -y
elif command -v yum &>/dev/null; then
    yum update -y
else
    echo "No supported package manager found" >&2; exit 1
fi
GUESTSCRIPT
    )

    for node in "${all_nodes[@]}"; do
        local ssh_host="${NODE_SSH[$node]:-}"

        # LXCs — pct exec is reliable and propagates exit codes
        while IFS= read -r vmid; do
            [[ -z "$vmid" ]] && continue
            log "  Updating LXC $vmid on $node..."
            if [[ -z "$ssh_host" ]]; then
                run pct exec "$vmid" -- bash -c "echo '$encoded_cmd' | base64 -d | bash" \
                    || log "  WARNING: LXC $vmid update failed — skipping"
            else
                run ssh $SSH_OPTS root@"$ssh_host" "pct exec $vmid -- bash -c 'echo $encoded_cmd | base64 -d | bash'" \
                    || log "  WARNING: LXC $vmid update failed — skipping"
            fi
        done < <(pvesh get /nodes/"$node"/lxc --output-format json 2>/dev/null | \
            python3 -c "
import sys, json
for v in json.load(sys.stdin):
    if v.get('status') == 'running':
        print(v['vmid'])
" || true)

        # VMs — requires qemu-guest-agent; failures are non-fatal
        while IFS= read -r vmid; do
            [[ -z "$vmid" ]] && continue
            local ostype
            ostype=$(pvesh get /nodes/"$node"/qemu/"$vmid"/config --output-format json 2>/dev/null | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('ostype',''))" || echo "")
            if [[ "$ostype" == w* ]]; then
                log "  Skipping VM $vmid on $node (Windows — $ostype)"
                continue
            fi
            # Check for SSH override before falling back to guest agent
            if [[ -n "${VM_SSH_OVERRIDE[$vmid]:-}" ]]; then
                local override="${VM_SSH_OVERRIDE[$vmid]}"
                local ssh_target="${override%%:*}"
                local ssh_key="${override##*:}"
                log "  Updating VM $vmid on $node (via SSH override: $ssh_target)..."
                run ssh $SSH_OPTS -i "$ssh_key" "$ssh_target" \
                    "echo '$encoded_cmd' | base64 -d | sudo bash" \
                    || log "  WARNING: VM $vmid SSH update failed — skipping"
                continue
            fi

            log "  Updating VM $vmid on $node (via guest agent)..."
            if [[ -z "$ssh_host" ]]; then
                run qm guest exec "$vmid" --timeout "$GUEST_UPDATE_TIMEOUT" -- \
                    bash -c "echo '$encoded_cmd' | base64 -d | bash" \
                    || log "  WARNING: VM $vmid update failed (guest agent unavailable?) — skipping"
            else
                run ssh $SSH_OPTS root@"$ssh_host" \
                    "qm guest exec $vmid --timeout $GUEST_UPDATE_TIMEOUT -- bash -c 'echo $encoded_cmd | base64 -d | bash'" \
                    || log "  WARNING: VM $vmid update failed (guest agent unavailable?) — skipping"
            fi
        done < <(pvesh get /nodes/"$node"/qemu --output-format json 2>/dev/null | \
            python3 -c "
import sys, json
for v in json.load(sys.stdin):
    if v.get('status') == 'running':
        print(v['vmid'])
" || true)
    done

    log "Guest updates complete."
}

shutdown_all_guests() {
    log "=== Step 2: Shutting down all VMs and LXCs ==="

    local all_nodes
    mapfile -t all_nodes < <(pvesh get /nodes --output-format json | \
        python3 -c "import sys,json; [print(n['node']) for n in json.load(sys.stdin)]")

    declare -a guest_list=()

    # Pass 1: collect all guests without issuing shutdowns yet
    for node in "${all_nodes[@]}"; do
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            guest_list+=("$entry")
        done < <(pvesh get /nodes/"$node"/qemu --output-format json 2>/dev/null | \
            python3 -c "
import sys, json
node = sys.argv[1]
for v in json.load(sys.stdin):
    if v.get('status') == 'running':
        print(f'{node}:qemu:{v[\"vmid\"]}')
" "$node" || true)

        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            guest_list+=("$entry")
        done < <(pvesh get /nodes/"$node"/lxc --output-format json 2>/dev/null | \
            python3 -c "
import sys, json
node = sys.argv[1]
for v in json.load(sys.stdin):
    if v.get('status') == 'running':
        print(f'{node}:lxc:{v[\"vmid\"]}')
" "$node" || true)
    done

    if [[ "${#guest_list[@]}" -eq 0 ]]; then
        log "No running guests found."
        return 0
    fi

    # Pass 2: issue all shutdowns in a tight loop with 1s stagger
    log "Issuing shutdown to ${#guest_list[@]} guest(s)..."
    for entry in "${guest_list[@]}"; do
        local node="${entry%%:*}"
        local type="${entry#*:}"; type="${type%:*}"
        local vmid="${entry##*:}"
        log "Shutting down $type $vmid on $node"
        run pvesh_retry create /nodes/"$node"/"$type"/"$vmid"/status/shutdown
        sleep 1
    done

    log "All shutdown commands issued. Polling for stopped state..."

    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY-RUN] Skipping shutdown polling — no real commands were issued."
        return 0
    fi

    local elapsed=0
    while [[ $elapsed -lt $SHUTDOWN_TIMEOUT ]]; do
        local still_running=0
        for entry in "${guest_list[@]}"; do
            local node="${entry%%:*}"
            local type="${entry#*:}"; type="${type%:*}"
            local vmid="${entry##*:}"
            local status
            status=$(pvesh get /nodes/"$node"/"$type"/"$vmid"/status/current \
                --output-format json 2>/dev/null | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" || echo "unknown")
            [[ "$status" == "stopped" ]] || still_running=$((still_running + 1))
        done
        [[ $still_running -eq 0 ]] && break
        log "Waiting for $still_running guest(s)... (${elapsed}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    for entry in "${guest_list[@]}"; do
        local node="${entry%%:*}"
        local type="${entry#*:}"; type="${type%:*}"
        local vmid="${entry##*:}"
        local status
        status=$(pvesh get /nodes/"$node"/"$type"/"$vmid"/status/current \
            --output-format json 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" || echo "unknown")
        if [[ "$status" != "stopped" ]]; then
            log "WARNING: $type $vmid on $node still running after ${SHUTDOWN_TIMEOUT}s — hard stopping"
            run pvesh_retry create /nodes/"$node"/"$type"/"$vmid"/status/stop
        fi
    done

    log "All guests stopped."
}

check_zfs_health() {
    local host="$1"
    local label="$2"
    log "ZFS health check on $label..."
    local degraded
    if [[ "$host" == "local" ]]; then
        degraded=$(zpool status | grep -cE 'DEGRADED|FAULTED|UNAVAIL' || true)
    else
        degraded=$(ssh root@"$host" "zpool status" | grep -cE 'DEGRADED|FAULTED|UNAVAIL' || true)
    fi
    [[ "$degraded" -eq 0 ]] || die "Degraded ZFS pool on $label. Aborting."
    log "ZFS OK on $label."
}

check_zfs_mounts() {
    local host="$1"
    local label="$2"
    local unmounted
    unmounted=$(ssh root@"$host" "zfs list -H -o name,mounted | awk '\$2==\"no\"{print \$1}' | wc -l")
    if [[ "$unmounted" -gt 0 ]]; then
        log "WARNING: $unmounted ZFS dataset(s) not mounted on $label — investigate manually."
    else
        log "ZFS mounts OK on $label."
    fi
}

wait_for_ssh() {
    local host="$1"
    local label="$2"
    local timeout="${3:-$REBOOT_TIMEOUT}"
    log "Waiting for SSH on $label ($host)..."
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if ssh $SSH_OPTS root@"$host" true 2>/dev/null; then
            log "SSH up on $label (${elapsed}s)."
            return 0
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done
    die "Timeout waiting for SSH on $label after ${timeout}s."
}

wait_for_quorum() {
    local label="$1"
    local timeout="${2:-$REBOOT_TIMEOUT}"
    log "Waiting for quorum after $label reboot..."
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local quorate
        quorate=$(pvecm status 2>/dev/null | awk '/^Quorate/{print $2}' || echo "No")
        if [[ "$quorate" == "Yes" ]]; then
            local online
            online=$(pvesh get /nodes --output-format json 2>/dev/null | \
                python3 -c "import sys,json; nodes=json.load(sys.stdin); print(sum(1 for n in nodes if n['status']=='online'))" || echo 0)
            if [[ "$online" -eq "$CLUSTER_NODE_COUNT" ]]; then
                log "Quorum restored, all $CLUSTER_NODE_COUNT nodes online (${elapsed}s)."
                return 0
            fi
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done
    die "Quorum not restored after $label reboot — aborting to protect remaining nodes."
}

update_remote_node() {
    local host="$1"
    local label="$2"
    log "=== Updating $label ($host) ==="
    check_zfs_health "$host" "$label"
    log "Running apt upgrade on $label..."
    run ssh root@"$host" bash << 'REMOTE'
DEBIAN_FRONTEND=noninteractive apt-get update -q && \
DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    dist-upgrade && \
apt-get autoremove --purge -y
REMOTE
    log "Rebooting $label..."
    run ssh root@"$host" "reboot" || true
    sleep 30
    # Combined 10-minute budget for SSH + quorum (subtract the 30s sleep)
    local remaining=$((REBOOT_TIMEOUT - 30))
    local ssh_start
    ssh_start=$(date +%s)
    wait_for_ssh "$host" "$label" "$remaining"
    local ssh_elapsed=$(( $(date +%s) - ssh_start ))
    local quorum_budget=$(( remaining - ssh_elapsed ))
    [[ $quorum_budget -lt 30 ]] && quorum_budget=30
    wait_for_quorum "$label" "$quorum_budget"
    check_zfs_mounts "$host" "$label"
}

update_remote_nodes() {
    log "=== Step 3: Updating remote nodes ==="
    for i in "${!REMOTE_NODES[@]}"; do
        update_remote_node "${REMOTE_NODES[$i]}" "${REMOTE_LABELS[$i]}"
    done
}

update_self() {
    log "=== Step 4: Updating self ($(hostname)) ==="
    check_zfs_health "local" "$(hostname)"
    log "Running apt upgrade on $(hostname)..."
    run bash << 'LOCAL'
DEBIAN_FRONTEND=noninteractive apt-get update -q && \
DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    dist-upgrade && \
apt-get autoremove --purge -y
LOCAL
    log "Update complete. Rebooting $(hostname) — script complete."
    run /sbin/reboot
}

main() {
    log "========================================="
    log "PVE Auto-Update starting (DRY_RUN=${DRY_RUN})"
    log "========================================="
    preflight_check
    update_guests
    shutdown_all_guests
    update_remote_nodes
    update_self
}

main "$@"
