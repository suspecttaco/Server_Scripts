# =============================================================================
# dns_manager.ps1 — Gestor de servidor DNS para Windows Server
# Requiere: . .\lib\ui.ps1  . .\lib\net.ps1  . .\lib\iface.ps1
# =============================================================================
#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)][string]$Command,
    [Parameter(Mandatory=$false)][switch]$Override,
    [Parameter(Mandatory=$false)][string]$Adapter,
    [Parameter(Mandatory=$false)][string]$IP,
    [Parameter(Mandatory=$false)][int]$PrefixLength = 24,
    [Parameter(Mandatory=$false)][string]$DNS,
    [Parameter(Mandatory=$false)][string]$Domain,
    [Parameter(Mandatory=$false)][string]$HostName,
    [Parameter(Mandatory=$false)][string]$Type,
    [Parameter(Mandatory=$false)][string]$Value,
    [Parameter(Mandatory=$false)][int]$TTL
)

# Importar librerias (deben ir despues del bloque param)
. "$PSScriptRoot\lib\ui.ps1"
. "$PSScriptRoot\lib\net.ps1"
. "$PSScriptRoot\lib\iface.ps1"

#==============================================================================
# CONSTANTES Y VARIABLES GLOBALES
#==============================================================================

$Script:Version     = "1.0.0"
$Script:OverrideMode = $false

$Script:BlacklistDomains = @(
    "localhost","local","invalid","test",
    "example.com","example.net","example.org","example.edu"
)

# IPs ya cubiertas por Test-ValidIp de lib_net, pero se mantiene para PTR records
$Script:BlacklistIPs = @("0.0.0.0","255.255.255.255","127.0.0.1","127.0.0.53")

$Script:DefaultTTL           = New-TimeSpan -Days 7
$Script:DefaultRefresh       = New-TimeSpan -Days 7
$Script:DefaultRetry         = New-TimeSpan -Days 1
$Script:DefaultExpire        = New-TimeSpan -Days 28
$Script:DefaultNegativeCache = New-TimeSpan -Days 7

#==============================================================================
# FUNCIONES DE VALIDACION
# Se reemplazan las validaciones de IP/red por lib_net donde es posible.
# Se mantiene la logica de blacklist de dominio (especifica de DNS).
#==============================================================================

function Test-BlacklistedDomain {
    param([string]$Domain)
    if ($Script:OverrideMode) { return $false }
    foreach ($b in $Script:BlacklistDomains) {
        if ($Domain -eq $b -or $Domain -like "*.$b") { return $true }
    }
    return $false
}

# Valida IP para contexto DNS: usa Test-ValidIp de lib_net + blacklist propia.
# Override desactiva todas las restricciones.
function Test-DNSValidIP {
    param([string]$IPAddress)
    if ($Script:OverrideMode) { return $true }
    # Test-ValidIp (lib_net) cubre: formato, loopback, APIPA, multicast, reservado
    if (-not (Test-ValidIp $IPAddress)) { return $false }
    # Blacklist adicional especifica de DNS
    if ($Script:BlacklistIPs -contains $IPAddress) { return $false }
    return $true
}

function Test-ValidDomain {
    param([string]$Domain)
    if ($Script:OverrideMode) { return $true }
    $regex = '^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    if ($Domain -notmatch $regex)               { return $false }
    if (Test-BlacklistedDomain -Domain $Domain)  { return $false }
    return $true
}

function Get-ReverseZoneFromIP {
    param([string]$IP)
    $o = $IP -split '\.'
    return "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"
}

function Get-ReversePTRName {
    param([string]$IP)
    return ($IP -split '\.')[3]
}

#==============================================================================
# GESTION DE RED
# Reemplazada con funciones de lib_iface y lib_net
#==============================================================================

# Lista adaptadores activos (lib_iface: Get-NetworkInterfaces ya lo hace,
# pero necesitamos solo los "Up" para instalacion DNS)
function Get-NetworkAdapters {
    msg_info "Adaptadores de red disponibles:"
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        $ip = Get-InterfaceIp $_.Name   # lib_iface
        $ipLabel = if ($ip) { " [$ip]" } else { "" }
        Write-Host "  $($_.Name) - $($_.InterfaceDescription)$ipLabel"
    }
}

# Verifica IP estatica — delegado a lib_iface
function Test-StaticIPAdapter {
    param([string]$AdapterName)
    return (Test-StaticIp $AdapterName)   # lib_iface
}

# Configura IP estatica — delegado a lib_iface
function Set-StaticIPConfiguration {
    param(
        [string]$AdapterName,
        [string]$IPAddress,
        [int]$PrefixLength,
        [string]$DNSAddress
    )

    if (-not (Test-DNSValidIP $IPAddress)) {
        msg_error "IP invalida o en blacklist: $IPAddress"
        return $false
    }
    if (-not (Test-DNSValidIP $DNSAddress)) {
        msg_error "DNS invalida: $DNSAddress"
        return $false
    }

    # Set-StaticIp de lib_iface acepta IP/CIDR y DNS
    $ipCidr = "$IPAddress/$PrefixLength"
    return (Set-StaticIp -interfaceName $AdapterName -ipCidr $ipCidr -dns $DNSAddress)
}

#==============================================================================
# INSTALACION Y CONFIGURACION DE DNS
#==============================================================================

function Install-DNSServerRole {
    $dnsInstalled = Get-WindowsFeature -Name DNS | Where-Object { $_.Installed }

    if ($dnsInstalled) {
        msg_info "DNS Server ya esta instalado"
        return $true
    }

    try {
        msg_process "Instalando DNS Server..."
        Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null
        msg_success "DNS Server instalado correctamente"
        return $true
    }
    catch {
        msg_error "Error al instalar DNS Server: $_"
        return $false
    }
}

function Add-DNSFirewallRule {
    msg_process "Configurando firewall..."
    $rules = Get-NetFirewallRule -DisplayName "DNS*" -ErrorAction SilentlyContinue

    if (-not $rules) {
        New-NetFirewallRule -DisplayName "DNS (UDP-In)" -Direction Inbound -Protocol UDP -LocalPort 53 -Action Allow | Out-Null
        New-NetFirewallRule -DisplayName "DNS (TCP-In)" -Direction Inbound -Protocol TCP -LocalPort 53 -Action Allow | Out-Null
        msg_success "Reglas de firewall creadas"
    }
    else {
        msg_info "Reglas de firewall ya existen"
    }
}

function Start-DNSServerService {
    try {
        Add-DNSFirewallRule
        Start-Service DNS -ErrorAction Stop
        Set-Service DNS -StartupType Automatic
        msg_success "Servicio DNS iniciado"
        return $true
    }
    catch {
        msg_error "Error al iniciar DNS: $_"
        return $false
    }
}

#==============================================================================
# GESTION DE ZONAS DNS
#==============================================================================

function Test-DNSZoneExists {
    param([string]$ZoneName)
    return ($null -ne (Get-DnsServerZone -Name $ZoneName -ErrorAction SilentlyContinue))
}

function New-DNSForwardZone {
    param(
        [string]$ZoneName,
        [string]$IPAddress,
        [timespan]$TTL          = $Script:DefaultTTL,
        [timespan]$Refresh      = $Script:DefaultRefresh,
        [timespan]$Retry        = $Script:DefaultRetry,
        [timespan]$Expire       = $Script:DefaultExpire,
        [timespan]$NegativeCache = $Script:DefaultNegativeCache
    )

    if (-not (Test-ValidDomain $ZoneName)) {
        msg_error "Dominio invalido o en blacklist: $ZoneName"
        return $false
    }
    if (-not (Test-DNSValidIP $IPAddress)) {
        msg_error "IP invalida o en blacklist: $IPAddress"
        return $false
    }
    if (Test-DNSZoneExists $ZoneName) {
        msg_error "La zona $ZoneName ya existe"
        return $false
    }

    try {
        Add-DnsServerPrimaryZone -Name $ZoneName -ZoneFile "$ZoneName.dns"
        Set-DnsServerZoneAging   -Name $ZoneName -Aging $false
        Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name "ns"  -IPv4Address $IPAddress -TimeToLive $TTL
        Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name "@"   -IPv4Address $IPAddress -TimeToLive $TTL
        Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name "www" -IPv4Address $IPAddress -TimeToLive $TTL
        msg_success "Zona $ZoneName creada correctamente"
        return $true
    }
    catch {
        msg_error "Error al crear zona: $_"
        return $false
    }
}

function New-DNSReverseZone {
    param(
        [string]$IPAddress,
        [string]$DomainName,
        [timespan]$TTL = $Script:DefaultTTL
    )

    if (-not (Test-DNSValidIP $IPAddress)) {
        msg_error "IP invalida o en blacklist: $IPAddress"
        return $false
    }

    $reverseZone = Get-ReverseZoneFromIP $IPAddress
    $ptrName     = Get-ReversePTRName    $IPAddress

    if (-not (Test-DNSZoneExists $reverseZone)) {
        try {
            msg_process "Creando zona inversa $reverseZone..."
            Add-DnsServerPrimaryZone -NetworkID ($IPAddress -replace '\.\d+$', '.0/24') -ZoneFile "$reverseZone.dns"
        }
        catch {
            msg_error "Error al crear zona inversa: $_"
            return $false
        }
    }

    try {
        Add-DnsServerResourceRecordPtr -ZoneName $reverseZone -Name $ptrName -PtrDomainName "$DomainName." -TimeToLive $TTL
        msg_success "Zona inversa configurada correctamente"
        return $true
    }
    catch {
        msg_error "Error al anadir registro PTR: $_"
        return $false
    }
}

function Get-DNSZoneList {
    msg_info "Zonas DNS configuradas:"
    Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated } | ForEach-Object {
        Write-Host "  - $($_.ZoneName)"
    }
}

function Remove-DNSZoneByName {
    param([string]$ZoneName)

    if (-not (Test-ValidDomain $ZoneName)) {
        msg_error "Dominio invalido: $ZoneName"
        return $false
    }
    if (-not (Test-DNSZoneExists $ZoneName)) {
        msg_error "La zona $ZoneName no existe"
        return $false
    }

    try {
        Remove-DnsServerZone -Name $ZoneName -Force
        msg_success "Zona $ZoneName eliminada"
        return $true
    }
    catch {
        msg_error "Error al eliminar zona: $_"
        return $false
    }
}

function Add-DNSResourceRecord {
    param(
        [string]$ZoneName,
        [string]$HostName,
        [string]$Type,
        [string]$Value
    )

    if (-not (Test-DNSZoneExists $ZoneName)) {
        msg_error "La zona $ZoneName no existe"
        return $false
    }

    try {
        switch ($Type.ToUpper()) {
            'A' {
                if (-not (Test-DNSValidIP $Value)) {
                    msg_error "IP invalida: $Value"
                    return $false
                }
                Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $HostName -IPv4Address $Value
            }
            'CNAME' {
                Add-DnsServerResourceRecordCName -ZoneName $ZoneName -Name $HostName -HostNameAlias "$Value."
            }
            default {
                msg_error "Tipo de registro no soportado: $Type"
                return $false
            }
        }
        msg_success "Registro $HostName ($Type) anadido a $ZoneName"
        return $true
    }
    catch {
        msg_error "Error al anadir registro: $_"
        return $false
    }
}

function Show-DNSZone {
    param([string]$ZoneName)

    if (-not (Test-DNSZoneExists $ZoneName)) {
        msg_error "La zona $ZoneName no existe"
        return $false
    }

    msg_info "Contenido de la zona $ZoneName :"
    Get-DnsServerResourceRecord -ZoneName $ZoneName | Format-Table -AutoSize
}

#==============================================================================
# VALIDACION Y PRUEBAS
#==============================================================================

function Test-DNSResolution {
    param([string]$Domain)
    msg_process "Probando resolucion de $Domain..."
    try {
        $result = Resolve-DnsName -Name $Domain -Server 127.0.0.1 -ErrorAction Stop
        msg_success "Resolucion exitosa: $Domain -> $($result.IPAddress)"
        return $true
    }
    catch {
        msg_error "No se pudo resolver $Domain"
        return $false
    }
}

function Test-DNSReverseResolution {
    param([string]$IPAddress)
    msg_process "Probando resolucion inversa de $IPAddress..."
    try {
        $result = Resolve-DnsName -Name $IPAddress -Server 127.0.0.1 -Type PTR -ErrorAction Stop
        msg_success "Resolucion inversa exitosa: $IPAddress -> $($result.NameHost)"
        return $true
    }
    catch {
        msg_error "No se pudo resolver inversamente $IPAddress"
        return $false
    }
}

function Get-DNSServerStatus {
    $service = Get-Service DNS -ErrorAction SilentlyContinue

    if ($service.Status -eq 'Running') {
        msg_success "DNS Server esta en ejecucion"
        $service | Format-List Name, Status, StartType
        return $true
    }
    else {
        msg_error "DNS Server no esta en ejecucion"
        return $false
    }
}

#==============================================================================
# AYUDA
#==============================================================================

function Show-Help {
    @"
DNS Server Manager v$($Script:Version) - Windows Server 2022

USO: .\dns_manager.ps1 -Command <COMANDO> [-Override] [OPCIONES]

INSTALACION:
  -Command Install -Adapter <NOMBRE> [-IP <IP>] [-PrefixLength <N>]

RED:
  -Command ListAdapters
  -Command CheckStaticIP -Adapter <NOMBRE>
  -Command SetStaticIP -Adapter <NOMBRE> -IP <IP> -PrefixLength <N> -DNS <DNS>

ZONAS:
  -Command CreateZone       -Domain <DOMINIO> -IP <IP> [-TTL <segundos>]
  -Command CreateReverseZone -IP <IP> -Domain <DOMINIO>
  -Command ListZones
  -Command ShowZone         -Domain <DOMINIO>
  -Command DeleteZone       -Domain <DOMINIO>

REGISTROS:
  -Command AddRecord -Domain <DOMINIO> -HostName <HOST> -Type <A|CNAME> -Value <VALOR>

VALIDACION:
  -Command Test        -Domain <DOMINIO>
  -Command TestReverse -IP <IP>
  -Command Status

  -Override   Omite validaciones y blacklist

VALORES POR DEFECTO:
  TTL: 7 dias | Refresh: 7 dias | Retry: 1 dia | Expire: 28 dias | Negative: 7 dias
"@
}

#==============================================================================
# FUNCION PRINCIPAL
#==============================================================================

function Invoke-DNSManager {
    param(
        [string]$Command,
        [switch]$Override,
        [string]$Adapter,
        [string]$IP,
        [int]$PrefixLength = 24,
        [string]$DNS,
        [string]$Domain,
        [string]$HostName,
        [string]$Type,
        [string]$Value,
        [int]$TTL
    )

    if ($Override) { $Script:OverrideMode = $true }

    switch ($Command.ToLower()) {
        'help' {
            Show-Help
        }
        'install' {
            if (-not $Adapter) { msg_error "Se requiere -Adapter"; return }

            Install-DNSServerRole

            if ($IP) {
                Set-StaticIPConfiguration -AdapterName $Adapter -IPAddress $IP -PrefixLength $PrefixLength -DNSAddress $DNS
            }

            Start-DNSServerService
        }
        'listadapters' {
            # Verifica herramientas de red (lib_iface) antes de listar
            if (Test-NetworkTools) { Get-NetworkAdapters }
        }
        'checkstaticip' {
            if (-not $Adapter) { msg_error "Se requiere -Adapter"; return }

            if (Test-StaticIPAdapter $Adapter) {   # usa Test-StaticIp de lib_iface
                msg_success "IP estatica configurada en $Adapter"
            }
            else {
                msg_info "No hay IP estatica en $Adapter"
            }
        }
        'setstaticip' {
            if (-not $Adapter -or -not $IP -or -not $DNS) {
                msg_error "Se requieren -Adapter, -IP y -DNS"
                return
            }
            Set-StaticIPConfiguration -AdapterName $Adapter -IPAddress $IP -PrefixLength $PrefixLength -DNSAddress $DNS
        }
        'createzone' {
            if (-not $Domain -or -not $IP) { msg_error "Se requieren -Domain y -IP"; return }

            if ($TTL) {
                New-DNSForwardZone -ZoneName $Domain -IPAddress $IP -TTL (New-TimeSpan -Seconds $TTL)
            }
            else {
                New-DNSForwardZone -ZoneName $Domain -IPAddress $IP
            }
        }
        'createreversezone' {
            if (-not $IP -or -not $Domain) { msg_error "Se requieren -IP y -Domain"; return }
            New-DNSReverseZone -IPAddress $IP -DomainName $Domain
        }
        'listzones' {
            Get-DNSZoneList
        }
        'showzone' {
            if (-not $Domain) { msg_error "Se requiere -Domain"; return }
            Show-DNSZone -ZoneName $Domain
        }
        'deletezone' {
            if (-not $Domain) { msg_error "Se requiere -Domain"; return }
            Remove-DNSZoneByName -ZoneName $Domain
        }
        'addrecord' {
            if (-not $Domain -or -not $HostName -or -not $Type -or -not $Value) {
                msg_error "Se requieren -Domain, -HostName, -Type y -Value"
                return
            }
            Add-DNSResourceRecord -ZoneName $Domain -HostName $HostName -Type $Type -Value $Value
        }
        'test' {
            if (-not $Domain) { msg_error "Se requiere -Domain"; return }
            Test-DNSResolution -Domain $Domain
            Test-DNSResolution -Domain "www.$Domain"
        }
        'testreverse' {
            if (-not $IP) { msg_error "Se requiere -IP"; return }
            Test-DNSReverseResolution -IPAddress $IP
        }
        'status' {
            Get-DNSServerStatus
        }
        default {
            Show-Help
        }
    }
}

# Si se ejecuta directamente
if ($MyInvocation.InvocationName -ne '.') {
    # Verifica que las herramientas de red esten disponibles (lib_iface)
    if (-not (Test-NetworkTools)) { exit 1 }

    Invoke-DNSManager @PSBoundParameters
}