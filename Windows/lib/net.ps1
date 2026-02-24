# =============================================================================
# net.ps1 — Funciones de calculo y validacion de redes IP
# Uso: . .\net.ps1
# Requiere: . .\ui.ps1
# =============================================================================

$MAX_ATTEMPTS = if ($env:MAX_ATTEMPTS) { [int]$env:MAX_ATTEMPTS } else { 100 }

# -----------------------------------------------------------------------------
# Conversion IP <-> entero
# -----------------------------------------------------------------------------

function IpToInt {
    param([string]$ip)
    if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $null }
    $parts = $ip -split '\.'
    foreach ($p in $parts) { if ([int]$p -gt 255) { return $null } }
    return ([int]$parts[0] * 16777216) + ([int]$parts[1] * 65536) + ([int]$parts[2] * 256) + [int]$parts[3]
}

function IntToIp {
    param([long]$num)
    if ($num -lt 0 -or $num -gt 4294967295) { return $null }
    return "{0}.{1}.{2}.{3}" -f (($num -shr 24) -band 255), (($num -shr 16) -band 255), (($num -shr 8) -band 255), ($num -band 255)
}

# -----------------------------------------------------------------------------
# Mascara / CIDR
# -----------------------------------------------------------------------------

function CidrToMask {
    param([int]$cidr)
    if ($cidr -lt 1 -or $cidr -gt 32) { return $null }
    $mask = 0L
    for ($i = 0; $i -lt $cidr; $i++) {
        $mask = $mask -bor (1L -shl (31 - $i))
    }
    return IntToIp $mask
}

function MaskToCidr {
    param([string]$mask)
    $maskInt = IpToInt $mask
    if ($null -eq $maskInt) { return $null }
    $cidr = 0
    for ($i = 31; $i -ge 0; $i--) {
        if ($maskInt -band (1L -shl $i)) { $cidr++ } else { break }
    }
    return $cidr
}

# -----------------------------------------------------------------------------
# Validacion
# -----------------------------------------------------------------------------

function Test-ValidCidr {
    param([int]$cidr)
    return ($cidr -ge 8 -and $cidr -le 30)
}

# $allowReserved = $true para permitir rangos especiales
function Test-ValidIp {
    param([string]$ip, [bool]$allowReserved = $false)
    if ([string]::IsNullOrEmpty($ip)) { return $false }
    if ($ip.Contains('/')) { $ip = $ip.Split('/')[0] }
    if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }
    $parts = $ip -split '\.'
    foreach ($p in $parts) { if ([int]$p -gt 255) { return $false } }

    if (-not $allowReserved) {
        $p = [int]$parts[0]; $q = [int]$parts[1]
        if ($p -eq 0)                             { return $false }  # 0.0.0.0/8
        if ($p -eq 127)                           { return $false }  # Loopback
        if ($p -eq 169 -and $q -eq 254)           { return $false }  # APIPA
        if ($p -ge 224 -and $p -le 239)           { return $false }  # Multicast
        if ($p -ge 240)                           { return $false }  # Reservado
        if ($ip -eq '255.255.255.255')            { return $false }  # Broadcast global
    }
    return $true
}

function Test-ValidIpCidr {
    param([string]$ipCidr)
    if ($ipCidr -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') { return $false }
    $parts = $ipCidr -split '/'
    return (Test-ValidIp $parts[0]) -and ([int]$parts[1] -ge 1) -and ([int]$parts[1] -le 32)
}

function Test-ValidIpOrCidr {
    param([string]$input)
    if ($input -match '/') { return Test-ValidIpCidr $input }
    else { return Test-ValidIp $input }
}

# -----------------------------------------------------------------------------
# Calculo de red
# -----------------------------------------------------------------------------

function Get-NetworkAddress {
    param([string]$ip, [string]$mask)
    $ipInt   = IpToInt $ip
    $maskInt = IpToInt $mask
    if ($null -eq $ipInt -or $null -eq $maskInt) { return $null }
    return IntToIp ($ipInt -band $maskInt)
}

function Get-BroadcastAddress {
    param([string]$network, [string]$mask)
    $netInt  = IpToInt $network
    $maskInt = IpToInt $mask
    if ($null -eq $netInt -or $null -eq $maskInt) { return $null }
    $invertedMask = (-bnot $maskInt) -band 0xFFFFFFFFL
    return IntToIp ($netInt -bor $invertedMask)
}

# -----------------------------------------------------------------------------
# Predicados
# -----------------------------------------------------------------------------

function Test-IpInNetwork {
    param([string]$ip, [string]$network, [string]$mask)
    $ipInt  = IpToInt $ip
    $netInt = IpToInt $network
    $mskInt = IpToInt $mask
    if ($null -eq $ipInt -or $null -eq $netInt -or $null -eq $mskInt) { return $false }
    return (($ipInt -band $mskInt) -eq ($netInt -band $mskInt))
}

function Test-IpIsNetwork   { param([string]$ip, [string]$network)   return $ip -eq $network }
function Test-IpIsBroadcast { param([string]$ip, [string]$broadcast) return $ip -eq $broadcast }

function Test-IpInRange {
    param([string]$ip, [string]$start, [string]$end)
    $ipInt    = IpToInt $ip
    $startInt = IpToInt $start
    $endInt   = IpToInt $end
    if ($null -eq $ipInt -or $null -eq $startInt -or $null -eq $endInt) { return $false }
    return ($ipInt -ge $startInt -and $ipInt -le $endInt)
}

# -----------------------------------------------------------------------------
# Validacion compuesta (requiere $NETWORK_ADDRESS, $MASCARA, $BROADCAST_ADDRESS, $CIDR en el scope llamador)
# -----------------------------------------------------------------------------

function Test-IpInSegment {
    param([string]$ip, [string]$label)
    if (-not (Test-ValidIp $ip)) {
        msg_error "IP $label invalida o en segmento no usable"
        return $false
    }
    if (-not (Test-IpInNetwork $ip $script:NETWORK_ADDRESS $script:MASCARA)) {
        msg_error "La IP $label no pertenece al segmento $script:NETWORK_ADDRESS/$script:CIDR"
        return $false
    }
    if (Test-IpIsNetwork $ip $script:NETWORK_ADDRESS) {
        msg_error "La IP $label no puede ser la direccion de red ($script:NETWORK_ADDRESS)"
        return $false
    }
    if (Test-IpIsBroadcast $ip $script:BROADCAST_ADDRESS) {
        msg_error "La IP $label no puede ser la direccion de broadcast ($script:BROADCAST_ADDRESS)"
        return $false
    }
    return $true
}

# Solicita una IP con reintentos. Devuelve $null si el usuario presiona Enter (omitir).
# $extraValidator = scriptblock adicional opcional
function Read-IpLoop {
    param([string]$prompt, [scriptblock]$extraValidator = $null)
    $attempts = 0
    while ($attempts -lt $MAX_ATTEMPTS) {
        msg_input $prompt
        $input = Read-Host
        if ([string]::IsNullOrEmpty($input)) { return $null }
        if (-not (Test-ValidIp $input)) {
            msg_error "IP invalida o en segmento no usable"
            $attempts++; continue
        }
        if ($null -ne $extraValidator -and -not (& $extraValidator $input)) {
            $attempts++; continue
        }
        return $input
    }
    msg_error "Demasiados intentos fallidos"
    return $false  # false = fallo total (distinto de null = omitido)
}

# -----------------------------------------------------------------------------
# Helpers para dns_manager
# -----------------------------------------------------------------------------

function Get-IpFromCidr    { param([string]$ipCidr) return ($ipCidr -split '/')[0] }
function Get-PrefixFromCidr{ param([string]$ipCidr) return ($ipCidr -split '/')[1] }

function Test-Dependency {
    param([string]$cmd)
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}