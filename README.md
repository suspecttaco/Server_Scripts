# Server Manager Scripts

Scripts for managing DHCP, DNS, SSH, and FTP services on Linux (Fedora) and Windows Server. Each script is self-contained, requires root/administrator privileges, and can run interactively or via command-line arguments.

---

## Structure

```
.
├── Linux/
│   ├── dhcp_manager.sh
│   ├── dns_manager.sh
│   ├── ssh_manager.sh
│   ├── ftp_manager.sh
│   ├── ftp_lib/
│   │   ├── ftp.sh          # Entry point, global variables, module loader
│   │   ├── ftp_install.sh  # Installation, initial setup and uninstallation
│   │   ├── ftp_users.sh    # FTP user CRUD
│   │   ├── ftp_groups.sh   # FTP group CRUD and directory permissions
│   │   ├── ftp_dirs.sh     # Directory structure and bind mounts
│   │   ├── ftp_service.sh  # vsftpd service control
│   │   └── ftp_config.sh   # vsftpd.conf editing and firewall management
│   └── lib/
│       ├── ui.sh           # Output formatting and colors
│       ├── net.sh          # IP validation and subnet calculations
│       └── iface.sh        # Interface detection and configuration
│
└── Windows/
    ├── dhcp_manager.ps1
    ├── dns_manager.ps1
    ├── ssh_manager.ps1
    ├── ftp_manager.ps1
    ├── ftp_lib/
    │   ├── ftp.ps1         # Entry point, global variables, module loader
    │   ├── ftp_install.ps1 # Installation, initial setup and uninstallation
    │   ├── ftp_users.ps1   # FTP user CRUD
    │   ├── ftp_groups.ps1  # FTP group CRUD and directory permissions
    │   ├── ftp_dirs.ps1    # Directory structure and NTFS permissions
    │   ├── ftp_service.ps1 # FTPSVC service control
    │   └── ftp_config.ps1  # Site configuration editing and firewall management
    └── lib/
        ├── ui.ps1          # Output formatting
        ├── net.ps1         # IP validation and subnet calculations
        └── iface.ps1       # Interface detection and configuration
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
- FTP: IIS with Web-Ftp-Server and Web-Scripting-Tools features (auto-installed)

---

## Usage

All scripts follow the same pattern: run without arguments to open the interactive menu, or pass a command directly.

### Linux

```bash
# Interactive menu
sudo ./dhcp_manager.sh
sudo ./dns_manager.sh
sudo ./ssh_manager.sh
sudo ./ftp_manager.sh

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
.\ftp_manager.ps1

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

### ftp_manager

Installs and configures an FTP server with multi-group user isolation. Users are confined to their own chroot directory but have access to a shared general folder and their group's shared folder.

**Linux:** uses `vsftpd` with local system user authentication via `/etc/shadow`. Each user's chroot is built using systemd bind mounts (instead of symlinks, which vsftpd cannot follow outside the chroot). ACLs control access to shared directories.

**Windows:** uses IIS FTP Service with User Isolation mode. Each user is isolated to `C:\FTP\LocalUser\<username>\`. Shared access to the general and group folders is provided via NTFS junction points. Authentication uses local Windows accounts.

Both platforms support:
- Multiple FTP groups with separate shared directories
- An anonymous read-only area (general folder)
- SSH/interactive login blocked for FTP users
- Firewall rules for port 21 and passive mode port range (default 30000–31000)
- SELinux configuration on Linux; NTFS permissions and IIS authorization rules on Windows

**Interactive menu sections:**
- Install / uninstall FTP server
- Manage users (create in batch, update, delete, list)
- Manage groups and directory permissions
- Service control (start, stop, restart, auto-start toggle)
- Configuration editing (banner, passive ports, anonymous access, firewall)

---

## Notes

- Each script validates all IP addresses and network segments before applying any configuration.
- Firewall rules are applied automatically during configuration (firewalld on Linux, Windows Firewall on Windows).
- Network interface configuration is persisted via NetworkManager (Linux) or `Set-NetIPAddress` (Windows).
- The `dns_manager` scripts use an `--override` flag to skip validation and blacklist checks, useful for lab or testing environments.
- SSH hardening disables password authentication. Ensure at least one authorized key is in place before applying it.
- FTP user directories on Linux use systemd `.mount` units for bind mounts, which persist across reboots. Run `ftp_manager.sh` → Repair permissions to restore any missing mounts after a reboot.
- FTP on Windows requires IIS to be available. The installer handles feature installation automatically, but a reboot may be required on systems where IIS has never been configured.