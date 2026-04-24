# Server Manager Scripts

Scripts for managing DHCP, DNS, SSH, FTP, HTTP, and SSL/TLS services on Linux (Fedora) and Windows Server, plus Active Directory management, Docker infrastructure, and domain-join automation. Each script is self-contained, requires root/administrator privileges, and can run interactively or via command-line arguments.

---

## Structure

```
.
├── Linux/
│   ├── dhcp_manager.sh
│   ├── dns_manager.sh
│   ├── ssh_manager.sh
│   ├── ftp_manager.sh
│   ├── ssl_manager.sh
│   ├── ws_manager.sh
│   ├── ftp_repo_builder.sh
│   ├── ftp_lib/
│   │   ├── ftp.sh              # Entry point, global variables, module loader
│   │   ├── ftp_install.sh      # Installation, initial setup and uninstallation
│   │   ├── ftp_users.sh        # FTP user CRUD
│   │   ├── ftp_groups.sh       # FTP group CRUD and directory permissions
│   │   ├── ftp_dirs.sh         # Directory structure and bind mounts
│   │   ├── ftp_service.sh      # vsftpd service control
│   │   └── ftp_config.sh       # vsftpd.conf editing and firewall management
│   ├── ssl_lib/
│   │   ├── ssl.sh              # Entry point, variables, module loader
│   │   ├── ssl_apache.sh       # Apache HTTP/HTTPS configuration
│   │   ├── ssl_nginx.sh        # Nginx HTTPS configuration
│   │   ├── ssl_tomcat.sh       # Tomcat HTTPS configuration and keystore management
│   │   ├── ssl_ftp.sh          # vsftpd FTPS (explicit TLS) configuration
│   │   ├── ssl_certs.sh        # Self-signed certificate generation and CSR creation
│   │   └── ssl_audit.sh        # SSL configuration audit and cipher suite validation
│   ├── ws_lib/
│   │   ├── ws_utils.sh         # Global variables, service constants, web root paths
│   │   ├── ws_install.sh       # Installation logic with SSL hook integration
│   │   ├── ws_config.sh        # Virtual host and port management
│   │   ├── ws_status.sh        # Service status and port listening checks
│   │   ├── ws_versions.sh      # Version comparison and update detection
│   │   ├── ws_monitor.sh       # Health checks and HTTP connectivity testing
│   │   ├── ws_validators.sh    # Input validation for domains, ports, paths
│   │   ├── ws_ftp_source.sh    # FTP repository integration with SHA256 verification
│   │   └── ws_security_audit.sh# HTTP security headers and configuration audit
│   └── lib/
│       ├── ui.sh               # Output formatting and colors
│       ├── net.sh              # IP validation and subnet calculations
│       ├── iface.sh            # Interface detection and configuration
│       └── utils.sh            # System checks (privileges, packages, services, ports)
│
├── Windows/
│   ├── dhcp_manager.ps1
│   ├── dns_manager.ps1
│   ├── ssh_manager.ps1
│   ├── ftp_manager.ps1
│   ├── ssl_manager.ps1
│   ├── ws_manager.ps1
│   ├── ac_manager.ps1
│   ├── ftp_lib/
│   │   ├── ftp.ps1             # Entry point, global variables, module loader
│   │   ├── ftp_install.ps1     # Installation, initial setup and uninstallation
│   │   ├── ftp_users.ps1       # FTP user CRUD
│   │   ├── ftp_groups.ps1      # FTP group CRUD and directory permissions
│   │   ├── ftp_dirs.ps1        # Directory structure and NTFS permissions
│   │   ├── ftp_service.ps1     # FTPSVC service control
│   │   └── ftp_config.ps1      # Site configuration editing and firewall management
│   ├── ssl_lib/
│   │   ├── ssl.ps1             # Entry point, variables, module loader
│   │   ├── ssl_apache.ps1      # Apache SSL configuration (Windows binaries)
│   │   ├── ssl_nginx.ps1       # Nginx SSL configuration
│   │   ├── ssl_tomcat.ps1      # Tomcat SSL configuration
│   │   ├── ssl_ftp.ps1         # IIS FTP SSL/TLS setup
│   │   ├── ssl_iis.ps1         # IIS native SSL binding via netsh and IIS modules
│   │   └── ssl_certs.ps1       # Self-signed certificate generation and certificate store management
│   ├── ws_lib/
│   │   ├── ws_utils.ps1        # Global variables, service constants, HTTP paths
│   │   ├── ws_install.ps1      # IIS role/feature and binary service installation
│   │   ├── ws_config.ps1       # Site/host configuration and port management
│   │   ├── ws_status.ps1       # Service status and version detection
│   │   ├── ws_versions.ps1     # Version comparison
│   │   ├── ws_monitor.ps1      # Health checks and HTTP connectivity
│   │   ├── ws_validators.ps1   # Input validation
│   │   └── ws_ftp_source.ps1   # FTP repository integration
│   ├── ac_lib/
│   │   ├── ac_ad.ps1           # Active Directory operations (OUs, users, groups)
│   │   ├── ac_csv.ps1          # Bulk user import from CSV
│   │   ├── ac_log.ps1          # Logging system with file and console output
│   │   ├── ac_logon.ps1        # Logon script management and GPO integration
│   │   ├── ac_fsrm.ps1         # File Server Resource Manager: quotas and file screening
│   │   ├── ac_applocker.ps1    # AppLocker rules and application whitelisting
│   │   └── ac_setup.ps1        # Domain controller and AD initial setup helpers
│   └── lib/
│       ├── ui.ps1              # Output formatting
│       ├── net.ps1             # IP validation and subnet calculations
│       ├── iface.ps1           # Interface detection and configuration
│       ├── utils.ps1           # System checks (privileges, packages, services, ports)
│       └── input.ps1           # Interactive input helpers with validation and retry
│
├── Docker/
│   ├── apache/
│   │   ├── Dockerfile          # Fedora 43, Apache + PHP-FPM via socket
│   │   ├── docker-compose.yml  # Port mapping, PostgreSQL env vars, FTP shared volume
│   │   ├── start.sh            # Entrypoint: PHP-FPM background + Apache foreground
│   │   ├── config/
│   │   │   ├── httpd.conf      # Apache virtual host and module configuration
│   │   │   ├── php-fpm.conf    # PHP-FPM pool configuration
│   │   │   └── security.conf   # Security headers and directory restrictions
│   │   └── web/
│   │       └── index.php       # Default web page
│   ├── nginx/
│   │   ├── Dockerfile          # Fedora 43, Nginx with custom user/group
│   │   ├── docker-compose.yml  # Port mapping, PostgreSQL/FTP env vars, shared volume
│   │   ├── start.sh            # Entrypoint script
│   │   ├── config/
│   │   │   └── nginx.conf      # Nginx server block and PHP-FPM proxy configuration
│   │   └── web/
│   │       └── index.php       # Default web page
│   ├── ftp/
│   │   ├── Dockerfile          # Fedora 43, vsftpd with PAM-based authentication
│   │   ├── docker-compose.yml  # Ports 21 + passive range 30000–30010, shared volume
│   │   └── entrypoint.sh       # Creates FTP user from env vars, configures PAM and PASV
│   └── postgres/
│       ├── Dockerfile          # postgres:16-alpine with backup utility
│       ├── docker-compose.yml  # Persistent volume, health check via pg_isready, infra_red network
│       └── init/
│           ├── 01_schema.sql   # Initial database schema
│           └── backup.sh       # Manual pg_dump to timestamped SQL file
│
└── Clients/
    ├── linux_client_setup.sh   # Fedora domain join: realmd, sssd, krb5, PAM homedir
    ├── win_client_setup.ps1    # Windows domain join: DNS, rename, AD join, WinRM, GPO
    ├── clientAD-v4.ps1         # Windows client setup v4
    └── clienteAD-v3.ps1        # Windows client setup v3
```

---

## Requirements

**Linux**
- Fedora Server (tested on Fedora 43)
- `bash`, `systemctl`, `nmcli`, `firewall-cmd`
- Optional: `ipcalc`, `sipcalc`, `grepcidr` (auto-installed if missing)
- HTTP managers: `httpd`, `nginx`, or `tomcat` (installed by `ws_manager.sh`)
- SSL managers: `openssl` (auto-installed if missing)
- Repository builder: `curl`, `dnf`, `sha256sum`
- Root privileges: `sudo`

**Windows**
- Windows Server 2022 (PowerShell 5.1+)
- Run as Administrator
- Modules: `NetTCPIP`, `NetAdapter` (included in Windows Server by default)
- FTP: IIS with Web-Ftp-Server and Web-Scripting-Tools features (auto-installed)
- HTTP: IIS or Windows binaries for Apache/Nginx/Tomcat (managed by `ws_manager.ps1`)
- AC Manager: Active Directory module (`RSAT-AD-PowerShell`), FSRM, AppLocker features

**Docker**
- Docker Engine + Docker Compose
- All services share the `infra_red` bridge network and the `ftp_shared` volume

**Client setup (standalone)**
- Linux: `realmd`, `sssd`, `adcli`, `krb5-workstation`, `samba-common-tools` (auto-installed)
- Windows: Windows 10/11 Pro or Windows Server, PowerShell 5.1+, Administrator privileges

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
sudo ./ssl_manager.sh
sudo ./ws_manager.sh

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

# Web services manager flags
sudo ./ws_manager.sh --debug
sudo ./ws_manager.sh --verify

# FTP repository builder
bash ./ftp_repo_builder.sh
bash ./ftp_repo_builder.sh ~/custom_output_path
```

### Windows

```powershell
# Interactive menu
.\dhcp_manager.ps1
.\dns_manager.ps1
.\ssh_manager.ps1
.\ftp_manager.ps1
.\ssl_manager.ps1
.\ws_manager.ps1
.\ac_manager.ps1

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

# Web services manager flags
.\ws_manager.ps1 -Debug
.\ws_manager.ps1 -Verify
```

### Docker

Each service has its own `docker-compose.yml`. Start the full stack by launching postgres first (it creates the shared network), then the other services.

```bash
cd Docker/postgres && docker compose up -d
cd Docker/ftp     && docker compose up -d
cd Docker/apache  && docker compose up -d
cd Docker/nginx   && docker compose up -d
```

### Domain join (standalone)

```bash
# Linux client — join Active Directory domain
sudo bash Clients/linux_client_setup.sh
```

```powershell
# Windows client — join Active Directory domain
PowerShell.exe -ExecutionPolicy Bypass -File .\Clients\win_client_setup.ps1
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

### ssl_manager

Configures SSL/TLS certificates and HTTPS/FTPS for already-installed services. Can run standalone against running services or be invoked automatically as a post-install hook from `ws_manager` or `ftp_manager`.

**Linux:** manages `httpd` (Apache), `nginx`, Tomcat, and `vsftpd` (explicit TLS via `AUTH TLS`). Generates self-signed certificates or processes CSRs with `openssl`. Includes an SSL audit that checks cipher suites and configuration.

**Windows:** manages IIS, Apache (Windows binaries), Nginx, Tomcat, and IIS FTP. Handles certificate generation, certificate store import, and SSL bindings via `netsh` and IIS PowerShell modules.

**Modules (both platforms):**
- Certificate generation and CSR creation
- Per-service SSL configuration (Apache, Nginx, Tomcat, FTP/FTPS)
- SSL configuration audit

### ws_manager

Installs, configures, and monitors HTTP services. Supports downloading packages from the internet (`dnf` / Windows binaries) or from a local FTP repository built with `ftp_repo_builder.sh`.

**Linux:** manages Apache (`httpd`), Nginx, and Tomcat. Configures virtual hosts, server blocks, and ports. Integrates with `ssl_manager` to enable HTTPS immediately after installation.

**Windows:** manages IIS (via Windows roles/features), and binary installations of Apache, Nginx, and Tomcat. Configures IIS sites and application pools.

**Shared features (both platforms):**
- Install, configure, status, monitor, and version-check for each HTTP service
- FTP repository source: installs packages from a local FTP server instead of the internet, with SHA256 integrity verification
- HTTP security headers and configuration audit

### ac_manager *(Windows only)*

Manages Active Directory users, groups, and organizational units on Windows Server 2022. Runs on the domain controller as Administrator.

**Modules:**
- `ac_ad.ps1` — OU, group, and user CRUD; group membership management
- `ac_csv.ps1` — bulk user import and operations from CSV files
- `ac_log.ps1` — structured logging to file and console
- `ac_logon.ps1` — logon script assignment and Group Policy integration
- `ac_fsrm.ps1` — disk quotas and file screening via File Server Resource Manager
- `ac_applocker.ps1` — AppLocker rules; application whitelisting and blacklisting
- `ac_setup.ps1` — initial domain controller and AD configuration helpers
- `ac_rbac.ps1` — role-based access control (optional)
- `ac_fgpp.ps1` — fine-grained password policies (optional)
- `ac_audit.ps1` — audit policy configuration (optional)

### ftp_repo_builder *(Linux only)*

Downloads Apache, Nginx, and Tomcat packages for both Linux (RPM) and Windows (ZIP/EXE), generates SHA256 hashes, and organizes them into a directory tree ready to be uploaded to the FTP server. After uploading, `ws_manager` can install services from this local repository without internet access.

**Output structure:**
```
~/ftp_repo/http/
├── Linux/
│   ├── Apache/   → httpd-*.rpm + .sha256
│   ├── Nginx/    → nginx-*.rpm + .sha256
│   └── Tomcat/   → tomcat*.rpm + .sha256
└── Windows/
    ├── Apache/   → httpd-*-win64-*.zip + .sha256
    ├── Nginx/    → nginx-*.zip + .sha256
    └── Tomcat/   → apache-tomcat-*.exe + .sha256
```

**Requires:** `curl`, `dnf`, `sha256sum`

---

## Docker Infrastructure

Four containerized services on a shared `infra_red` bridge network. All containers run on Fedora 43 base images (except PostgreSQL which uses `postgres:16-alpine`).

| Service | Image base | Ports | Notes |
|---------|-----------|-------|-------|
| Apache | Fedora 43 | 80, 443 | PHP-FPM via Unix socket |
| Nginx | Fedora 43 | 80, 443 | Reverse proxy or standalone |
| vsftpd | Fedora 43 | 21, 30000–30010 | PAM authentication, PASV configurable |
| PostgreSQL | postgres:16-alpine | 5432 | Persistent volume, health check |

**Shared resources:**
- `infra_red` bridge network — created by the postgres service; all others join it as external
- `ftp_shared` volume — mounted by Apache, Nginx, and vsftpd for file exchange
- `.env` files per service for credentials and configuration
- Resource limits (memory + CPU) on all containers
- Restart policy: `unless-stopped`

The FTP container creates its user from environment variables on startup, configures PAM authentication, sets the passive mode address and port range, then starts vsftpd.

PostgreSQL includes a `backup.sh` utility that runs `pg_dump` and writes a timestamped SQL file.

---

## Client Setup Scripts

Standalone scripts for joining machines to an Active Directory domain. Neither depends on `ac_manager` or any project library — all required values are prompted interactively.

### linux_client_setup.sh

Joins a Fedora 43+ machine (also compatible with RHEL/AlmaLinux) to an AD domain.

**Steps performed:**
1. Installs `realmd`, `sssd`, `adcli`, `krb5-workstation`, `samba-common-tools`
2. Configures `/etc/resolv.conf` to point to the domain controller
3. Changes the machine hostname
4. Joins the domain via `realm join`
5. Configures `sssd.conf` (home directory, shell, login without FQDN)
6. Configures PAM to auto-create home directories on first login
7. Optionally grants `sudo` to domain groups or users

### win_client_setup.ps1

Joins a Windows 10/11 Pro or Windows Server machine to an AD domain.

**Steps performed:**
1. Configures DNS to point to the domain controller
2. Renames the computer if needed
3. Joins the AD domain
4. Enables WinRM for remote administration
5. Forces a Group Policy refresh
6. Prompts for reboot

---

## Notes

- Each script validates all IP addresses and network segments before applying any configuration.
- Firewall rules are applied automatically during configuration (firewalld on Linux, Windows Firewall on Windows).
- Network interface configuration is persisted via NetworkManager (Linux) or `Set-NetIPAddress` (Windows).
- The `dns_manager` scripts use an `--override` flag to skip validation and blacklist checks, useful for lab or testing environments.
- SSH hardening disables password authentication. Ensure at least one authorized key is in place before applying it.
- FTP user directories on Linux use systemd `.mount` units for bind mounts, which persist across reboots. Run `ftp_manager.sh` → Repair permissions to restore any missing mounts after a reboot.
- FTP on Windows requires IIS to be available. The installer handles feature installation automatically, but a reboot may be required on systems where IIS has never been configured.
- `ssl_manager` depends on `ws_lib/ws_utils.sh` (Linux) or `ws_lib/ws_utils.ps1` (Windows) for HTTP service constants; install `ws_lib` alongside `ssl_lib` even when not using `ws_manager` directly.
- Docker services must be started with postgres first so the `infra_red` network exists before the other services try to join it.
- `ac_manager` optional modules (`ac_rbac`, `ac_fgpp`, `ac_audit`, `ac_mfa`) are loaded only if present; the manager starts normally if they are missing.
