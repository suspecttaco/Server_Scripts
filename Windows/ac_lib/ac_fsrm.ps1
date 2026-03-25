# =============================================================================
# ac_lib/ac_fsrm.ps1 — Gestion de FSRM: cuotas, file screening, carpetas home
# Uso: . .\ac_lib\ac_fsrm.ps1
# Requiere: lib/ui.ps1, lib/input.ps1, ac_lib/ac_log.ps1, ac_lib/ac_ad.ps1
# =============================================================================

#Requires -Module ActiveDirectory

# Importar modulo FSRM si esta disponible
if (Get-Module -ListAvailable -Name FileServerResourceManager) {
    Import-Module FileServerResourceManager -ErrorAction Stop
} else {
    throw "El modulo FileServerResourceManager no esta disponible. Verifica que el rol FS-Resource-Manager este instalado."
}

# -----------------------------------------------------------------------------
# CONSTANTES DE MODULO
# -----------------------------------------------------------------------------
$script:FSRM_SERVICE       = 'SrmSvc'           # Nombre del servicio FSRM
$script:FSRM_FEATURE       = 'FS-Resource-Manager'
$script:FSRM_REPORT_PATH   = $null              # Ruta de reportes, se solicita al usuario
$script:FSRM_HOMES_ROOT    = $null              # Ruta raiz de carpetas home

# Extensiones bloqueadas por defecto (el usuario puede modificar esta lista)
$script:FSRM_DEFAULT_BLOCKED = @('.mp3','.mp4','.avi','.mkv','.mov','.wmv',
                                  '.flv','.wav','.aac','.ogg','.wma',
                                  '.exe','.msi','.bat','.cmd','.vbs','.ps1',
                                  '.dll','.scr','.com','.pif')

# -----------------------------------------------------------------------------
# Test-FSRMInstalled
# Verifica si el rol FSRM esta instalado y el servicio esta corriendo.
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Test-FSRMInstalled {
    $feature = Get-WindowsFeature -Name $script:FSRM_FEATURE -ErrorAction SilentlyContinue
    if ($null -eq $feature -or $feature.InstallState -ne 'Installed') {
        return $false
    }
    return $true
}

# -----------------------------------------------------------------------------
# Install-FSRMRole
# Instala el rol File Server Resource Manager si no esta presente.
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Install-FSRMRole {
    Write-LogSection "Instalacion del Rol FSRM"

    if (Test-FSRMInstalled) {
        Write-Log INFO "El rol FSRM ya esta instalado."
        return $true
    }

    Write-Log WARN "El rol FSRM no esta instalado."
    $install = Read-Confirm `
        -Prompt "Instalar el rol File Server Resource Manager ahora" `
        -Default 'S'
    if (-not $install) {
        Write-Log WARN "Instalacion de FSRM cancelada. El modulo no puede continuar."
        return $false
    }

    msg_process "Instalando FSRM (puede tardar varios minutos)..."

    try {
        Invoke-Logged "Instalar rol FS-Resource-Manager" {
            Install-WindowsFeature -Name $script:FSRM_FEATURE `
                -IncludeManagementTools `
                -ErrorAction Stop
        } | Out-Null
    } catch {
        Write-Log ERROR "No se pudo instalar el rol FSRM: $_"
        return $false
    }

    # Verificar instalacion
    if (-not (Test-FSRMInstalled)) {
        Write-Log ERROR "La instalacion de FSRM no se completo correctamente."
        return $false
    }

    # Iniciar y habilitar el servicio
    try {
        Invoke-Logged "Iniciar servicio SrmSvc" {
            Start-Service  -Name $script:FSRM_SERVICE -ErrorAction Stop
            Set-Service    -Name $script:FSRM_SERVICE -StartupType Automatic -ErrorAction Stop
        } | Out-Null
        Write-Log SUCCESS "Servicio FSRM iniciado y configurado como automatico."
    } catch {
        Write-Log WARN "No se pudo configurar el servicio FSRM: $_"
    }

    Write-Log SUCCESS "Rol FSRM instalado correctamente."
    return $true
}

# -----------------------------------------------------------------------------
# Initialize-FSRMPaths
# Solicita al usuario las rutas raiz: carpetas home y directorio de reportes.
# Crea los directorios si no existen.
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Initialize-FSRMPaths {
    Write-LogSection "Rutas de FSRM"

    # ── Ruta raiz de carpetas home ────────────────────────────────────────────
    $homesRoot = Read-FilePath `
        -Prompt "Ruta raiz para las carpetas home de usuarios (ej: C:\Homes)" `
        -MustExist $false `
        -Type 'Any'
    if ($homesRoot -eq $false) { return $false }

    if (-not (Test-Path $homesRoot)) {
        $create = Read-Confirm `
            -Prompt "La ruta '$homesRoot' no existe. Crearla ahora" `
            -Default 'S'
        if (-not $create) { return $false }
        try {
            New-Item -ItemType Directory -Path $homesRoot -Force -ErrorAction Stop | Out-Null
            Write-Log SUCCESS "Directorio creado: $homesRoot"
        } catch {
            Write-Log ERROR "No se pudo crear '$homesRoot': $_"
            return $false
        }
    }

    $script:FSRM_HOMES_ROOT = $homesRoot

    # ── Ruta de reportes ──────────────────────────────────────────────────────
    $reportsPath = Read-FilePath `
        -Prompt "Ruta para reportes de FSRM (ej: C:\FSRMReports)" `
        -MustExist $false `
        -Type 'Any'
    if ($reportsPath -eq $false) { return $false }

    if (-not (Test-Path $reportsPath)) {
        try {
            New-Item -ItemType Directory -Path $reportsPath -Force -ErrorAction Stop | Out-Null
            Write-Log SUCCESS "Directorio de reportes creado: $reportsPath"
        } catch {
            Write-Log ERROR "No se pudo crear '$reportsPath': $_"
            return $false
        }
    }

    $script:FSRM_REPORT_PATH = $reportsPath

    # Configurar ruta de reportes en FSRM
    try {
        Invoke-Logged "Configurar ruta de reportes en FSRM" {
            Set-FsrmSetting -ReportLocationOnDemand $reportsPath -ErrorAction Stop
        } | Out-Null
        Write-Log SUCCESS "Ruta de reportes FSRM configurada: $reportsPath"
    } catch {
        Write-Log WARN "No se pudo configurar la ruta de reportes en FSRM: $_"
    }

    # ── Configuracion SMTP (opcional) ─────────────────────────────────────────
    $configureSMTP = Read-Confirm `
        -Prompt "Configurar notificaciones por correo electronico (SMTP)" `
        -Default 'N'

    if ($configureSMTP) {
        $smtpServer = Read-InputLoop `
            -Prompt "Servidor SMTP (ej: smtp.dominio.local)" `
            -Validator { param($v) $v.Length -ge 4 } `
            -ErrorMsg "Ingresa un nombre de servidor valido."
        if ($smtpServer -ne $false) {

            $smtpFrom = Read-InputLoop `
                -Prompt "Correo de origen (ej: fsrm@dominio.local)" `
                -Validator { param($v) $v -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' } `
                -ErrorMsg "Formato de email invalido."

            $smtpAdmin = Read-InputLoop `
                -Prompt "Correo del administrador (destinatario de alertas)" `
                -Validator { param($v) $v -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' } `
                -ErrorMsg "Formato de email invalido."

            if ($smtpFrom -ne $false -and $smtpAdmin -ne $false) {
                try {
                    Invoke-Logged "Configurar SMTP en FSRM" {
                        Set-FsrmSetting `
                            -SmtpServer       $smtpServer `
                            -FromEmailAddress $smtpFrom `
                            -AdminEmailAddress $smtpAdmin `
                            -ErrorAction Stop
                    } | Out-Null
                    Write-Log SUCCESS "SMTP configurado: $smtpServer"
                } catch {
                    Write-Log WARN "No se pudo configurar SMTP en FSRM: $_"
                }
            }
        }
    }

    Write-Log SUCCESS "Rutas de FSRM configuradas correctamente."
    return $true
}

# -----------------------------------------------------------------------------
# New-UserHomeFolder
# Crea la carpeta home de un usuario, establece permisos NTFS y
# la comparte opcionalmente en red.
#
# Parametros:
#   -SamAccountName  SAM del usuario
#   -HomesRoot       Ruta raiz (default: $script:FSRM_HOMES_ROOT)
#   -ShareFolder     Si $true, crea un share SMB para la carpeta
#
# Devuelve: ruta completa de la carpeta | $false
# -----------------------------------------------------------------------------
function New-UserHomeFolder {
    param(
        [Parameter(Mandatory)] [string] $SamAccountName,
        [string] $HomesRoot   = $script:FSRM_HOMES_ROOT,
        [bool]   $ShareFolder = $false
    )

    if ([string]::IsNullOrWhiteSpace($HomesRoot)) {
        Write-Log ERROR "La ruta raiz de homes no esta configurada."
        return $false
    }

    $folderPath = Join-Path $HomesRoot $SamAccountName

    # Crear carpeta
    if (-not (Test-Path $folderPath)) {
        try {
            New-Item -ItemType Directory -Path $folderPath -Force -ErrorAction Stop | Out-Null
            Write-Log INFO "Carpeta home creada: $folderPath"
        } catch {
            Write-Log ERROR "No se pudo crear la carpeta home '$folderPath': $_"
            return $false
        }
    } else {
        Write-Log INFO "La carpeta home ya existe: $folderPath"
    }

    # Configurar permisos NTFS: usuario tiene control total, herencia deshabilitada
    try {
        Invoke-Logged "Configurar permisos NTFS: $folderPath" {
            $acl   = Get-Acl -Path $folderPath -ErrorAction Stop
            $acl.SetAccessRuleProtection($true, $false)  # Deshabilitar herencia

            # Regla para SYSTEM
            $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "SYSTEM", "FullControl", "ContainerInherit,ObjectInherit",
                "None", "Allow"
            )
            $acl.AddAccessRule($systemRule)

            # Regla para Administrators via SID universal S-1-5-32-544.
            # NO usar el string "Administrators" — en DCs en español el grupo
            # se llama "Administradores" y el nombre en ingles causa
            # IdentityNotMappedException al crear la regla ACL.
            $adminSid  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
            $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $adminSid, "FullControl", "ContainerInherit,ObjectInherit",
                "None", "Allow"
            )
            $acl.AddAccessRule($adminRule)

            # Regla para el usuario (control total sobre su propia carpeta)
            $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "$env:USERDOMAIN\$SamAccountName", "FullControl",
                "ContainerInherit,ObjectInherit", "None", "Allow"
            )
            $acl.AddAccessRule($userRule)

            Set-Acl -Path $folderPath -AclObject $acl -ErrorAction Stop
        } | Out-Null
        Write-Log SUCCESS "Permisos NTFS configurados: $folderPath"
    } catch {
        Write-Log WARN "No se pudieron configurar permisos NTFS para '$folderPath': $_"
    }

    # Actualizar HomeDirectory en AD
    try {
        Invoke-Logged "Actualizar HomeDirectory en AD: $SamAccountName" {
            Set-ADUser -Identity $SamAccountName `
                -HomeDirectory $folderPath `
                -HomeDrive 'H:' `
                -ErrorAction Stop
        } | Out-Null
        Write-Log SUCCESS "HomeDirectory actualizado en AD: $SamAccountName -> $folderPath"
    } catch {
        Write-Log WARN "No se pudo actualizar HomeDirectory en AD para '$SamAccountName': $_"
    }

    # Compartir en red (opcional)
    if ($ShareFolder) {
        $shareName = "$SamAccountName`$"   # Share oculto (con $)
        $existing  = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
        if ($null -eq $existing) {
            try {
                Invoke-Logged "Crear share SMB: $shareName" {
                    New-SmbShare `
                        -Name        $shareName `
                        -Path        $folderPath `
                        -Description "Home de $SamAccountName" `
                        -FullAccess  "$env:USERDOMAIN\$SamAccountName" `
                        -ErrorAction Stop
                } | Out-Null
                Write-Log SUCCESS "Share creado: \\$env:COMPUTERNAME\$shareName"
            } catch {
                Write-Log WARN "No se pudo crear el share '$shareName': $_"
            }
        } else {
            Write-Log INFO "El share '$shareName' ya existe."
        }
    }

    return $folderPath
}

# -----------------------------------------------------------------------------
# New-ACQuotaTemplate
# Crea una plantilla de cuota en FSRM.
#
# Parametros:
#   -TemplateName  Nombre de la plantilla
#   -SizeMB        Tamano de la cuota en MB
#   -HardQuota     Si $true, bloquea escritura al alcanzar el limite
#   -ThresholdPct  Porcentaje al que se dispara la notificacion (0 = sin umbral)
#   -SendEmail     Si $true, envia correo al alcanzar el umbral
#
# Devuelve: nombre de la plantilla | $false
# -----------------------------------------------------------------------------
function New-ACQuotaTemplate {
    param(
        [Parameter(Mandatory)] [string] $TemplateName,
        [Parameter(Mandatory)] [int]    $SizeMB,
        [bool]   $HardQuota    = $true,
        [int]    $ThresholdPct = 85,
        [bool]   $SendEmail    = $false
    )

    $sizeBytes = [int64]$SizeMB * 1MB

    # Verificar si ya existe
    $existing = Get-FsrmQuotaTemplate -Name $TemplateName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log WARN "La plantilla de cuota '$TemplateName' ya existe. Se sobreescribira."
        try {
            Remove-FsrmQuotaTemplate -Name $TemplateName -Confirm:$false -ErrorAction Stop
        } catch {
            Write-Log WARN "No se pudo eliminar la plantilla existente: $_"
        }
    }

    # Construir acciones del umbral
    $actions = @()
    if ($SendEmail) {
        $emailAction = New-FsrmAction `
            -Type Email `
            -MailTo      '[Admin Email]' `
            -Subject     "Alerta de cuota: [Quota Path]" `
            -Body        "El usuario [Source Io Owner] ha alcanzado el $ThresholdPct% de su cuota en [Quota Path].`nUso actual: [Quota Used Bytes] de [Quota Limit Bytes]." `
            -ErrorAction SilentlyContinue
        if ($emailAction) { $actions += $emailAction }
    }

    # Accion de log de eventos (siempre activa)
    $eventAction = New-FsrmAction `
        -Type Event `
        -EventType Warning `
        -Body "Alerta de cuota en [Quota Path]: [Quota Used Bytes] / [Quota Limit Bytes]" `
        -ErrorAction SilentlyContinue
    if ($eventAction) { $actions += $eventAction }

    # Construir umbral
    $thresholdParams = @{
        Percentage = $ThresholdPct
    }
    if ($actions.Count -gt 0) {
        $thresholdParams['Action'] = $actions
    }

    try {
        $threshold = New-FsrmQuotaThreshold @thresholdParams -ErrorAction Stop
    } catch {
        Write-Log WARN "No se pudo crear el umbral de notificacion: $_"
        $threshold = $null
    }

    # Crear la plantilla
    try {
        $templateParams = @{
            Name        = $TemplateName
            Size        = $sizeBytes
            SoftLimit   = (-not $HardQuota)
            ErrorAction = 'Stop'
        }
        if ($null -ne $threshold) {
            $templateParams['Threshold'] = @($threshold)
        }

        Invoke-Logged "Crear plantilla de cuota: $TemplateName ($SizeMB MB, $(if ($HardQuota) { 'Hard' } else { 'Soft' }))" {
            New-FsrmQuotaTemplate @templateParams
        } | Out-Null

        Write-Log SUCCESS "Plantilla de cuota creada: $TemplateName — $SizeMB MB $(if ($HardQuota) { '[HARD]' } else { '[SOFT]' })"
        return $TemplateName
    } catch {
        Write-Log ERROR "No se pudo crear la plantilla de cuota '$TemplateName': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Set-FSRMQuotaOnFolder
# Aplica una cuota (desde plantilla o directa) a una carpeta.
#
# Parametros:
#   -FolderPath     Ruta de la carpeta
#   -TemplateName   Nombre de la plantilla FSRM (opcional)
#   -SizeMB         Tamano en MB si no se usa plantilla
#   -HardQuota      Tipo de cuota si no se usa plantilla
#
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Set-FSRMQuotaOnFolder {
    param(
        [Parameter(Mandatory)] [string] $FolderPath,
        [string] $TemplateName = $null,
        [int]    $SizeMB       = 0,
        [bool]   $HardQuota    = $true
    )

    # Verificar si ya tiene cuota — actualizar en lugar de eliminar y recrear
    $existing = Get-FsrmQuota -Path $FolderPath -ErrorAction SilentlyContinue
    if ($existing) {
        if ($TemplateName) {
            try {
                Set-FsrmQuota -Path $FolderPath -Template $TemplateName -ErrorAction Stop
                Write-Log SUCCESS "Cuota actualizada (plantilla '$TemplateName'): $FolderPath"
                return $true
            } catch {
                Write-Log WARN "No se pudo actualizar cuota existente, recreando: $_"
                try { Remove-FsrmQuota -Path $FolderPath -Confirm:$false -ErrorAction Stop } catch {}
            }
        } else {
            try { Remove-FsrmQuota -Path $FolderPath -Confirm:$false -ErrorAction Stop } catch {}
        }
    }

    # Si la carpeta no existe, crearla automaticamente
    if (-not (Test-Path $FolderPath)) {
        Write-Log WARN "Carpeta no encontrada, creando: $FolderPath"
        try {
            New-Item -ItemType Directory -Path $FolderPath -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Log ERROR "No se pudo crear la carpeta '$FolderPath': $_"
            return $false
        }
    }

    try {
        if ($TemplateName) {
            # Verificar que la plantilla existe antes de aplicarla
            $tmpl = Get-FsrmQuotaTemplate -Name $TemplateName -ErrorAction SilentlyContinue
            if (-not $tmpl) {
                Write-Log ERROR "La plantilla '$TemplateName' no existe en FSRM."
                return $false
            }
            Invoke-Logged "Aplicar cuota desde plantilla '$TemplateName' a: $FolderPath" {
                New-FsrmQuota `
                    -Path         $FolderPath `
                    -Template     $TemplateName `
                    -ErrorAction  Stop
            } | Out-Null
        } else {
            $sizeBytes = [int64]$SizeMB * 1MB
            Invoke-Logged "Aplicar cuota directa $SizeMB MB a: $FolderPath" {
                New-FsrmQuota `
                    -Path       $FolderPath `
                    -Size       $sizeBytes `
                    -SoftLimit  (-not $HardQuota) `
                    -ErrorAction Stop
            } | Out-Null
        }
        Write-Log SUCCESS "Cuota aplicada a: $FolderPath"
        return $true
    } catch {
        Write-Log ERROR "No se pudo aplicar la cuota a '$FolderPath': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# New-ACFileGroup
# Crea un grupo de archivos con las extensiones a bloquear.
#
# Parametros:
#   -GroupName    Nombre del grupo de archivos
#   -Extensions   Array de extensiones (con punto: '.mp3', '.exe')
#
# Devuelve: nombre del grupo | $false
# -----------------------------------------------------------------------------
function New-ACFileGroup {
    param(
        [Parameter(Mandatory)] [string]   $GroupName,
        [Parameter(Mandatory)] [string[]] $Extensions
    )

    # Convertir extensiones a patrones de FSRM (ej: *.mp3)
    $patterns = $Extensions | ForEach-Object {
        $ext = $_.Trim().ToLower()
        if (-not $ext.StartsWith('.')) { $ext = ".$ext" }
        "*$ext"
    }

    # Eliminar grupo existente si hay
    $existing = Get-FsrmFileGroup -Name $GroupName -ErrorAction SilentlyContinue
    if ($existing) {
        try {
            Remove-FsrmFileGroup -Name $GroupName -Confirm:$false -ErrorAction Stop
        } catch {}
    }

    try {
        Invoke-Logged "Crear grupo de archivos: $GroupName ($($patterns.Count) patrones)" {
            New-FsrmFileGroup `
                -Name           $GroupName `
                -IncludePattern $patterns `
                -ErrorAction    Stop
        } | Out-Null
        Write-Log SUCCESS "Grupo de archivos creado: $GroupName"
        Write-Log INFO    "Patrones: $($patterns -join ', ')"
        return $GroupName
    } catch {
        Write-Log ERROR "No se pudo crear el grupo de archivos '$GroupName': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# New-ACFileScreen
# Crea un File Screen (apantallamiento) en una carpeta.
# Usa Active Screening (bloqueo real) por defecto.
#
# Parametros:
#   -FolderPath    Ruta de la carpeta a proteger
#   -FileGroupName Nombre del grupo de archivos a bloquear
#   -Active        Si $true, Active Screening (bloqueo real)
#                  Si $false, Passive Screening (solo log)
#   -SendEmail     Si $true, envia correo al detectar archivo bloqueado
#
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function New-ACFileScreen {
    param(
        [Parameter(Mandatory)] [string] $FolderPath,
        [Parameter(Mandatory)] [string] $FileGroupName,
        [bool] $Active    = $true,
        [bool] $SendEmail = $false
    )

    if (-not (Test-Path $FolderPath)) {
        Write-Log ERROR "La carpeta no existe: $FolderPath"
        return $false
    }

    # Eliminar file screen existente
    $existing = Get-FsrmFileScreen -Path $FolderPath -ErrorAction SilentlyContinue
    if ($existing) {
        try {
            Remove-FsrmFileScreen -Path $FolderPath -Confirm:$false -ErrorAction Stop
        } catch {}
    }

    # Construir acciones de notificacion
    $actions = [System.Collections.Generic.List[object]]::new()

    # Accion de log (siempre)
    try {
        $logAction = New-FsrmAction `
            -Type      Event `
            -EventType Warning `
            -Body      "Archivo bloqueado en [File Screen Path]: [Source File Path] ([Source Io Owner])" `
            -ErrorAction Stop
        $actions.Add($logAction)
    } catch {
        Write-Log WARN "No se pudo crear accion de log para file screen: $_"
    }

    # Accion de correo (opcional)
    if ($SendEmail) {
        try {
            $emailAction = New-FsrmAction `
                -Type    Email `
                -MailTo  '[Admin Email]' `
                -Subject "Archivo bloqueado: [File Screen Path]" `
                -Body    "El usuario [Source Io Owner] intento guardar el archivo bloqueado:[Source File Path]`nFecha: [Event Time]" `
                -ErrorAction Stop
            $actions.Add($emailAction)
        } catch {
            Write-Log WARN "No se pudo crear accion de email para file screen: $_"
        }
    }

    # Crear el file screen
    try {
        $screenParams = @{
            IncludeGroup = @($FileGroupName)
            Active       = $Active
            ErrorAction  = 'Stop'
        }
        if ($actions.Count -gt 0) {
            $screenParams['Notification'] = $actions.ToArray()
        }

        Invoke-Logged "Crear file screen $(if ($Active) { 'ACTIVO' } else { 'PASIVO' }) en: $FolderPath" {
            New-FsrmFileScreen -Path $FolderPath @screenParams
        } | Out-Null

        Write-Log SUCCESS "File screen $(if ($Active) { 'activo' } else { 'pasivo' }) creado: $FolderPath"
        return $true
    } catch {
        Write-Log ERROR "No se pudo crear el file screen en '$FolderPath': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Invoke-FSRMGroupSetup
# Flujo interactivo para configurar cuotas y file screening por grupo AD.
# Para cada grupo: define cuota, tipo, umbral; crea carpetas home; aplica todo.
# -----------------------------------------------------------------------------
function Invoke-FSRMGroupSetup {
    Write-LogSection "Configuracion de FSRM por Grupo"

    if (-not (Test-FSRMInstalled)) {
        $installed = Install-FSRMRole
        if (-not $installed) { return $false }
    }

    if ([string]::IsNullOrWhiteSpace($script:FSRM_HOMES_ROOT)) {
        $ok = Initialize-FSRMPaths
        if (-not $ok) { return $false }
    }

    # ── Configurar extensiones bloqueadas ─────────────────────────────────────
    Write-Host ""
    msg_info "Configuracion de extensiones de archivo bloqueadas"
    Write-Separator
    msg_info "Extensiones por defecto:"
    Write-Host "  $($script:FSRM_DEFAULT_BLOCKED -join '  ')" -ForegroundColor DarkCyan

    $useDefault = Read-Confirm `
        -Prompt "Usar estas extensiones como base" `
        -Default 'S'

    $blockedExtensions = if ($useDefault) {
        [System.Collections.Generic.List[string]]::new([string[]]$script:FSRM_DEFAULT_BLOCKED)
    } else {
        [System.Collections.Generic.List[string]]::new()
    }

    # Agregar extensiones personalizadas
    $addMore = Read-Confirm `
        -Prompt "Agregar extensiones adicionales" `
        -Default 'N'

    if ($addMore) {
        $custom = Read-StringList `
            -Prompt     "Ingresa las extensiones a agregar" `
            -ItemPrompt "Extension" `
            -MinItems   1 `
            -Validator  { param($v) $v -match '^\.?[a-zA-Z0-9]{1,10}$' } `
            -ErrorMsg   "Extension invalida. Ejemplos: .iso  .rar  .zip" `
            -Transform  { param($v) if ($v.StartsWith('.')) { $v.ToLower() } else { ".$($v.ToLower())" } }
        if ($custom -ne $false) {
            foreach ($ext in $custom) {
                if (-not $blockedExtensions.Contains($ext)) {
                    $blockedExtensions.Add($ext)
                }
            }
        }
    }

    # Eliminar extensiones
    $removeExt = Read-Confirm `
        -Prompt "Eliminar alguna extension de la lista" `
        -Default 'N'

    if ($removeExt) {
        $toRemove = Read-MultiSelect `
            -Prompt   "Selecciona las extensiones a eliminar" `
            -Options  $blockedExtensions.ToArray() `
            -MinSelect 1
        if ($toRemove -ne $false) {
            foreach ($item in $toRemove) {
                $blockedExtensions.Remove($item.Value) | Out-Null
            }
        }
    }

    msg_info "Extensiones bloqueadas finales ($($blockedExtensions.Count)):"
    Write-Host "  $($blockedExtensions -join '  ')" -ForegroundColor Yellow

    # ── Tipo de file screening ────────────────────────────────────────────────
    $screenTypeSel = Read-Selection `
        -Prompt "Tipo de apantallamiento de archivos" `
        -Options @(
            "Active Screening — Bloqueo real (RECOMENDADO para la rubrica)",
            "Passive Screening — Solo registro en log, no bloquea"
        )
    if ($screenTypeSel -eq $false) { return $false }
    $activeScreening = ($screenTypeSel.Index -eq 0)

    # Notificaciones por email para file screen
    $screenEmail = Read-Confirm `
        -Prompt "Enviar correo al detectar archivo bloqueado" `
        -Default 'N'

    # ── Crear grupo de archivos FSRM ──────────────────────────────────────────
    $fileGroupName = Read-InputLoop `
        -Prompt "Nombre del grupo de archivos bloqueados (ej: Archivos_Bloqueados)" `
        -Validator { param($v) $v -match '^[a-zA-Z0-9_\- ]{3,64}$' } `
        -ErrorMsg  "Nombre invalido. 3-64 caracteres alfanumericos."
    if ($fileGroupName -eq $false) { return $false }

    $extArray = [string[]]$blockedExtensions
    $fgResult = New-ACFileGroup `
        -GroupName  $fileGroupName `
        -Extensions $extArray
    if ($fgResult -eq $false) { return $false }

    # ── Configurar grupos AD ──────────────────────────────────────────────────
    Write-Host ""
    msg_info "Ahora configuraremos la cuota para cada grupo de usuarios."

    # Obtener grupos del dominio
    $adGroups = $null
    try {
        $adGroups = Get-ADGroup -Filter * -SearchBase $script:AD_DOMAIN_DN `
                    -ErrorAction Stop | Sort-Object Name |
                    Select-Object -ExpandProperty Name
    } catch {
        Write-Log ERROR "No se pudieron obtener los grupos de AD: $_"
        return $false
    }

    if (@($adGroups).Count -eq 0) {
        Write-Log ERROR "No hay grupos en el dominio."
        return $false
    }

    $groupsSel = Read-MultiSelect `
        -Prompt    "Selecciona los grupos a los que aplicar cuotas" `
        -Options   $adGroups `
        -MinSelect 1
    if ($groupsSel -eq $false) { return $false }

    # Preguntar si compartir carpetas
    $shareHomeFolders = Read-Confirm `
        -Prompt "Crear shares SMB para las carpetas home (acceso por red)" `
        -Default 'S'

    $groupResults = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($grpItem in $groupsSel) {
        $groupName = $grpItem.Value
        Write-Host ""
        Write-LogSection "Grupo: $groupName"

        # ── Cuota para este grupo ─────────────────────────────────────────────
        $quotaMB = Read-IntInRange `
            -Prompt "Cuota de almacenamiento para '$groupName' (MB)" `
            -Min 1 -Max 102400
        if ($quotaMB -eq $false) { continue }

        $quotaTypeSel = Read-Selection `
            -Prompt "Tipo de cuota para '$groupName'" `
            -Options @(
                "Hard Quota — Bloquea escritura al alcanzar el limite (RECOMENDADO)",
                "Soft Quota — Solo alerta, permite seguir escribiendo"
            )
        if ($quotaTypeSel -eq $false) { continue }
        $isHard = ($quotaTypeSel.Index -eq 0)

        if (-not $isHard) {
            msg_alert "ADVERTENCIA: Soft Quota no bloquea fisicamente."
            msg_alert "La rubrica de evaluacion requiere bloqueo fisico (Hard Quota)."
            $confirm = Read-Confirm -Prompt "Confirmar uso de Soft Quota de todas formas" -Default 'N'
            if (-not $confirm) {
                $isHard = $true
                msg_info "Cambiado a Hard Quota."
            }
        }

        # ── Umbral de notificacion ────────────────────────────────────────────
        $thresholdPct = Read-IntInRange `
            -Prompt    "Porcentaje para disparar notificacion (0 para desactivar)" `
            -Min 0 -Max 99 `
            -Default   85
        if ($thresholdPct -eq $false) { $thresholdPct = 85 }
        $thresholdPct = [int]$thresholdPct

        $quotaEmail = Read-Confirm `
            -Prompt "Enviar correo al alcanzar el umbral de cuota" `
            -Default 'N'

        # Crear plantilla de cuota
        $templateName = "Cuota_${groupName}_${quotaMB}MB"
        $tResult = New-ACQuotaTemplate `
            -TemplateName  $templateName `
            -SizeMB        $quotaMB `
            -HardQuota     $isHard `
            -ThresholdPct  $thresholdPct `
            -SendEmail     $quotaEmail
        if ($tResult -eq $false) { continue }

        # ── Procesar usuarios del grupo ───────────────────────────────────────
        $members = $null
        try {
            $members = Get-ADGroupMember -Identity $groupName -ErrorAction Stop |
                       Where-Object { $_.objectClass -eq 'user' }
        } catch {
            Write-Log ERROR "No se pudieron obtener miembros del grupo '$groupName': $_"
            continue
        }

        if ($null -eq $members -or @($members).Count -eq 0) {
            Write-Log WARN "El grupo '$groupName' no tiene miembros. Se omite."
            continue
        }

        $ok = 0; $fail = 0
        foreach ($member in $members) {
            $sam = $member.SamAccountName

            # Crear carpeta home
            $homePath = New-UserHomeFolder `
                -SamAccountName $sam `
                -HomesRoot      $script:FSRM_HOMES_ROOT `
                -ShareFolder    $shareHomeFolders

            if ($homePath -eq $false) { $fail++; continue }

            # Aplicar cuota
            $qResult = Set-FSRMQuotaOnFolder `
                -FolderPath    $homePath `
                -TemplateName  $templateName
            if (-not $qResult) { $fail++; continue }

            # Aplicar file screen
            $fsResult = New-ACFileScreen `
                -FolderPath    $homePath `
                -FileGroupName $fileGroupName `
                -Active        $activeScreening `
                -SendEmail     $screenEmail
            if (-not $fsResult) {
                Write-Log WARN "File screen no aplicado a '$homePath', pero cuota si."
            }

            $ok++
        }

        $groupResults.Add(@{
            Group      = $groupName
            QuotaMB    = $quotaMB
            HardQuota  = $isHard
            Template   = $templateName
            Members    = @($members).Count
            OK         = $ok
            Failed     = $fail
        })

        Write-Log SUCCESS "Grupo '$groupName': $ok/$(@($members).Count) usuarios procesados."
    }

    # ── Resumen final ─────────────────────────────────────────────────────────
    Write-Host ""
    Write-LogSection "Resumen FSRM"
    foreach ($r in $groupResults) {
        $type = if ($r.HardQuota) { 'Hard' } else { 'Soft' }
        msg_info "  $($r.Group.PadRight(25)) $($r.QuotaMB) MB [$type]  $($r.OK)/$($r.Members) usuarios"
    }
    msg_info "  Extensiones bloqueadas : $($blockedExtensions.Count)"
    msg_info "  Tipo de screening      : $(if ($activeScreening) { 'Active (bloqueo real)' } else { 'Passive (solo log)' })"
    msg_info "  Carpetas home en       : $script:FSRM_HOMES_ROOT"

    return $true
}

# -----------------------------------------------------------------------------
# Get-ACStorageReport
# Genera un reporte de uso de almacenamiento via FSRM.
#
# Parametros:
#   -ReportPath  Ruta donde guardar el reporte (default: $script:FSRM_REPORT_PATH)
#   -ScopePath   Ruta a analizar (default: $script:FSRM_HOMES_ROOT)
# -----------------------------------------------------------------------------
function Get-ACStorageReport {
    param(
        [string] $ReportPath = $script:FSRM_REPORT_PATH,
        [string] $ScopePath  = $script:FSRM_HOMES_ROOT
    )

    Write-LogSection "Reporte de Uso de Almacenamiento FSRM"

    if ([string]::IsNullOrWhiteSpace($ReportPath)) {
        $ReportPath = Read-FilePath `
            -Prompt "Ruta para guardar el reporte" `
            -MustExist $false -Type 'Any'
        if ($ReportPath -eq $false) { return $false }
    }

    if ([string]::IsNullOrWhiteSpace($ScopePath) -or -not (Test-Path $ScopePath)) {
        $ScopePath = Read-FilePath `
            -Prompt "Ruta a analizar" `
            -MustExist $true -Type 'Directory'
        if ($ScopePath -eq $false) { return $false }
    }

    $reportTypes = Read-MultiSelect `
        -Prompt   "Tipos de reporte a generar" `
        -Options  @('LargeFiles','DuplicateFiles','FilesByType','QuotaUsage','FileScreenAudit') `
        -MinSelect 1 `
        -AllowAll  $true
    if ($reportTypes -eq $false) { return $false }

    $types = $reportTypes | ForEach-Object { $_.Value }

    try {
        Invoke-Logged "Generar reporte FSRM en: $ReportPath" {
            New-FsrmStorageReport `
                -Name         "Reporte_$(Get-Date -Format 'yyyyMMdd_HHmm')" `
                -Namespace    @($ScopePath) `
                -ReportType   $types `
                -ReportFormat @('XML','HTML') `
                -ErrorAction  Stop
        } | Out-Null
        Write-Log SUCCESS "Reporte generado en: $ReportPath"
        return $true
    } catch {
        Write-Log ERROR "No se pudo generar el reporte: $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Invoke-FSRMMenu
# Menu del modulo para integracion con ac_manager.ps1
# -----------------------------------------------------------------------------
function Invoke-FSRMMenu {
    while ($true) {
        Write-Host ""
        draw_header "Gestion de Almacenamiento — FSRM"

        $sel = Read-Selection `
            -Prompt "Selecciona una opcion" `
            -Options @(
                "Configuracion completa (cuotas + file screening por grupo)",
                "Inicializar rutas y configuracion SMTP",
                "Crear/modificar plantilla de cuota",
                "Aplicar cuota a una carpeta especifica",
                "Crear/modificar grupo de archivos bloqueados",
                "Aplicar file screen a una carpeta especifica",
                "Generar reporte de almacenamiento",
                "Ver estado actual de cuotas"
            ) `
            -AllowBack $true

        if ($null -eq $sel -or $sel -eq $false) { return }

        switch ($sel.Index) {
            0 { Invoke-FSRMGroupSetup }
            1 { Initialize-FSRMPaths }
            2 {
                $name = Read-InputLoop `
                    -Prompt "Nombre de la plantilla" `
                    -Validator { param($v) $v.Length -ge 3 } `
                    -ErrorMsg "Minimo 3 caracteres."
                if ($name -eq $false) { break }
                $mb = Read-IntInRange -Prompt "Tamano en MB" -Min 1 -Max 102400
                if ($mb -eq $false) { break }
                $hard = Read-Confirm -Prompt "Hard Quota (bloqueo real)" -Default 'S'
                $thr  = Read-IntInRange -Prompt "Umbral de notificacion %" -Min 0 -Max 99 -Default 85
                New-ACQuotaTemplate -TemplateName $name -SizeMB $mb -HardQuota $hard -ThresholdPct $thr
            }
            3 {
                $path = Read-FilePath -Prompt "Ruta de la carpeta" -MustExist $true -Type 'Directory'
                if ($path -eq $false) { break }
                $mb   = Read-IntInRange -Prompt "Tamano en MB" -Min 1 -Max 102400
                if ($mb -eq $false) { break }
                $hard = Read-Confirm -Prompt "Hard Quota" -Default 'S'
                Set-FSRMQuotaOnFolder -FolderPath $path -SizeMB $mb -HardQuota $hard
            }
            4 {
                $name = Read-InputLoop `
                    -Prompt "Nombre del grupo de archivos" `
                    -Validator { param($v) $v.Length -ge 3 } `
                    -ErrorMsg "Minimo 3 caracteres."
                if ($name -eq $false) { break }
                $exts = Read-StringList `
                    -Prompt     "Extensiones a bloquear" `
                    -ItemPrompt "Extension" `
                    -MinItems   1 `
                    -Validator  { param($v) $v -match '^\.?[a-zA-Z0-9]{1,10}$' } `
                    -ErrorMsg   "Extension invalida (ej: .mp3 o mp3)" `
                    -Transform  { param($v) if ($v.StartsWith('.')) { $v.ToLower() } else { ".$($v.ToLower())" } }
                if ($exts -eq $false) { break }
                New-ACFileGroup -GroupName $name -Extensions $exts
            }
            5 {
                $path  = Read-FilePath -Prompt "Ruta de la carpeta" -MustExist $true -Type 'Directory'
                if ($path -eq $false) { break }
                $groups = Get-FsrmFileGroup -ErrorAction SilentlyContinue |
                          Select-Object -ExpandProperty Name
                if (@($groups).Count -eq 0) {
                    Write-Log WARN "No hay grupos de archivos FSRM. Crea uno primero."
                    break
                }
                $grpSel = Read-Selection -Prompt "Grupo de archivos a aplicar" -Options $groups
                if ($grpSel -eq $false) { break }
                $active = Read-Confirm -Prompt "Active Screening (bloqueo real)" -Default 'S'
                New-ACFileScreen -FolderPath $path -FileGroupName $grpSel.Value -Active $active
            }
            6 { Get-ACStorageReport }
            7 {
                try {
                    $quotas = Get-FsrmQuota -ErrorAction Stop
                    if (@($quotas).Count -eq 0) {
                        msg_info "No hay cuotas configuradas."
                    } else {
                        Write-Separator
                        foreach ($q in $quotas) {
                            $usedPct = if ($q.Size -gt 0) {
                                [Math]::Round(($q.Usage / $q.Size) * 100, 1)
                            } else { 0 }
                            $type = if ($q.SoftLimit) { 'Soft' } else { 'Hard' }
                            msg_info "  $($q.Path.PadRight(40)) $([Math]::Round($q.Size/1MB))MB [$type] Usado: $usedPct%"
                        }
                        Write-Separator
                    }
                } catch {
                    Write-Log ERROR "No se pudieron obtener las cuotas: $_"
                }
            }
        }

        msg_pause
    }
}