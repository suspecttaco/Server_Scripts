# =============================================================================
# ac_lib/ac_setup.ps1 — Instalacion de prerequisitos y promocion del DC
# Uso: . .\ac_lib\ac_setup.ps1
# Requiere: lib/ui.ps1, lib/input.ps1, ac_lib/ac_log.ps1
# Se ejecuta ANTES del menu principal en ac_manager.ps1
# =============================================================================

#Requires -Version 5.1
#Requires -RunAsAdministrator

# -----------------------------------------------------------------------------
# CONSTANTES
# -----------------------------------------------------------------------------

# Roles y caracteristicas requeridos en el servidor
$script:SETUP_REQUIRED_FEATURES = @(
    @{ Name = 'AD-Domain-Services';         Label = 'Active Directory Domain Services'; Critical = $true  }
    @{ Name = 'RSAT-AD-Tools';              Label = 'RSAT: Herramientas AD';             Critical = $true  }
    @{ Name = 'RSAT-AD-PowerShell';         Label = 'RSAT: Modulo AD PowerShell';        Critical = $true  }
    @{ Name = 'GPMC';                       Label = 'Consola de administracion de GPO';  Critical = $true  }
    @{ Name = 'RSAT-DNS-Server';            Label = 'RSAT: Herramientas DNS';            Critical = $false }
    @{ Name = 'DNS';                        Label = 'Servidor DNS';                      Critical = $false }
    @{ Name = 'FS-Resource-Manager';        Label = 'Administrador de recursos FSRM';    Critical = $false }
    @{ Name = 'RSAT-File-Services';         Label = 'RSAT: Herramientas de archivo';     Critical = $false }
)

# -----------------------------------------------------------------------------
# Test-FeatureInstalled
# Verifica si un rol/caracteristica de Windows esta instalado.
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Test-FeatureInstalled {
    param([string] $FeatureName)
    try {
        $f = Get-WindowsFeature -Name $FeatureName -ErrorAction Stop
        return $f.InstallState -eq 'Installed'
    } catch {
        return $false
    }
}

# -----------------------------------------------------------------------------
# Test-IsDomainController
# Verifica si este servidor ya es un Domain Controller activo.
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Test-IsDomainController {
    try {
        $role = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).DomainRole
        # DomainRole: 4 = Backup DC, 5 = Primary DC
        return $role -ge 4
    } catch {
        return $false
    }
}

# -----------------------------------------------------------------------------
# Test-ADDSRunning
# Verifica si el servicio NTDS (AD DS) esta corriendo.
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Test-ADDSRunning {
    $svc = Get-Service -Name 'NTDS' -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

# -----------------------------------------------------------------------------
# Get-SetupStatus
# Audita el estado actual de todos los prerequisitos.
# Devuelve: hashtable con el estado de cada componente
# -----------------------------------------------------------------------------
function Get-SetupStatus {
    $status = @{
        IsAdmin         = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        IsDC            = Test-IsDomainController
        ADDSRunning     = Test-ADDSRunning
        Features        = @{}
        NeedsReboot     = $false
        AllCriticalOK   = $false
    }

    foreach ($feature in $script:SETUP_REQUIRED_FEATURES) {
        $status.Features[$feature.Name] = @{
            Label     = $feature.Label
            Installed = Test-FeatureInstalled $feature.Name
            Critical  = $feature.Critical
        }
    }

    # Verificar si hay reboot pendiente
    $rebootKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $status.NeedsReboot = Test-Path $rebootKey

    # Determinar si todos los criticos estan OK
    $criticalFailing = @($status.Features.Values |
        Where-Object { $_.Critical -and -not $_.Installed })
    $status.AllCriticalOK = ($criticalFailing.Count -eq 0) -and $status.ADDSRunning

    return $status
}

# -----------------------------------------------------------------------------
# Show-SetupStatus
# Muestra el estado actual de los prerequisitos en consola.
# -----------------------------------------------------------------------------
function Show-SetupStatus {
    param([hashtable] $Status)

    Write-Host ""
    Write-Host "  Estado del entorno:" -ForegroundColor Cyan
    Write-Separator

    # Admin
    $icon  = if ($Status.IsAdmin) { "[ OK ]" } else { "[FAIL]" }
    $color = if ($Status.IsAdmin) { 'Green' } else { 'Red' }
    Write-Host "    " -NoNewline
    Write-Host $icon -ForegroundColor $color -NoNewline
    Write-Host " Ejecutando como Administrador"

    # DC
    $icon  = if ($Status.IsDC) { "[ OK ]" } else { "[ -- ]" }
    $color = if ($Status.IsDC) { 'Green' } else { 'Yellow' }
    Write-Host "    " -NoNewline
    Write-Host $icon -ForegroundColor $color -NoNewline
    Write-Host " Servidor es Domain Controller: $(if ($Status.IsDC) { 'Si' } else { 'No (se configurara)' })"

    # AD DS running
    $icon  = if ($Status.ADDSRunning) { "[ OK ]" } else { "[ -- ]" }
    $color = if ($Status.ADDSRunning) { 'Green' } else { 'Yellow' }
    Write-Host "    " -NoNewline
    Write-Host $icon -ForegroundColor $color -NoNewline
    Write-Host " Servicio AD DS (NTDS): $(if ($Status.ADDSRunning) { 'Running' } else { 'No activo' })"

    Write-Host ""
    Write-Host "  Roles y caracteristicas:" -ForegroundColor Cyan

    foreach ($name in $Status.Features.Keys) {
        $f     = $Status.Features[$name]
        $icon  = if ($f.Installed) { "[ OK ]" } else { if ($f.Critical) { "[FALT]" } else { "[ -- ]" } }
        $color = if ($f.Installed) { 'Green' } else { if ($f.Critical) { 'Red' } else { 'Yellow' } }
        Write-Host "    " -NoNewline
        Write-Host $icon -ForegroundColor $color -NoNewline
        Write-Host " $($f.Label)"
    }

    if ($Status.NeedsReboot) {
        Write-Host ""
        Write-Host "    [WARN] Hay un reinicio pendiente del sistema." -ForegroundColor Yellow
    }

    Write-Separator
}

# -----------------------------------------------------------------------------
# Install-RequiredFeatures
# Instala todos los roles y caracteristicas faltantes en una sola pasada.
# Agrupa criticos y opcionales, pide confirmacion por separado.
#
# Devuelve: $true si todos los criticos quedaron instalados | $false
# -----------------------------------------------------------------------------
function Install-RequiredFeatures {
    param([hashtable] $Status)

    $missing = @($Status.Features.GetEnumerator() |
               Where-Object { -not $_.Value.Installed } |
               Sort-Object { -not $_.Value.Critical })

    if ($missing.Count -eq 0) {
        Write-Log INFO "Todos los roles y caracteristicas ya estan instalados."
        return $true
    }

    $criticalMissing  = @($missing | Where-Object { $_.Value.Critical  })
    $optionalMissing  = @($missing | Where-Object { -not $_.Value.Critical })

    # ── Criticos ──────────────────────────────────────────────────────────────
    if ($criticalMissing.Count -gt 0) {
        Write-Host ""
        msg_alert "Caracteristicas criticas faltantes:"
        $criticalMissing | ForEach-Object { msg_info "  - $($_.Value.Label)" }
        Write-Host ""

        $install = Read-Confirm `
            -Prompt "Instalar las caracteristicas criticas ahora (requerido para continuar)" `
            -Default 'S'

        if (-not $install) {
            Write-Log ERROR "El usuario rechazo instalar las caracteristicas criticas. No se puede continuar."
            return $false
        }

        $names = $criticalMissing | ForEach-Object { $_.Key }
        msg_process "Instalando caracteristicas criticas: $($names -join ', ')"
        msg_alert   "Esto puede tardar varios minutos..."

        try {
            $result = Invoke-Logged "Instalar roles criticos: $($names -join ', ')" {
                Install-WindowsFeature `
                    -Name               $names `
                    -IncludeManagementTools `
                    -ErrorAction        Stop
            } -PassThru $true

            # Verificar resultado
            $failed = @()
            foreach ($name in $names) {
                if (-not (Test-FeatureInstalled $name)) {
                    $failed += $name
                }
            }

            if ($failed.Count -gt 0) {
                Write-Log ERROR "No se pudieron instalar: $($failed -join ', ')"
                return $false
            }

            Write-Log SUCCESS "Caracteristicas criticas instaladas correctamente."

            # Verificar si se requiere reinicio
            if ($result -and $result.RestartNeeded -eq 'Yes') {
                Write-Host ""
                msg_alert "La instalacion requiere un REINICIO del servidor."
                msg_alert "Despues de reiniciar, vuelve a ejecutar ac_manager.ps1"
                $reboot = Read-Confirm -Prompt "Reiniciar ahora" -Default 'S'
                if ($reboot) {
                    Write-Log INFO "Reiniciando servidor por solicitud post-instalacion..."
                    Restart-Computer -Force
                    exit 0
                } else {
                    Write-Log WARN "Reinicio pospuesto. Algunos modulos pueden no funcionar hasta reiniciar."
                }
            }

        } catch {
            Write-Log ERROR "Error al instalar caracteristicas criticas: $_"
            return $false
        }
    }

    # ── Opcionales ────────────────────────────────────────────────────────────
    if ($optionalMissing.Count -gt 0) {
        Write-Host ""
        msg_info "Caracteristicas opcionales faltantes:"
        $optionalMissing | ForEach-Object { msg_info "  - $($_.Value.Label)" }
        Write-Host ""

        $installOpt = Read-Confirm `
            -Prompt "Instalar caracteristicas opcionales (recomendado)" `
            -Default 'S'

        if ($installOpt) {
            $names = $optionalMissing | ForEach-Object { $_.Key }
            msg_process "Instalando caracteristicas opcionales..."

            try {
                Invoke-Logged "Instalar roles opcionales: $($names -join ', ')" {
                    Install-WindowsFeature `
                        -Name               $names `
                        -IncludeManagementTools `
                        -ErrorAction        Stop
                } | Out-Null
                Write-Log SUCCESS "Caracteristicas opcionales instaladas."
            } catch {
                Write-Log WARN "No se pudieron instalar algunas caracteristicas opcionales: $_"
            }
        }
    }

    return $true
}

# =============================================================================
# VALIDACIONES DE PREREQUISITOS
# Se ejecutan antes de la promocion del DC para garantizar que el entorno
# es compatible. Basadas en validatorsAD.ps1 del amigo.
# =============================================================================

# -----------------------------------------------------------------------------
# Test-OSCompatibility — Windows Server 2016+ (Build >= 14393)
# -----------------------------------------------------------------------------
function Test-OSCompatibility {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $build = [int]$os.BuildNumber
        if ($build -lt 14393) {
            Write-Log ERROR "SO no compatible: $($os.Caption) (Build $build). Se requiere Server 2016+."
            return $false
        }
        Write-Log INFO "SO compatible: $($os.Caption) (Build $build)"
        return $true
    } catch {
        Write-Log WARN "No se pudo verificar la version del SO: $_"
        return $true  # No bloquear si no se puede verificar
    }
}

# -----------------------------------------------------------------------------
# Test-ExecutionPolicyOK — RemoteSigned, Unrestricted o Bypass
# -----------------------------------------------------------------------------
function Test-ExecutionPolicyOK {
    $policy  = Get-ExecutionPolicy -Scope Process
    $blocked = @('Restricted','AllSigned')
    if ($blocked -contains $policy) {
        Write-Log ERROR "Politica de ejecucion bloqueante: $policy"
        msg_error "Ejecuta PowerShell con: -ExecutionPolicy Bypass"
        return $false
    }
    Write-Log INFO "Politica de ejecucion: $policy (OK)"
    return $true
}

# -----------------------------------------------------------------------------
# Test-StaticIPAssigned — IP estatica detectada en adaptador interno
# -----------------------------------------------------------------------------
function Test-StaticIPAssigned {
    $adapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object {
                   $_.IPAddress -notlike '127.*' -and
                   $_.IPAddress -notlike '169.254.*'
               } | Select-Object -First 1

    if ($null -eq $adapter) {
        Write-Log ERROR "No se encontro adaptador de red con IP valida."
        return $false
    }
    if ($adapter.PrefixOrigin -ne 'Manual') {
        Write-Log WARN "La IP $($adapter.IPAddress) es dinamica (origen: $($adapter.PrefixOrigin))."
        Write-Log WARN "Se recomienda IP estatica en el DC para evitar cambios de direccion."
        msg_alert "La IP del servidor no es estatica. AD puede fallar si la IP cambia."
        return $true  # Advertencia, no bloqueo
    }
    Write-Log INFO "IP estatica verificada: $($adapter.IPAddress)"
    return $true
}

# -----------------------------------------------------------------------------
# Test-DNSSelfPointingWithFix
# Verifica que el DNS del adaptador apunte al propio servidor.
# Si no apunta, lo corrige automaticamente — es la causa #1 de fallos en AD DS.
# -----------------------------------------------------------------------------
function Test-DNSSelfPointingWithFix {
    $adapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object {
                   $_.IPAddress -notlike '127.*' -and
                   $_.IPAddress -notlike '169.254.*'
               } | Select-Object -First 1

    if ($null -eq $adapter) {
        Write-Log WARN "No se pudo verificar DNS self-pointing: sin adaptador detectado."
        return $true
    }

    $serverIP  = $adapter.IPAddress
    $ifIndex   = $adapter.InterfaceIndex
    $dnsConfig = Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 `
                 -ErrorAction SilentlyContinue

    $dnsServers = $dnsConfig.ServerAddresses

    if ($null -eq $dnsServers -or $dnsServers.Count -eq 0 -or
        ($dnsServers[0] -ne $serverIP -and $dnsServers[0] -ne '127.0.0.1')) {

        Write-Log WARN "DNS no apunta al propio servidor. Autocorrigiendo a $serverIP..."
        try {
            Set-DnsClientServerAddress -InterfaceIndex $ifIndex `
                -ServerAddresses $serverIP -ErrorAction Stop
            Write-Log SUCCESS "DNS del adaptador configurado automaticamente a: $serverIP"
            msg_success "DNS autocorregido a $serverIP (requerido para AD DS)."
        } catch {
            Write-Log ERROR "No se pudo autocorregir el DNS: $_"
            msg_error "Configura manualmente el DNS del adaptador a $serverIP antes de continuar."
            return $false
        }
    } else {
        Write-Log INFO "DNS self-pointing verificado: $($dnsServers[0])"
    }
    return $true
}

# -----------------------------------------------------------------------------
# Test-DomainNameFormat
# Valida el formato del nombre de dominio. Restricciones:
#   - Prefijo max 15 chars (limite NetBIOS)
#   - Solo letras, numeros y guiones; no empieza/termina con guion
#   - Sufijo debe ser .local, .lan o .internal (no TLDs reales)
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Test-DomainNameFormat {
    param([Parameter(Mandatory)] [string] $DomainName)

    if ([string]::IsNullOrWhiteSpace($DomainName)) {
        Write-Log ERROR "El nombre de dominio no puede estar vacio."
        return $false
    }

    $parts = $DomainName.Split('.')
    if ($parts.Count -ne 2) {
        Write-Log ERROR "Formato invalido '$DomainName' — debe tener exactamente un punto (ej: practica.local)"
        return $false
    }

    $prefix = $parts[0]; $suffix = $parts[1]

    if ($prefix.Length -gt 15) {
        Write-Log ERROR "Prefijo '$prefix' tiene $($prefix.Length) chars (max 15 — limite NetBIOS)"
        return $false
    }

    if ($prefix -notmatch '^[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9]$' -and
        $prefix -notmatch '^[a-zA-Z0-9]$') {
        Write-Log ERROR "Prefijo '$prefix' contiene caracteres no permitidos."
        return $false
    }

    $allowedSuffixes = @('local','lan','internal')
    if ($allowedSuffixes -notcontains $suffix.ToLower()) {
        Write-Log ERROR "Sufijo '.$suffix' no permitido. Usa: .local, .lan o .internal"
        msg_error "Sufijo '.$suffix' no valido. Los TLDs reales (.com, .net) causan conflictos DNS."
        return $false
    }

    Write-Log INFO "Nombre de dominio valido: $DomainName (NetBIOS: $($prefix.ToUpper()))"
    return $true
}

# -----------------------------------------------------------------------------
# Invoke-AllValidations
# Ejecuta todas las validaciones de prerequisitos en orden.
# Las criticas detienen la ejecucion; las informativas solo advierten.
# Devuelve: $true si el entorno esta listo | $false si hay bloqueantes
# -----------------------------------------------------------------------------
function Invoke-AllValidations {
    Write-LogSection "Validacion de Prerequisitos"

    $results = [ordered]@{}

    msg_process "Verificando compatibilidad del sistema operativo..."
    $results['OS'] = Test-OSCompatibility

    msg_process "Verificando politica de ejecucion de PowerShell..."
    $results['Policy'] = Test-ExecutionPolicyOK

    msg_process "Verificando IP estatica del servidor..."
    $results['IP'] = Test-StaticIPAssigned

    msg_process "Verificando que DNS apunte al propio servidor..."
    $results['DNS'] = Test-DNSSelfPointingWithFix

    Write-Host ""
    # Solo OS y Policy son criticos de verdad — IP y DNS se autocorrigen
    $criticalFailed = (-not $results['OS']) -or (-not $results['Policy'])

    foreach ($k in $results.Keys) {
        $icon  = if ($results[$k]) { "[ OK ]" } else { "[FAIL]" }
        $color = if ($results[$k]) { 'Green' } else { 'Red' }
        Write-Host "    " -NoNewline
        Write-Host $icon -ForegroundColor $color -NoNewline
        Write-Host " $k"
    }

    Write-Host ""

    if ($criticalFailed) {
        Write-Log ERROR "Validaciones criticas fallidas. Corrige los errores antes de continuar."
        return $false
    }

    Write-Log SUCCESS "Todas las validaciones pasaron. Entorno listo para la instalacion."
    return $true
}

# -----------------------------------------------------------------------------
# Invoke-DCPromotion
# Flujo interactivo completo para instalar AD DS y promover el servidor
# como Domain Controller (nuevo bosque).
#
# Solicita todos los parametros necesarios sin asumir valores predeterminados.
# Devuelve: $true si la promocion se inicio | $false si se cancelo
# -----------------------------------------------------------------------------
function Invoke-DCPromotion {
    Write-LogSection "Promocion del Servidor como Domain Controller"

    msg_info "Este servidor no es un Domain Controller."
    msg_info "AC Manager requiere que el servidor sea DC para funcionar."
    msg_info "Se procedera a instalar AD DS y promover este servidor."
    Write-Host ""

    # Correr validaciones completas antes de ofrecer la promocion
    $validOK = Invoke-AllValidations
    if (-not $validOK) {
        msg_error "El entorno no cumple los prerequisitos. Corrige los errores y vuelve a ejecutar."
        return $false
    }

    $promote = Read-Confirm `
        -Prompt "Promover este servidor como Domain Controller ahora" `
        -Default 'S'

    if (-not $promote) {
        Write-Log WARN "Promocion de DC cancelada por el usuario."
        msg_alert "Sin un DC activo, AC Manager no puede funcionar."
        return $false
    }

    # ── Tipo de deployment ────────────────────────────────────────────────────
    Write-Host ""
    $deployType = Read-Selection `
        -Prompt "Tipo de deployment" `
        -Options @(
            "Nuevo bosque (Forest) — Primera instalacion, dominio completamente nuevo",
            "Nuevo dominio en bosque existente",
            "DC adicional en dominio existente"
        )
    if ($deployType -eq $false) { return $false }

    # ── FQDN del dominio — validado con Test-DomainNameFormat ────────────────
    $domainFQDN = Read-InputLoop `
        -Prompt    "FQDN del dominio (ej: practica.local)" `
        -Validator { param($v)
            ($v -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$') -and
            (Test-DomainNameFormat -DomainName $v)
        } `
        -ErrorMsg  "Formato invalido o sufijo no permitido. Usa: nombre.local | nombre.lan | nombre.internal"
    if ($domainFQDN -eq $false) { return $false }

    # ── NetBIOS ───────────────────────────────────────────────────────────────
    $suggestedNetBIOS = $domainFQDN.Split('.')[0].ToUpper()
    $netBIOSName = Read-InputLoop `
        -Prompt    "Nombre NetBIOS del dominio (Enter para '$suggestedNetBIOS')" `
        -Validator { param($v) $v -match '^[A-Z0-9]{1,15}$' } `
        -ErrorMsg  "Max 15 caracteres alfanumericos en mayusculas." `
        -AllowEmpty $true
    if ($null -eq $netBIOSName -or $netBIOSName -eq $false) { $netBIOSName = $suggestedNetBIOS }

    # ── Nivel funcional ───────────────────────────────────────────────────────
    $levelSel = Read-Selection `
        -Prompt "Nivel funcional del dominio" `
        -Options @(
            "WinThreshold (Windows Server 2016) — RECOMENDADO para FGPP y caracteristicas modernas",
            "Win2012R2 (Windows Server 2012 R2)",
            "Win2012  (Windows Server 2012)",
            "Win2008R2 (Windows Server 2008 R2)"
        )
    if ($levelSel -eq $false) { $levelSel = [PSCustomObject]@{ Index = 0 } }

    $domainLevel = switch ($levelSel.Index) {
        0 { 'WinThreshold' }
        1 { 'Win2012R2'    }
        2 { 'Win2012'      }
        3 { 'Win2008R2'    }
        default { 'WinThreshold' }
    }

    # ── Rutas de base de datos AD ─────────────────────────────────────────────
    Write-Host ""
    msg_info "Rutas de almacenamiento de Active Directory"
    msg_info "Se pueden dejar en los valores por defecto (Enter) o personalizar."

    $dbPath = Read-InputLoop `
        -Prompt    "Ruta de la base de datos NTDS (Enter para C:\Windows\NTDS)" `
        -Validator { $true } `
        -AllowEmpty $true
    if ($null -eq $dbPath -or $dbPath -eq $false) { $dbPath = 'C:\Windows\NTDS' }

    $logPath = Read-InputLoop `
        -Prompt    "Ruta de los logs de AD (Enter para C:\Windows\NTDS)" `
        -Validator { $true } `
        -AllowEmpty $true
    if ($null -eq $logPath -or $logPath -eq $false) { $logPath = 'C:\Windows\NTDS' }

    $sysvolPath = Read-InputLoop `
        -Prompt    "Ruta de SYSVOL (Enter para C:\Windows\SYSVOL)" `
        -Validator { $true } `
        -AllowEmpty $true
    if ($null -eq $sysvolPath -or $sysvolPath -eq $false) { $sysvolPath = 'C:\Windows\SYSVOL' }

    # ── Contrasena DSRM ───────────────────────────────────────────────────────
    Write-Host ""
    msg_info "Contrasena del Modo de Restauracion de Directorio (DSRM)"
    msg_info "Esta contrasena se usa para recuperacion de AD en modo seguro."
    msg_alert "GUARDA ESTA CONTRASENA EN UN LUGAR SEGURO — no se puede recuperar."

    $dsrmPassword = Read-SecureInput `
        -Prompt    "Contrasena DSRM" `
        -Confirm   $true `
        -MinLength 8 `
        -Validator { param($v)
            ($v -match '[A-Z]') -and
            ($v -match '[a-z]') -and
            ($v -match '[0-9]') -and
            ($v -match '[^a-zA-Z0-9]')
        } `
        -ErrorMsg  "La contrasena DSRM debe tener mayusculas, minusculas, numeros y simbolos."
    if ($dsrmPassword -eq $false) { return $false }

    # ── Papelera de reciclaje AD ──────────────────────────────────────────────
    $enableRecycleBin = Read-Confirm `
        -Prompt "Habilitar la Papelera de reciclaje de AD (recomendado)" `
        -Default 'S'

    # ── Instalar DNS en este servidor ─────────────────────────────────────────
    $installDNS = Read-Confirm `
        -Prompt "Instalar servidor DNS en este equipo (recomendado para DC)" `
        -Default 'S'

    # ── Resumen ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-LogSection "Resumen de Configuracion del DC"
    msg_info "FQDN del dominio     : $domainFQDN"
    msg_info "NetBIOS              : $netBIOSName"
    msg_info "Nivel funcional      : $domainLevel"
    msg_info "Base de datos NTDS   : $dbPath"
    msg_info "Logs de AD           : $logPath"
    msg_info "SYSVOL               : $sysvolPath"
    msg_info "Instalar DNS         : $installDNS"
    msg_info "Papelera de reciclaje: $enableRecycleBin"
    Write-Host ""
    msg_alert "El servidor se REINICIARA al completar la promocion."
    Write-Host ""

    $confirm = Read-Confirm `
        -Prompt "Confirmar y ejecutar la promocion del Domain Controller" `
        -Default 'S'
    if (-not $confirm) {
        Write-Log INFO "Promocion cancelada por el usuario en la confirmacion final."
        return $false
    }

    # ── Verificar que AD-Domain-Services este instalado ───────────────────────
    if (-not (Test-FeatureInstalled 'AD-Domain-Services')) {
        msg_process "Instalando rol AD Domain Services..."
        try {
            Invoke-Logged "Instalar AD-Domain-Services" {
                Install-WindowsFeature -Name AD-Domain-Services `
                    -IncludeManagementTools -ErrorAction Stop
            } | Out-Null
        } catch {
            Write-Log ERROR "No se pudo instalar AD-Domain-Services: $_"
            return $false
        }
    }

    # ── Ejecutar promocion ────────────────────────────────────────────────────
    msg_process "Iniciando promocion del Domain Controller..."
    msg_alert   "El servidor se reiniciara automaticamente al finalizar."

    $promoParams = @{
        DomainName                    = $domainFQDN
        DomainNetbiosName             = $netBIOSName
        DomainMode                    = $domainLevel
        ForestMode                    = $domainLevel
        DatabasePath                  = $dbPath
        LogPath                       = $logPath
        SysvolPath                    = $sysvolPath
        SafeModeAdministratorPassword = $dsrmPassword
        InstallDns                    = $installDNS
        Force                         = $true
        NoRebootOnCompletion          = $true   # Nosotros controlamos el reinicio
        ErrorAction                   = 'Stop'
    }

    try {
        Write-Log INFO "Ejecutando Install-ADDSForest para dominio: $domainFQDN"

        switch ($deployType.Index) {
            0 {
                # Nuevo bosque
                Invoke-Logged "Promover DC: nuevo bosque $domainFQDN" {
                    Install-ADDSForest @promoParams
                } | Out-Null
            }
            1 {
                # Nuevo dominio en bosque existente
                $parentDomain = Read-InputLoop `
                    -Prompt    "FQDN del dominio padre" `
                    -Validator { param($v) $v -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$' } `
                    -ErrorMsg  "Formato invalido."
                $domainLabel = Read-InputLoop `
                    -Prompt    "Etiqueta del nuevo dominio hijo (ej: 'sucursal' para sucursal.empresa.com)" `
                    -Validator { param($v) $v -match '^[a-zA-Z0-9\-]{1,63}$' } `
                    -ErrorMsg  "Solo letras, numeros y guiones."
                $cred = Get-Credential -Message "Credenciales de administrador del dominio padre"

                Invoke-Logged "Promover DC: nuevo dominio hijo" {
                    Install-ADDSDomain `
                        -ParentDomainName             $parentDomain `
                        -NewDomainName                $domainLabel `
                        -NewDomainNetbiosName          $netBIOSName `
                        -DomainMode                   $domainLevel `
                        -DatabasePath                 $dbPath `
                        -LogPath                      $logPath `
                        -SysvolPath                   $sysvolPath `
                        -SafeModeAdministratorPassword $dsrmPassword `
                        -Credential                   $cred `
                        -InstallDns:$installDNS `
                        -Force `
                        -ErrorAction Stop
                } | Out-Null
            }
            2 {
                # DC adicional en dominio existente
                $cred = Get-Credential -Message "Credenciales de administrador del dominio"

                Invoke-Logged "Promover DC adicional en: $domainFQDN" {
                    Install-ADDSDomainController `
                        -DomainName                   $domainFQDN `
                        -DatabasePath                 $dbPath `
                        -LogPath                      $logPath `
                        -SysvolPath                   $sysvolPath `
                        -SafeModeAdministratorPassword $dsrmPassword `
                        -Credential                   $cred `
                        -InstallDns:$installDNS `
                        -Force `
                        -ErrorAction Stop
                } | Out-Null
            }
        }

        Write-Log SUCCESS "Promocion del DC completada. Configurando post-promocion..."

        # ── Reglas de firewall para Active Directory ──────────────────────────
        # Sin estas reglas los clientes no pueden autenticarse en el dominio.
        # TCP: DNS(53), Kerberos(88), RPC(135), LDAP(389), SMB(445),
        #      LDAPS(636), GlobalCatalog(3268), GlobalCatalogSSL(3269)
        # UDP: DNS(53), Kerberos(88), LDAP(389)
        Write-Log INFO "Configurando reglas de firewall para AD..."
        $tcpPorts = @{ 53='AD-DNS-TCP'; 88='AD-Kerberos-TCP'; 135='AD-RPC-TCP';
                       389='AD-LDAP-TCP'; 445='AD-SMB-TCP'; 636='AD-LDAPS-TCP';
                       3268='AD-GlobalCatalog-TCP'; 3269='AD-GlobalCatalogSSL-TCP' }
        $udpPorts = @{ 53='AD-DNS-UDP'; 88='AD-Kerberos-UDP'; 389='AD-LDAP-UDP' }

        foreach ($port in $tcpPorts.Keys) {
            $ruleName = $tcpPorts[$port]
            if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
                try {
                    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound `
                        -Protocol TCP -LocalPort $port -Action Allow -Profile Any `
                        -ErrorAction Stop | Out-Null
                    Write-Log INFO "Regla firewall TCP $port creada: $ruleName"
                } catch {
                    Write-Log WARN "No se pudo crear regla TCP $port : $_"
                }
            }
        }
        foreach ($port in $udpPorts.Keys) {
            $ruleName = $udpPorts[$port]
            if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
                try {
                    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound `
                        -Protocol UDP -LocalPort $port -Action Allow -Profile Any `
                        -ErrorAction Stop | Out-Null
                    Write-Log INFO "Regla firewall UDP $port creada: $ruleName"
                } catch {
                    Write-Log WARN "No se pudo crear regla UDP $port : $_"
                }
            }
        }
        Write-Log SUCCESS "Reglas de firewall AD configuradas."

        # ── Papelera de reciclaje (script para post-reinicio) ─────────────────
        if ($enableRecycleBin) {
            $recycleBinScript = @"
Import-Module ActiveDirectory
Enable-ADOptionalFeature ``
    -Identity 'Recycle Bin Feature' ``
    -Scope ForestOrConfigurationSet ``
    -Target '$domainFQDN' ``
    -Confirm:`$false
Write-Host 'Papelera de reciclaje de AD habilitada.'
"@
            $recycleBinPath = "$env:SystemDrive\ac_enable_recyclebin.ps1"
            Set-Content -Path $recycleBinPath -Value $recycleBinScript -Encoding UTF8
            Write-Log INFO "Script papelera de reciclaje guardado: $recycleBinPath"
        }

        # ── Tarea programada para continuar automaticamente post-reinicio ─────
        # Sin esto, el administrador debe re-ejecutar ac_manager.ps1 manualmente
        # despues del reinicio. La tarea se elimina sola al completar el setup.
        $scriptPath = $MyInvocation.ScriptName
        if ([string]::IsNullOrWhiteSpace($scriptPath)) {
            $scriptPath = Join-Path $PSScriptRoot "..\ac_manager.ps1"
        }
        $scriptPath = [System.IO.Path]::GetFullPath($scriptPath)

        try {
            $taskAction   = New-ScheduledTaskAction `
                -Execute   "PowerShell.exe" `
                -Argument  "-ExecutionPolicy Bypass -NonInteractive -File `"$scriptPath`""
            $taskTrigger  = New-ScheduledTaskTrigger -AtLogOn
            $taskSettings = New-ScheduledTaskSettingsSet `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 60) `
                -RestartCount 0
            Register-ScheduledTask `
                -TaskName  "ACManager-PostDCPromo" `
                -Action    $taskAction `
                -Trigger   $taskTrigger `
                -RunLevel  Highest `
                -User      "SYSTEM" `
                -Settings  $taskSettings `
                -Force | Out-Null
            Write-Log SUCCESS "Tarea programada 'ACManager-PostDCPromo' registrada."
            msg_success "AC Manager continuara automaticamente despues del reinicio."
        } catch {
            Write-Log WARN "No se pudo crear la tarea programada: $_"
            msg_alert "Despues del reinicio ejecuta ac_manager.ps1 manualmente."
        }

        # ── Reinicio controlado ───────────────────────────────────────────────
        msg_alert "El servidor se reiniciara en 15 segundos."
        msg_info  "Despues del reinicio, inicia sesion y AC Manager continuara automaticamente."
        Write-Log INFO "Reinicio programado post-promocion DC."
        Start-Sleep -Seconds 15
        Restart-Computer -Force
        return $true

    } catch {
        Write-Log ERROR "Error durante la promocion del DC: $_"
        msg_error "La promocion fallo. Revisa el log para mas detalles."
        msg_info  "Causa comun: el servidor ya tiene un DC en la red con el mismo nombre de dominio."
        return $false
    }
}

# -----------------------------------------------------------------------------
# Invoke-Setup
# Punto de entrada principal del modulo.
# Evalua el estado del entorno y ejecuta los pasos necesarios en orden:
#   1. Instalar roles/features faltantes
#   2. Promover el DC si no lo es
#   3. Verificar que todo quedo correcto
#
# Devuelve: $true si el entorno esta listo para usar ac_manager | $false
# -----------------------------------------------------------------------------
function Invoke-Setup {
    Write-LogSection "Verificacion y Configuracion del Entorno"

    # ── Evaluar estado actual ─────────────────────────────────────────────────
    msg_process "Auditando el entorno..."
    $status = Get-SetupStatus
    Show-SetupStatus -Status $status

    # Entorno ya listo — camino rapido
    if ($status.AllCriticalOK) {
        Write-Log SUCCESS "El entorno ya cumple todos los requisitos criticos."
        return $true
    }

    # Reboot pendiente
    if ($status.NeedsReboot) {
        msg_alert "Hay un reinicio pendiente. Algunos cambios no tendran efecto hasta reiniciar."
        $reboot = Read-Confirm -Prompt "Reiniciar ahora para continuar" -Default 'S'
        if ($reboot) {
            Write-Log INFO "Reiniciando por reboot pendiente..."
            Restart-Computer -Force
            exit 0
        }
    }

    # ── Paso 1: Instalar roles/features ──────────────────────────────────────
    $featuresOK = Install-RequiredFeatures -Status $status
    if (-not $featuresOK) {
        Write-Log ERROR "No se pudieron instalar las caracteristicas criticas."
        return $false
    }

    # Recargar estado despues de instalar
    $status = Get-SetupStatus

    # ── Paso 2: Promover DC si no lo es ──────────────────────────────────────
    if (-not $status.IsDC) {
        $promoted = Invoke-DCPromotion
        if (-not $promoted) {
            Write-Log ERROR "El servidor no fue promovido como DC."
            return $false
        }
        # Si llego aqui sin reiniciar, el proceso de promocion maneja el reinicio
        return $true
    }

    # ── Paso 3: Verificar AD DS corriendo ────────────────────────────────────
    if (-not $status.ADDSRunning) {
        Write-Log WARN "AD DS instalado pero servicio NTDS no esta corriendo."
        msg_process "Intentando iniciar el servicio NTDS..."
        try {
            Start-Service -Name NTDS -ErrorAction Stop
            Start-Sleep -Seconds 5
            if (Test-ADDSRunning) {
                Write-Log SUCCESS "Servicio NTDS iniciado correctamente."
            } else {
                Write-Log ERROR "El servicio NTDS no inicio. Verifica los logs del sistema."
                return $false
            }
        } catch {
            Write-Log ERROR "No se pudo iniciar NTDS: $_"
            return $false
        }
    }

    # ── Paso 3b: Esperar que ADWS este completamente listo ────────────────────
    # Despues de un reinicio post-promocion, ADWS puede tardar hasta 60 seg
    # en aceptar consultas. Sin esta espera, Get-ADDomain falla y los modulos
    # de AC Manager no pueden conectarse al dominio.
    msg_process "Esperando que los servicios de AD esten completamente listos..."
    $maxWait = 120
    $waited  = 0
    $adReady = $false
    while ($waited -lt $maxWait) {
        try {
            Get-ADDomain -ErrorAction Stop | Out-Null
            $adReady = $true
            break
        } catch {
            Write-Log INFO "AD aun no responde, esperando 5s... ($waited/$maxWait s)"
            Start-Sleep -Seconds 5
            $waited += 5
        }
    }
    if (-not $adReady) {
        Write-Log ERROR "Active Directory no respondio en $maxWait segundos."
        msg_error "Verifica que la promocion del DC se haya completado correctamente."
        return $false
    }
    Write-Log SUCCESS "Servicios de Active Directory listos."

    # ── Eliminar tarea programada post-reinicio si existe ─────────────────────
    $existingTask = Get-ScheduledTask -TaskName "ACManager-PostDCPromo" -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName "ACManager-PostDCPromo" -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log INFO "Tarea programada 'ACManager-PostDCPromo' eliminada."
    }


    # ── Paso 4: Importar modulos AD ahora que estan instalados ───────────────
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Import-Module GroupPolicy     -ErrorAction Stop
        Write-Log SUCCESS "Modulos ActiveDirectory y GroupPolicy cargados."
    } catch {
        Write-Log ERROR "No se pudieron importar los modulos de AD: $_"
        return $false
    }

    # ── Verificacion final ────────────────────────────────────────────────────
    $finalStatus = Get-SetupStatus
    if ($finalStatus.AllCriticalOK) {
        Write-Log SUCCESS "Entorno configurado y listo."
        return $true
    } else {
        Write-Log ERROR "Algunos prerequisitos criticos siguen fallando tras la configuracion."
        Show-SetupStatus -Status $finalStatus
        return $false
    }
}