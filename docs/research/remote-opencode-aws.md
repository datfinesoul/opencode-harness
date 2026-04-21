# Remote OpenCode in AWS with Tailscale

## Overview

Tailscale creates a WireGuard-based VPN that makes your AWS instance accessible from anywhere as if it were on your local network. This is the most seamless approach for maintaining persistent sessions across multiple locations and devices.

**Why Tailscale for OpenCode:**
- No need to expose ports to the internet
- No SSH tunneling required each session
- Automatic HTTPS certificates via `tailscale serve`
- Works from any location, any device
- Free for personal use (up to 100 devices)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Your Device (Mac/Windows/Linux)                            │
│  ┌─────────────┐                                            │
│  │  Tailscale  │◄─── Tailscale VPN ────────────────────────│
│  │  Client     │                                            │
│  └─────────────┘                                            │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ WireGuard tunnel
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  AWS EC2 Instance                                           │
│  ┌─────────────┐   ┌─────────────────┐   ┌──────────────┐   │
│  │  Tailscale  │──►│ opencode serve  │──►│  Port 4096   │   │
│  │  Subnet     │   │  (localhost)    │   │  (internal)  │   │
│  │  Router     │   └─────────────────┘   └──────────────┘   │
│  └─────────────┘                                            │
│                                                             │
│  Security Group: No inbound ports needed!                   │
└─────────────────────────────────────────────────────────────┘
```

---

## Quick Setup

### Step 1: Create Tailscale Account

Sign up at [login.tailscale.com](https://login.tailscale.com/start) (free).

### Step 2: Launch AWS EC2 Instance

1. Launch an EC2 instance (Ubuntu 22.04 or Amazon Linux 2023)
2. Ensure it has a public IP or Elastic IP
3. **Important:** In security group, allow nothing inbound (no SSH, no custom TCP)

### Step 3: Install Tailscale on AWS

```bash
# SSH into your EC2 instance
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate (one-time)
sudo tailscale up

# Disable key expiry so you don't re-authenticate periodically
sudo tailscale set --operator=ubuntu
```

Visit the URL returned to authenticate the instance.

### Step 4: Install OpenCode on AWS

```bash
curl -fsSL https://opencode.ai/install | bash
```

### Step 5: Start OpenCode Server

```bash
# Simple approach - serves on localhost only
opencode serve --port 4096

# Or with password protection
OPENCODE_SERVER_PASSWORD=your-password opencode serve --port 4096
```

### Step 6: Connect from Your Devices

On each client device:

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to your tailnet
sudo tailscale up

# Access opencode - use the AWS instance's Tailscale IP
opencode connect https://<your-aws-hostname>.tailscale.ts.net:4096
```

---

## Advanced: Using Tailscale Serve (Recommended)

Tailscale Serve provides automatic HTTPS and makes the opencode server available via a friendly URL like `https://opencode-server.tailnet-name.ts.net`.

### On AWS Instance:

```bash
# Enable HTTPS certificates
sudo tailscale set --accept-dns=false  # Optional: accept DNS config

# Serve opencode on port 4096
sudo tailscale serve 4096

# Check the URL
tailscale serve status
```

### Access URL Format:

```
https://<hostname>.<tailnet>.ts.net
```

No port specification needed when using Tailscale Serve.

---

## AWS VPC with Subnet Router

For accessing multiple instances in a VPC private subnet, deploy a Tailscale subnet router:

### Step 1: Enable IP Forwarding on EC2

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```

### Step 2: Install and Configure as Subnet Router

```bash
sudo systemctl enable --now tailscaled
sudo tailscale set --advertise-routes=10.0.0.0/24,10.0.1.0/24
```

### Step 3: Approve Routes in Admin Console

1. Go to [login.tailscale.com/admin](https://login.tailscale.com/admin)
2. Find your EC2 instance
3. Click "Edit route settings" and enable the advertised routes

Now all devices in your tailnet can reach instances in those private subnets.

---

## Session Persistence

Sessions are stored in `~/.opencode/sessions/` on the AWS instance. To maintain sessions across reconnections:

1. Keep `opencode serve` running on the AWS instance (use `systemd` or `tmux`)
2. Sessions persist automatically
3. Reconnect using the same Tailscale URL from any device

```bash
# Keep opencode running with systemd
sudo tee /etc/systemd/system/opencode.service << 'EOF'
[Unit]
Description=OpenCode Server
After=network.target

[Service]
Type=simple
User=ubuntu
Environment="OPENCODE_SERVER_PASSWORD=your-password"
ExecStart=/usr/local/bin/opencode serve --port 4096
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable opencode
sudo systemctl start opencode
```

---

## AWS Instance Recommendations

| Instance Type | Use Case | Monthly Cost (est.) |
|---------------|----------|---------------------|
| `t3.medium` | Light usage, small projects | ~$15 |
| `t3.xlarge` | Heavy multi-file editing | ~$60 |
| `c6i.xlarge` | Compute-optimized, best price/performance | ~$40 |

**Storage:** Use instance store or EBS for session data.

---

## Security Benefits

| Without Tailscale | With Tailscale |
|-------------------|----------------|
| Must expose port 4096 to internet | No exposed ports |
| AWS security group management | Automatic private network |
| SSH tunnel complexity | Direct access as if local |
| IP-based restrictions | Tailscale identity + ACLs |

---

## Troubleshooting

### Instance not appearing in tailnet
```bash
sudo tailscale status
sudo tailscale netcheck
```

### Can't connect to opencode
```bash
# Check if opencode is running
sudo systemctl status opencode

# Check port is listening
sudo ss -tlnp | grep 4096
```

### Auth key expiry issues
```bash
# Disable key expiry in admin console or:
sudo tailscale set --key-expiry=0
```

---

## Alternative: Tailscale Funnel (Public Access)

If you need to share opencode access publicly (e.g., with teammates), use Funnel:

```bash
sudo tailscale funnel 4096
```

This exposes opencode at `https://your-hostname.tailnet-name.ts.net` publicly with Tailscale's TLS certificate.

**Note:** Funnel makes the service publicly accessible. Use `OPENCODE_SERVER_PASSWORD` for protection.
