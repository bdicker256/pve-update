# pve-update.sh

Weekly automated update script for a Proxmox VE cluster. Runs on one primary node and handles the full update sequence: guest package updates → guest shutdown → remote node updates (with reboots) → self update and reboot.

Supports clusters of any size (1–N nodes).

## What It Does

1. **Pre-flight check** — verifies the cluster is quorate and all nodes are online before touching anything
2. **Update guests** — runs `apt`/`dnf`/`yum` inside every running LXC and VM across all nodes
3. **Shut down guests** — gracefully stops all VMs and LXCs, waits up to 5 minutes, hard-stops stragglers
4. **Update remote nodes** — SSHes into each remote node, runs apt upgrade, reboots, and waits for SSH + quorum to restore before moving to the next
5. **Update self** — upgrades the node running the script and reboots

## Dependencies

All of the following must be present on the primary node:

| Dependency | Purpose |
|---|---|
| `pvesh` | Proxmox API CLI — lists nodes, guests, issues shutdown commands |
| `pvecm` | Proxmox cluster manager — checks quorum status |
| `pct` | Proxmox container tool — exec commands in LXCs |
| `qm` | Proxmox VM tool — exec commands in VMs via guest agent |
| `python3` | Parses JSON output from `pvesh` |
| `ssh` / `openssh-client` | SSHes into remote Proxmox nodes |
| `zpool` | ZFS pool health checks (pre-update on each node) |
| `base64` | Encodes guest update commands to survive SSH quoting |

All of these ship with Proxmox VE by default — no additional packages needed.

### Guest Requirements

- **LXCs**: no special requirements; uses `pct exec`
- **VMs (Linux)**: requires `qemu-guest-agent` installed and running inside the VM
- **VMs (Windows)**: skipped automatically
- **VMs without guest agent**: add an SSH override — see [Configuration](#configuration) below

## Installation

### 1. Download the script

On your primary Proxmox node:

```bash
curl -o /usr/local/sbin/pve-update.sh https://raw.githubusercontent.com/bdicker256/pve-update/main/pve-update.sh
chmod +x /usr/local/sbin/pve-update.sh
```

Or copy it from this repo:

```bash
scp pve-update.sh root@<your-primary-node-ip>:/usr/local/sbin/pve-update.sh
ssh root@<your-primary-node-ip> chmod +x /usr/local/sbin/pve-update.sh
```

### 2. Configure the script

Edit the configuration block near the top of the script. There are four things to set:

**Remote node IPs and labels** — list all nodes except the primary:

```bash
REMOTE_NODES=("10.0.0.2" "10.0.0.3" "10.0.0.4")
REMOTE_LABELS=("node2" "node3" "node4")
```

The labels must match the Proxmox node names shown in the web UI. To list them:

```bash
pvesh get /nodes --output-format json | python3 -c "import sys,json; [print(n['node']) for n in json.load(sys.stdin)]"
```

**Total node count:**

```bash
CLUSTER_NODE_COUNT=4  # including the primary node running this script
```

**NODE_SSH map** — maps each Proxmox node name to its IP. The primary node gets an empty string:

```bash
declare -A NODE_SSH=(
    ["node1"]=""        # primary — leave empty
    ["node2"]="10.0.0.2"
    ["node3"]="10.0.0.3"
    ["node4"]="10.0.0.4"
)
```

### 3. Set up passwordless SSH

The script SSHes into remote nodes as `root`. Run these on the primary node:

```bash
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
ssh-copy-id root@<node2-ip>
ssh-copy-id root@<node3-ip>
# repeat for each remote node
```

Test it before relying on cron:

```bash
ssh root@<node2-ip> hostname
```

### 4. Log rotation (optional)

Prevents `/var/log/pve-update.log` from growing unbounded (keeps 8 weeks, compressed):

```bash
curl -o /etc/logrotate.d/pve-update https://raw.githubusercontent.com/bdicker256/pve-update/main/pve-update.logrotate
```

Or copy manually:

```bash
scp pve-update.logrotate root@<your-primary-node-ip>:/etc/logrotate.d/pve-update
```

## Configuration

### SSH Override for VMs Without Guest Agent

For VMs where `qemu-guest-agent` isn't available (e.g. Amazon Linux 2023), add entries to `VM_SSH_OVERRIDE` in the config block:

```bash
declare -A VM_SSH_OVERRIDE=(
    ["100"]="admin@10.0.0.50:/root/.ssh/id_rsa_vm100"
    # ["<vmid>"]="<user>@<ip>:<path_to_ssh_key>"
)
```

The key is the VM ID (visible in the Proxmox UI) and the value is `user@ip:/path/to/ssh/key`. Leave the array empty if all your VMs have the guest agent.

### Timeouts

```bash
SHUTDOWN_TIMEOUT=300      # seconds to wait for guests to stop gracefully (default: 5 min)
REBOOT_TIMEOUT=600        # seconds to wait for a rebooted node to come back (default: 10 min)
GUEST_UPDATE_TIMEOUT=300  # seconds allowed per guest package update (default: 5 min)
```

Increase these if you have slow VMs or a large number of guests.

## Automating with Cron

Add a cron entry on the primary node to run the script weekly:

```bash
crontab -e
```

Add this line to run at **3:00 AM every Monday**:

```
0 3 * * 1 /usr/local/sbin/pve-update.sh >> /var/log/pve-update.log 2>&1
```

Adjust the time as needed — [crontab.guru](https://crontab.guru) is handy for building cron expressions.

Verify the entry was saved:

```bash
crontab -l
```

## Testing with Dry Run

Before scheduling, do a dry run to verify the script can reach all nodes and enumerate guests without making any changes:

```bash
DRY_RUN=1 /usr/local/sbin/pve-update.sh
```

All commands are logged with a `[DRY-RUN]` prefix and nothing is executed. Review the output to confirm it's finding the right nodes and guests.

## Logs

Logs land in `/var/log/pve-update.log`. To watch a run live:

```bash
tail -f /var/log/pve-update.log
```
