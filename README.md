# Server Manager Scripts

Scripts for managing DHCP, DNS, and SSH services on Linux (Fedora) and Windows Server. Each script is self-contained, requires root/administrator privileges, and can run interactively or via command-line arguments.

---

## Structure

```
.
├── Linux/
│   ├── dhcp_manager.sh
│   ├── dns_manager.sh
│   ├── ssh_manager.sh
│   └── lib/
│       ├── ui.sh       # Output formatting and colors
│       ├── net.sh      # IP validation and subnet calculations
│       └── iface.sh    # Interface detection and configuration
│
└── Windows/
    ├── dhcp_manager.ps1
    ├── dns_manager.ps1
    ├── ssh_manager.ps1
    └── lib/
        ├── ui.ps1      # Output formatting
        ├── net.ps1     # IP validation and subnet calculations
        └── iface.ps1   # Interface detection and configuration
```

---

## Requirements

**Linux**
- Fedora Server (tested on Fedora 43)
- `bash`, `systemctl`, `nmcli`, `firewall-cmd`
- Optional: `ipcalc`, `sipcalc`, `grepcidr` (auto-installed if missing)
- Root privileges: `sudo`

**Windows**
- Windows Server 2022 (PowerShell 5.1+)
- Run as Administrator
- Modules: `NetTCPIP`, `NetAdapter` (included in Windows Server by default)

---

## Usage

All scripts follow the same pattern: run without arguments to open the interactive menu, or pass a command directly.

### Linux

```bash
# Interactive menu
sudo ./dhcp_manager.sh
sudo ./dns_manager.sh
sudo ./ssh_manager.sh

# Direct commands
sudo ./dhcp_manager.sh install
sudo ./dhcp_manager.sh configure
sudo ./dhcp_manager.sh status

sudo ./dns_manager.sh install --interface eth0 --ip 192.168.1.10/24
sudo ./dns_manager.sh create-zone --domain example.internal --ip 192.168.1.10
sudo ./dns_manager.sh create-reverse-zone --ip 192.168.1.10 --domain example.internal
sudo ./dns_manager.sh add-record --domain example.internal --hostname mail --type A --value 192.168.1.20
sudo ./dns_manager.sh test --domain example.internal

sudo ./ssh_manager.sh install
sudo ./ssh_manager.sh configure
sudo ./ssh_manager.sh harden
sudo ./ssh_manager.sh firewall --port 2222 --iface eth0
sudo ./ssh_manager.sh status
```

### Windows

```powershell
# Interactive menu
.\dhcp_manager.ps1
.\dns_manager.ps1
.\ssh_manager.ps1

# Direct commands
.\dns_manager.ps1 -Command Install -Adapter "Ethernet" -IP 192.168.1.10 -PrefixLength 24 -DNS 8.8.8.8
.\dns_manager.ps1 -Command CreateZone -Domain example.internal -IP 192.168.1.10
.\dns_manager.ps1 -Command ListZones
.\dns_manager.ps1 -Command AddRecord -Domain example.internal -HostName mail -Type A -Value 192.168.1.20
.\dns_manager.ps1 -Command Test -Domain example.internal

.\ssh_manager.ps1 install
.\ssh_manager.ps1 configure
.\ssh_manager.ps1 harden
.\ssh_manager.ps1 firewall --port 2222 --iface Ethernet
.\ssh_manager.ps1 status
```

---

## Scripts Overview

### dhcp_manager

Installs and configures a DHCP server. Guides through scope name, network segment, IP range, gateway, DNS, and lease time. The first IP of the range is assigned statically to the server interface; clients receive addresses from the second IP onward.

**Linux:** uses `dhcp-server` (ISC DHCP) via `dnf`.  
**Windows:** installs the DHCP Server Windows role; designed for Workgroup environments (no Active Directory required).

### dns_manager

Installs and configures a DNS server (BIND9 on Linux, Windows DNS Server on Windows). Manages forward and reverse zones, A and CNAME records. Includes a domain and IP blacklist to prevent accidental misconfiguration; use `--override` / `-Override` to bypass it.

**Linux commands:** `install`, `create-zone`, `create-reverse-zone`, `list-zones`, `show-zone`, `delete-zone`, `add-record`, `test`, `test-reverse`, `validate`, `status`, `logs`, `logs-follow`, `logs-errors`  
**Windows commands:** same set via `-Command` parameter.

### ssh_manager

Installs, configures, and monitors OpenSSH Server. Supports interactive configuration of port, authentication methods, root login policy, keepalive, and login banner. Includes a hardening profile that disables password authentication and applies modern cipher settings.

**Commands (both platforms):** `install`, `configure`, `harden`, `firewall`, `status`, `show`, `keys`, `start`, `stop`, `restart`, `reload`, `enable`, `disable`

The `keys` submenu handles key pair generation, adding authorized keys, listing, and deletion.

---

## Notes

- Each script validates all IP addresses and network segments before applying any configuration.
- Firewall rules are applied automatically during configuration (firewalld on Linux, Windows Firewall on Windows).
- Network interface configuration is persisted via NetworkManager (Linux) or `Set-NetIPAddress` (Windows).
- The `dns_manager` scripts use an `--override` flag to skip validation and blacklist checks, useful for lab or testing environments.
- SSH hardening disables password authentication. Ensure at least one authorized key is in place before applying it.