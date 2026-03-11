# =============================================================================
# lib/utils.ps1 — Verificaciones de privilegios, servicios, red y usuarios
# Uso: . .\utils.ps1   (requiere lib/ui.ps1 cargado antes)
# =============================================================================

#Requires -Version 5.1

function check_privileges {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        msg_error "Este script requiere permisos de Administrador."
        msg_info  "Ejecute PowerShell como Administrador y reintente."
        return $false
    }

    msg_alert "Detectado ejecucion como Administrador"
    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
#   VERIFICACIÓN DE PAQUETES Y SERVICIOS
#   Equivalentes a check_package_installed / check_service_active /
#   check_service_enabled de utils.sh
# ─────────────────────────────────────────────────────────────────────────────

# Verifica si un paquete está instalado vía Chocolatey.
# Uso: check_package_installed "nginx"  → $true / $false
function check_package_installed {
    param([string]$Package)
    $result = choco list --local $Package 2>$null | Where-Object { $_ -match "^$Package " }
    return ($null -ne $result -and $result.Count -gt 0)
}

# Verifica si un servicio de Windows está corriendo (equivale a is-active).
# Uso: check_service_active "W3SVC"  → $true / $false
function check_service_active {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

# Verifica si un servicio arranca automáticamente en boot (equivale a is-enabled).
# Uso: check_service_enabled "W3SVC"  → $true / $false
function check_service_enabled {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.StartType -eq 'Automatic')
}

# ─────────────────────────────────────────────────────────────────────────────
#   RED
#   Equivalentes a get_interface_ip / check_connectivity /
#   check_port_listening de utils.sh
# ─────────────────────────────────────────────────────────────────────────────

# Devuelve la primera IP IPv4 de una interfaz de red.
# Uso: get_interface_ip "Ethernet"
function get_interface_ip {
    param([string]$InterfaceName)
    $addr = Get-NetIPAddress -InterfaceAlias $InterfaceName `
                             -AddressFamily IPv4 `
                             -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty IPAddress
    if ($addr) { return $addr }
    return "Sin IP"
}

# Lista interfaces de red activas excluyendo loopback.
# Equivalente a get_network_interfaces de utils.sh
function get_network_interfaces {
    return (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -ne 'Loopback' } |
            Select-Object -ExpandProperty Name)
}

# Verifica conectividad con un ping simple.
# Uso: check_connectivity "192.168.100.10"  → $true / $false
function check_connectivity {
    param([string]$HostTarget = "8.8.8.8")
    return (Test-Connection -ComputerName $HostTarget -Count 1 -Quiet -ErrorAction SilentlyContinue)
}

# Verifica si un puerto TCP está en escucha en localhost.
# Equivalente a check_port_listening de utils.sh (usa ss en Linux, netstat aquí)
# Uso: check_port_listening 80  → $true / $false
function check_port_listening {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conn -and $conn.Count -gt 0)
}

# ─────────────────────────────────────────────────────────────────────────────
#   USUARIOS DEL SISTEMA
# ─────────────────────────────────────────────────────────────────────────────

# Verifica si un usuario local de Windows existe.
# Equivalente a check_user_exists de utils.sh
# Uso: check_user_exists "apacheuser"  → $true / $false
function check_user_exists {
    param([string]$UserName)
    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    return ($null -ne $user)
}

# ─────────────────────────────────────────────────────────────────────────────
#   VISUAL: LÍNEAS Y CABECERAS
#   Equivalentes a draw_line / draw_header de utils.sh
# ─────────────────────────────────────────────────────────────────────────────

function draw_line {
    Write-Separator
}

# Cabecera con título centrado entre separadores.
# Uso: draw_header "Monitor HTTP"
function draw_header {
    param([string]$Title)
    Write-Host ""
    draw_line
    Write-Host "  $Title"
    draw_line
}