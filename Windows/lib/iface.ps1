# =============================================================================
# iface.ps1 — Gestion de interfaces de red y herramientas auxiliares
# Uso: . .\iface.ps1
# Requiere: . .\ui.ps1  . .\net.ps1
# =============================================================================

# -----------------------------------------------------------------------------
# Herramientas de red
# -----------------------------------------------------------------------------

# Esta funcion verifica que los cmdlets de red de Windows esten disponibles.
function Test-NetworkTools {
    $missing = @()
    if (-not (Get-Command 'Get-NetIPAddress' -ErrorAction SilentlyContinue))   { $missing += 'Get-NetIPAddress (NetTCPIP)' }
    if (-not (Get-Command 'Get-NetAdapter'   -ErrorAction SilentlyContinue))   { $missing += 'Get-NetAdapter (NetAdapter)' }
    if ($missing.Count -gt 0) {
        msg_alert "Modulos de red no encontrados: $($missing -join ', ')"
        msg_info  "Instala las caracteristicas de red de Windows o ejecuta en un sistema compatible"
        return $false
    }
    return $true
}

# -----------------------------------------------------------------------------
# Configuracion de interfaz
# -----------------------------------------------------------------------------

# Asigna IP/CIDR a la interfaz y persiste la configuracion.
# Variables de script requeridas: $script:INTERFAZ, $script:IP_ADAPTADOR, $script:CIDR
function Set-InterfaceIp {
    msg_process "Configurando IP $script:IP_ADAPTADOR/$script:CIDR en $script:INTERFAZ..."

    # Obtener indice del adaptador
    $adapter = Get-NetAdapter -Name $script:INTERFAZ -ErrorAction SilentlyContinue
    if ($null -eq $adapter) {
        msg_error "No se encontro el adaptador: $script:INTERFAZ"
        return $false
    }

    # Eliminar IPs previas en la interfaz
    $existingIps = Get-NetIPAddress -InterfaceAlias $script:INTERFAZ -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($oldIp in $existingIps) {
        try {
            Remove-NetIPAddress -InterfaceAlias $script:INTERFAZ -IPAddress $oldIp.IPAddress -Confirm:$false -ErrorAction Stop
        } catch {
            # -- DEBUG --
            msg_alert "No se pudo eliminar IP previa $($oldIp.IPAddress): $_"
        }
    }

    # Calcular gateway por defecto (primera IP del segmento) si no hay uno configurado
    $gwConfig = Get-NetRoute -InterfaceAlias $script:INTERFAZ -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    $gw = if ($gwConfig) { $gwConfig.NextHop } else { $null }

    try {
        if ($gw) {
            New-NetIPAddress -InterfaceAlias $script:INTERFAZ -IPAddress $script:IP_ADAPTADOR -PrefixLength $script:CIDR -DefaultGateway $gw -ErrorAction Stop | Out-Null
        } else {
            New-NetIPAddress -InterfaceAlias $script:INTERFAZ -IPAddress $script:IP_ADAPTADOR -PrefixLength $script:CIDR -ErrorAction Stop | Out-Null
        }
    } catch {
        # -- DEBUG --
        msg_alert "Detalle del error del sistema al configurar IP: $_"
        # Ignorar "ya existe"
        if ($_ -notmatch 'already exists|ObjectAlreadyExists') {
            msg_error "No se pudo configurar la IP: $_"
            return $false
        }
    }

    $script:INTERFAZ_IP = $script:IP_ADAPTADOR
    msg_success "IP configurada correctamente"
    return $true
}

# -----------------------------------------------------------------------------
# Consulta de interfaces
# -----------------------------------------------------------------------------

# Devuelve IP/CIDR actual de una interfaz (ej: 192.168.1.10/24)
function Get-InterfaceIpCidr {
    param([string]$interfaceName)
    $addr = Get-NetIPAddress -InterfaceAlias $interfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($addr) { return "$($addr.IPAddress)/$($addr.PrefixLength)" }
    return $null
}

# Devuelve solo la IP de una interfaz
function Get-InterfaceIp {
    param([string]$interfaceName)
    $cidr = Get-InterfaceIpCidr $interfaceName
    if ($cidr) { return Get-IpFromCidr $cidr }
    return $null
}

# Lista interfaces disponibles (excluye loopback)
function Get-NetworkInterfaces {
    Get-NetAdapter | Where-Object { $_.Name -ne 'Loopback Pseudo-Interface 1' } | ForEach-Object {
        $ip = Get-InterfaceIp $_.Name
        "  $($_.Name) - $($_.InterfaceDescription) ($($_.Status)) $(if ($ip) { "[$ip]" })"
    }
}

# Devuelve $true si la interfaz existe
function Test-InterfaceExists {
    param([string]$interfaceName)
    return [bool](Get-NetAdapter -Name $interfaceName -ErrorAction SilentlyContinue)
}

# Devuelve $true si la interfaz tiene IP estatica
function Test-StaticIp {
    param([string]$interfaceName)
    $addr = Get-NetIPAddress -InterfaceAlias $interfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $addr) { return $false }
    # En Windows: PrefixOrigin "Manual" indica IP estatica
    return ($addr.PrefixOrigin -eq 'Manual')
}

# Configura IP estatica en una interfaz.
# $interfaceName, $ipCidr (ej: 192.168.1.10/24), $dns
function Set-StaticIp {
    param([string]$interfaceName, [string]$ipCidr, [string]$dns)

    if (-not (Test-InterfaceExists $interfaceName)) {
        msg_error "La interfaz $interfaceName no existe"; return $false
    }
    if (-not (Test-ValidIpCidr $ipCidr)) {
        msg_error "IP/CIDR invalida: $ipCidr"; return $false
    }
    if (-not (Test-ValidIp $dns)) {
        msg_error "DNS invalida: $dns"; return $false
    }

    $ip     = Get-IpFromCidr $ipCidr
    $prefix = [int](Get-PrefixFromCidr $ipCidr)

    msg_info "Configurando IP estatica en $interfaceName..."

    # Eliminar configuracion DHCP e IPs previas
    try {
        Set-NetIPInterface -InterfaceAlias $interfaceName -Dhcp Disabled -ErrorAction Stop
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al deshabilitar DHCP: $_"
    }

    $existing = Get-NetIPAddress -InterfaceAlias $interfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($e in $existing) {
        try {
            Remove-NetIPAddress -InterfaceAlias $interfaceName -IPAddress $e.IPAddress -Confirm:$false -ErrorAction Stop
        } catch {
            # -- DEBUG --
            msg_alert "Error del sistema al eliminar IP $($e.IPAddress): $_"
        }
    }

    try {
        New-NetIPAddress -InterfaceAlias $interfaceName -IPAddress $ip -PrefixLength $prefix -ErrorAction Stop | Out-Null
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al asignar IP: $_"
        msg_error "No se pudo configurar la IP estatica: $_"
        return $false
    }

    try {
        Set-DnsClientServerAddress -InterfaceAlias $interfaceName -ServerAddresses $dns -ErrorAction Stop
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al configurar DNS: $_"
        msg_error "No se pudo configurar el DNS: $_"
        return $false
    }

    msg_success "IP estatica configurada: $ipCidr"
    return $true
}

# -----------------------------------------------------------------------------
# Firewall
# -----------------------------------------------------------------------------

# Devuelve el perfil de firewall activo en una interfaz (Domain/Private/Public)
function Get-InterfaceFirewallProfile {
    param([string]$interfaceName)
    try {
        $conn = Get-NetConnectionProfile -InterfaceAlias $interfaceName -ErrorAction Stop
        return $conn.NetworkCategory.ToString()   # DomainAuthenticated / Private / Public
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al obtener perfil de firewall: $_"
        return 'Public'
    }
}