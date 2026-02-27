# =============================================================================
# ssh_manager.ps1 — Gestor de OpenSSH Server (Windows)
#
# Uso interactivo:    .\ssh_manager.ps1
# Uso por parametros: .\ssh_manager.ps1 [COMANDO] [OPCIONES]
#
# =============================================================================

#Requires -RunAsAdministrator

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($lib in @('ui', 'net', 'iface')) {
    $libPath = Join-Path $ScriptDir "lib\${lib}.ps1"
    if (-not (Test-Path $libPath)) {
        Write-Host "ERROR: No se encontro el modulo requerido: $libPath"
        exit 1
    }
    . $libPath
}

# =============================================================================
# CONSTANTES
# =============================================================================

$SSH_SERVICE          = "sshd"
$SSHD_CONFIG          = "C:\ProgramData\ssh\sshd_config"
$SSHD_CONFIG_BAK      = "C:\ProgramData\ssh\sshd_config.bak"
$SSHD_HARDENING_CONF  = "C:\ProgramData\ssh\sshd_config.d\99-hardening.conf"
$SSH_DEFAULT_PORT     = 22

$MAX_ATTEMPTS = if ($env:MAX_ATTEMPTS) { [int]$env:MAX_ATTEMPTS } else { 100 }

# =============================================================================
# INSTALACION (idempotente)
# =============================================================================

function Install-SshServer {
    Write-Separator
    Write-Host "=== INSTALACION OpenSSH SSH Server ===" -ForegroundColor White
    Write-Separator
    Write-Host ""

    msg_process "Verificando OpenSSH SSH Server..."

    $feature = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -eq 'Installed') {
        msg_success "OpenSSH SSH Server ya esta instalado"
        $sshVersion = Get-Command ssh.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Version
        if ($sshVersion) { msg_info "Version detectada: $sshVersion" }
    } else {
        msg_process "Instalando OpenSSH SSH Server..."
        try {
            Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop | Out-Null
            msg_success "OpenSSH SSH Server instalado correctamente"
        } catch {
            # -- DEBUG --
            msg_alert "Error del sistema al instalar OpenSSH SSH Server: $_"
            msg_error "Fallo la instalacion de OpenSSH SSH Server: $_"
            return $false
        }
    }

    # Habilitar al arranque
    $svc = Get-Service -Name $SSH_SERVICE -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.StartType -ne 'Automatic') {
            msg_process "Habilitando servicio $SSH_SERVICE al arranque..."
            try {
                Set-Service -Name $SSH_SERVICE -StartupType Automatic -ErrorAction Stop
                msg_success "Servicio habilitado"
            } catch {
                # -- DEBUG --
                msg_alert "Error del sistema al habilitar $SSH_SERVICE : $_"
            }
        } else {
            msg_info "Servicio ya habilitado en el arranque"
        }

        # Iniciar si no corre
        if ($svc.Status -ne 'Running') {
            msg_process "Iniciando servicio $SSH_SERVICE..."
            try {
                Start-Service -Name $SSH_SERVICE -ErrorAction Stop
                msg_success "Servicio iniciado"
            } catch {
                # -- DEBUG --
                msg_alert "Error del sistema al iniciar $SSH_SERVICE : $_"
                msg_error "No se pudo iniciar el servicio: $_"
                return $false
            }
        } else {
            msg_info "Servicio ya en ejecucion"
        }
    }

    Write-Host ""
    msg_success "Instalacion completada"
    Write-Host ""
    return $true
}

# =============================================================================
# FIREWALL
# =============================================================================

function Set-SshFirewall {
    param([int]$port = $SSH_DEFAULT_PORT, [string]$interfaceName = "")

    Write-Separator
    Write-Host "=== CONFIGURACION FIREWALL ===" -ForegroundColor White
    Write-Separator
    Write-Host ""

    $profile = 'Any'
    if ($interfaceName -and (Test-InterfaceExists $interfaceName)) {
        $profile = Get-InterfaceFirewallProfile $interfaceName
        msg_info "Perfil detectado para ${interfaceName}: $profile"
    } else {
        msg_info "Usando perfil de firewall: Any"
    }

    # Mantener regla para puerto 22 (no bloquear sesiones activas)
    if ($port -ne 22) {
        try {
            $r22 = Get-NetFirewallRule -DisplayName "OpenSSH Server (sshd)" -ErrorAction SilentlyContinue
            if (-not $r22) {
                New-NetFirewallRule -DisplayName "OpenSSH Server (sshd)" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            }
        } catch {
            # -- DEBUG --
            msg_alert "Error del sistema al crear regla SSH puerto 22: $_"
        }
    }

    # Regla para el puerto configurado
    $ruleName = "OpenSSH Server port $port"
    try {
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($existing) { Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue }
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
        msg_success "Firewall configurado — puerto: $port"
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al crear regla SSH puerto $port : $_"
        msg_error "No se pudo configurar el firewall: $_"
    }
    Write-Host ""
}

function Remove-SshFirewallPort {
    param([int]$port, [string]$profile)
    if ($port -eq 22) { return }
    try {
        Remove-NetFirewallRule -DisplayName "OpenSSH Server port $port" -ErrorAction SilentlyContinue
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al eliminar regla firewall puerto $port : $_"
    }
}

# =============================================================================
# CONFIGURACION DE SSHD
# =============================================================================

function Read-SshdDirective {
    param([string]$key)
    if (-not (Test-Path $SSHD_CONFIG)) { return $null }
    $line = Get-Content $SSHD_CONFIG | Where-Object { $_ -match "^\s*$key\s" } | Select-Object -Last 1
    if ($line) { return ($line -split '\s+')[1] }
    return $null
}

function Set-SshdDirective {
    param([string]$key, [string]$value)
    if (-not (Test-Path $SSHD_CONFIG)) { return }
    $content = Get-Content $SSHD_CONFIG
    $pattern = "(?i)^\s*#?\s*$key\s"
    if ($content -match $pattern) {
        $content = $content -replace "(?i)^\s*#?\s*$key\s.*", "$key $value"
    } else {
        $content += "$key $value"
    }
    $content | Set-Content $SSHD_CONFIG -Encoding UTF8
}

function Invoke-ConfigureSsh {
    Write-Separator
    Write-Host "=== CONFIGURACION SSH ===" -ForegroundColor White
    Write-Separator
    Write-Host ""

    # Backup
    if (-not (Test-Path $SSHD_CONFIG_BAK)) {
        try {
            Copy-Item $SSHD_CONFIG $SSHD_CONFIG_BAK -ErrorAction Stop
            msg_info "Backup creado en $SSHD_CONFIG_BAK"
        } catch {
            # -- DEBUG --
            msg_alert "Error del sistema al crear backup de sshd_config: $_"
        }
    }

    $currentPort = Read-SshdDirective "Port"
    $currentPort = if ($currentPort) { $currentPort } else { "22" }

    # --- Puerto ---
    Write-Separator
    msg_info "Puerto actual: $currentPort"
    Write-Host ""
    $attempts = 0; $newPort = $currentPort
    while ($attempts -lt $MAX_ATTEMPTS) {
        msg_input "Nuevo puerto SSH [Enter = mantener $currentPort]: "
        $input = Read-Host
        if ([string]::IsNullOrEmpty($input)) { $newPort = $currentPort; break }
        if ($input -match '^\d+$' -and [int]$input -ge 1 -and [int]$input -le 65535) {
            $newPort = $input; break
        }
        msg_error "Puerto invalido (1-65535)"
        $attempts++
    }
    if ($attempts -ge $MAX_ATTEMPTS) { msg_error "Demasiados intentos"; return $false }

    # --- Interfaz para firewall ---
    Write-Host ""
    Write-Separator
    msg_process "Interfaces de red disponibles:"
    Write-Host ""
    Get-NetworkInterfaces | ForEach-Object { Write-Host $_ }
    Write-Host ""
    msg_input "Interfaz para firewall [Enter = perfil Any]: "
    $INTERFAZ_SSH = Read-Host

    # --- PasswordAuthentication ---
    Write-Host ""
    Write-Separator
    $passauthActual = Read-SshdDirective "PasswordAuthentication"
    $passauthActual = if ($passauthActual) { $passauthActual } else { "yes" }
    msg_info "PasswordAuthentication actual: $passauthActual"
    Write-Host ""
    msg_input "Permitir autenticacion por contrasena? (s/N) [actual: $passauthActual]: "
    $respPassauth = Read-Host
    $passauth = if ($respPassauth -match '^[sS]$') { "yes" } else { "no" }

    # --- PermitRootLogin ---
    Write-Host ""
    Write-Separator
    $rootLoginActual = Read-SshdDirective "PermitRootLogin"
    $rootLoginActual = if ($rootLoginActual) { $rootLoginActual } else { "yes" }
    msg_info "PermitRootLogin actual: $rootLoginActual"
    Write-Host ""
    Write-Host "  " -NoNewline; Write-Host "1." -ForegroundColor Green -NoNewline; Write-Host " no               (recomendado)"
    Write-Host "  " -NoNewline; Write-Host "2." -ForegroundColor Green -NoNewline; Write-Host " prohibit-password (solo claves)"
    Write-Host "  " -NoNewline; Write-Host "3." -ForegroundColor Green -NoNewline; Write-Host " yes               (sin restriccion)"
    Write-Host ""
    msg_input "Opcion [Enter = mantener $rootLoginActual]: "
    $respRoot = Read-Host
    $rootLogin = switch ($respRoot) {
        '1' { "no" }
        '2' { "prohibit-password" }
        '3' { "yes" }
        default { $rootLoginActual }
    }

    # --- MaxAuthTries ---
    Write-Host ""
    Write-Separator
    $maxtriesActual = Read-SshdDirective "MaxAuthTries"
    $maxtriesActual = if ($maxtriesActual) { $maxtriesActual } else { "6" }
    msg_info "MaxAuthTries actual: $maxtriesActual"
    Write-Host ""
    $attempts = 0; $maxtries = $maxtriesActual
    while ($attempts -lt $MAX_ATTEMPTS) {
        msg_input "MaxAuthTries [Enter = mantener $maxtriesActual]: "
        $input = Read-Host
        if ([string]::IsNullOrEmpty($input)) { $maxtries = $maxtriesActual; break }
        if ($input -match '^\d+$' -and [int]$input -ge 1 -and [int]$input -le 20) { $maxtries = $input; break }
        msg_error "Valor invalido (1-20)"
        $attempts++
    }

    # --- ClientAliveInterval ---
    Write-Host ""
    Write-Separator
    $aliveActual = Read-SshdDirective "ClientAliveInterval"
    $aliveActual = if ($aliveActual) { $aliveActual } else { "0" }
    msg_info "ClientAliveInterval actual: ${aliveActual}s (0=desactivado)"
    Write-Host ""
    $attempts = 0; $alive = $aliveActual
    while ($attempts -lt $MAX_ATTEMPTS) {
        msg_input "ClientAliveInterval en segundos [Enter = mantener $aliveActual]: "
        $input = Read-Host
        if ([string]::IsNullOrEmpty($input)) { $alive = $aliveActual; break }
        if ($input -match '^\d+$') { $alive = $input; break }
        msg_error "Debe ser un numero entero >= 0"
        $attempts++
    }

    # --- Banner ---
    Write-Host ""
    Write-Separator
    $bannerActual = Read-SshdDirective "Banner"
    msg_info "Banner actual: $(if ($bannerActual) { $bannerActual } else { 'none' })"
    Write-Host ""
    msg_input "Activar banner de advertencia en C:\ProgramData\ssh\banner.txt? (s/N): "
    $respBanner = Read-Host
    $bannerValor = "none"
    if ($respBanner -match '^[sS]$') {
        $bannerPath = "C:\ProgramData\ssh\banner.txt"
        $bannerValor = $bannerPath
        if (-not (Test-Path $bannerPath)) {
            @"
*******************************************************************************
*  ACCESO RESTRINGIDO - Solo usuarios autorizados.                            *
*  Toda actividad puede ser registrada y monitoreada.                         *
*******************************************************************************
"@ | Set-Content $bannerPath -Encoding UTF8
            msg_success "Banner creado en $bannerPath"
        }
    }

    # --- Resumen ---
    Write-Host ""
    Write-Separator
    Write-Host "Resumen de configuracion SSH" -ForegroundColor White
    Write-Host ""
    Write-Host "  " -NoNewline; Write-Host "Puerto:                 " -ForegroundColor Cyan -NoNewline; Write-Host $newPort
    $ifazDisplay = if ($INTERFAZ_SSH) { $INTERFAZ_SSH } else { "perfil Any" }
    Write-Host "  " -NoNewline; Write-Host "Interfaz firewall:      " -ForegroundColor Cyan -NoNewline; Write-Host $ifazDisplay    Write-Host "  " -NoNewline; Write-Host "PasswordAuthentication: " -ForegroundColor Cyan -NoNewline; Write-Host $passauth
    Write-Host "  " -NoNewline; Write-Host "PermitRootLogin:        " -ForegroundColor Cyan -NoNewline; Write-Host $rootLogin
    Write-Host "  " -NoNewline; Write-Host "MaxAuthTries:           " -ForegroundColor Cyan -NoNewline; Write-Host $maxtries
    Write-Host "  " -NoNewline; Write-Host "ClientAliveInterval:    " -ForegroundColor Cyan -NoNewline; Write-Host $alive
    Write-Host "  " -NoNewline; Write-Host "Banner:                 " -ForegroundColor Cyan -NoNewline; Write-Host $bannerValor
    Write-Host ""
    Write-Separator
    Write-Host ""
    msg_input "Aplicar esta configuracion? (s/N): "
    $confirmar = Read-Host
    if ($confirmar -notmatch '^[sS]$') { msg_alert "Configuracion cancelada"; return $false }

    # --- Aplicar ---
    Set-SshdDirective "Port"                   $newPort
    Set-SshdDirective "PasswordAuthentication" $passauth
    Set-SshdDirective "PermitRootLogin"        $rootLogin
    Set-SshdDirective "MaxAuthTries"           $maxtries
    Set-SshdDirective "ClientAliveInterval"    $alive
    Set-SshdDirective "ClientAliveCountMax"    "3"
    Set-SshdDirective "Banner"                 $bannerValor

    msg_success "sshd_config actualizado"

    Set-SshFirewall ([int]$newPort) $INTERFAZ_SSH
    Invoke-ReloadService
    return $true
}

# =============================================================================
# HARDENING
# =============================================================================

function Apply-Hardening {
    Write-Separator
    Write-Host "=== HARDENING SSH ===" -ForegroundColor White
    Write-Separator
    Write-Host ""
    msg_info "Se aplicara un perfil de hardening recomendado para Windows OpenSSH."
    msg_info "Se guardara en: $SSHD_HARDENING_CONF"
    Write-Host ""
    msg_input "Confirmar aplicacion de hardening? (s/N): "
    $confirmar = Read-Host
    if ($confirmar -notmatch '^[sS]$') { msg_alert "Operacion cancelada"; return }

    if (-not (Test-Path $SSHD_CONFIG_BAK)) {
        try {
            Copy-Item $SSHD_CONFIG $SSHD_CONFIG_BAK -ErrorAction Stop
            msg_info "Backup creado en $SSHD_CONFIG_BAK"
        } catch {
            # -- DEBUG --
            msg_alert "Error del sistema al crear backup para hardening: $_"
        }
    }

    $hardeningDir = Split-Path $SSHD_HARDENING_CONF
    if (-not (Test-Path $hardeningDir)) { New-Item -ItemType Directory -Path $hardeningDir -Force | Out-Null }

    # El archivo de hardening aqui refleja los parametros que si son compatibles con el sshd de Windows.
    @"
# =============================================================================
# Hardening SSH - generado por ssh_manager.ps1
#       Aplicar manualmente estos valores en $SSHD_CONFIG si es necesario.
# =============================================================================

PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30

PasswordAuthentication no
PubkeyAuthentication yes

AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
GatewayPorts no

ClientAliveInterval 300
ClientAliveCountMax 2

LogLevel VERBOSE
"@ | Set-Content $SSHD_HARDENING_CONF -Encoding UTF8

    msg_success "Perfil de hardening escrito en $SSHD_HARDENING_CONF"

    # Asegurar que sshd_config principal incluya el directorio de fragmentos.
    # Sin esta directiva, el archivo de hardening es ignorado silenciosamente.
    Set-SshdDirective "Include" "C:\ProgramData\ssh\sshd_config.d\*.conf"
    msg_info "Directiva Include configurada en sshd_config"

    # Aplicar directivas al sshd_config principal
    foreach ($kv in @(
        @('PermitEmptyPasswords','no'), @('MaxAuthTries','3'), @('MaxSessions','5'),
        @('LoginGraceTime','30'), @('PasswordAuthentication','no'), @('PubkeyAuthentication','yes'),
        @('AllowAgentForwarding','no'), @('AllowTcpForwarding','no'), @('X11Forwarding','no'),
        @('GatewayPorts','no'), @('ClientAliveInterval','300'), @('ClientAliveCountMax','2'),
        @('LogLevel','VERBOSE')
    )) {
        Set-SshdDirective $kv[0] $kv[1]
    }

    # Validar config: sshd -t
    $testResult = & sshd.exe -t 2>&1
    if ($LASTEXITCODE -eq 0) {
        msg_success "Configuracion valida"
        Invoke-ReloadService
    } else {
        # -- DEBUG --
        msg_alert "Detalle del error de validacion sshd -t: $testResult"
        msg_error "La configuracion generada tiene errores - revisa manualmente"
        return
    }

    Write-Host ""
    msg_alert "IMPORTANTE: PasswordAuthentication se desactivo."
    msg_info  "Asegurate de tener al menos una clave SSH en authorized_keys antes de cerrar sesion."
    Write-Host ""
}

# =============================================================================
# GESTION DE CLAVES
# =============================================================================

function Get-UserHome {
    param([string]$username)
    try {
        Get-LocalUser -Name $username -ErrorAction Stop | Out-Null
        # Consultar la ruta real del perfil (funciona con rutas redirigidas o personalizadas)
        $profile = Get-WmiObject Win32_UserProfile -ErrorAction SilentlyContinue |
                   Where-Object { $_.LocalPath -match "\\${username}$" } |
                   Select-Object -First 1
        if ($profile) { return $profile.LocalPath }
        return "C:\Users\$username"   # fallback
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al obtener home de '$username': $_"
        return $null
    }
}

function Get-UserSshDir {
    param([string]$username)
    $userHome = Get-UserHome $username
    if ($userHome) { return "$userHome\.ssh" }
    return $null
}

function New-SshKeyPair {
    Write-Separator
    Write-Host "=== GENERAR PAR DE CLAVES SSH ===" -ForegroundColor White
    Write-Separator
    Write-Host ""

    $defaultUser = $env:USERNAME
    msg_input "Usuario destino [Enter = $defaultUser]: "
    $usuario = Read-Host
    if ([string]::IsNullOrEmpty($usuario)) { $usuario = $defaultUser }

    try { Get-LocalUser -Name $usuario -ErrorAction Stop | Out-Null }
    catch {
        # -- DEBUG --
        msg_alert "Error del sistema al verificar usuario '$usuario': $_"
        msg_error "El usuario '$usuario' no existe"
        return
    }

    $sshDir = Get-UserSshDir $usuario

    # Tipo de clave
    Write-Host ""
    Write-Host "  " -NoNewline; Write-Host "1." -ForegroundColor Green -NoNewline; Write-Host " ed25519    (recomendado)"
    Write-Host "  " -NoNewline; Write-Host "2." -ForegroundColor Green -NoNewline; Write-Host " rsa 4096"
    Write-Host "  " -NoNewline; Write-Host "3." -ForegroundColor Green -NoNewline; Write-Host " ecdsa 521"
    Write-Host ""
    msg_input "Tipo de clave [1]: "
    $tipoNum = Read-Host
    $tipo = switch ($tipoNum) {
        '2' { 'rsa' }
        '3' { 'ecdsa' }
        default { 'ed25519' }
    }
    $bits = switch ($tipoNum) {
        '2' { '-b 4096' }
        '3' { '-b 521' }
        default { '' }
    }

    # Nombre del archivo
    Write-Host ""
    $defaultFile = "$sshDir\id_$tipo"
    msg_input "Ruta del archivo [Enter = $defaultFile]: "
    $rutaCustom = Read-Host
    $nombreArchivo = if ($rutaCustom) { $rutaCustom } else { $defaultFile }

    if (Test-Path $nombreArchivo) {
        msg_alert "Ya existe una clave en $nombreArchivo"
        msg_input "Sobreescribir? (s/N): "
        $resp = Read-Host
        if ($resp -notmatch '^[sS]$') { msg_alert "Operacion cancelada"; return }
    }

    # Comentario
    Write-Host ""
    $defaultComment = "${usuario}@$env:COMPUTERNAME"
    msg_input "Comentario para la clave [Enter = $defaultComment]: "
    $comentario = Read-Host
    if ([string]::IsNullOrEmpty($comentario)) { $comentario = $defaultComment }

    # Passphrase
    Write-Host ""
    msg_input "Passphrase (Enter para sin passphrase): "
    $passphrase = Read-Host -AsSecureString
    $passTxt = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($passphrase))

    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }

    $keygen = "ssh-keygen.exe"

    # En Windows, pasar -N "" puede causar comportamiento interactivo inesperado.
    # Si hay passphrase se pasa con -N; si esta vacia se omite -N y se usa -q
    # para evitar confirmaciones interactivas.
    if ([string]::IsNullOrEmpty($passTxt)) {
        $keygArgs = @('-t', $tipo) +
                    (if ($bits) { $bits -split ' ' } else { @() }) +
                    @('-C', $comentario, '-f', $nombreArchivo, '-q', '-N', '')
    } else {
        $keygArgs = @('-t', $tipo) +
                    (if ($bits) { $bits -split ' ' } else { @() }) +
                    @('-C', $comentario, '-f', $nombreArchivo, '-N', $passTxt)
    }

    try {
        & $keygen @keygArgs 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            msg_success "Par de claves generado:"
            Write-Host "  " -NoNewline; Write-Host "Privada: " -ForegroundColor Cyan -NoNewline; Write-Host $nombreArchivo
            Write-Host "  " -NoNewline; Write-Host "Publica: " -ForegroundColor Cyan -NoNewline; Write-Host "${nombreArchivo}.pub"
            Write-Host ""
            msg_info "Clave publica:"
            Get-Content "${nombreArchivo}.pub"
            Write-Host ""
        } else {
            msg_error "Error al generar las claves"
        }
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al ejecutar ssh-keygen: $_"
        msg_error "ssh-keygen fallo: $_"
    }
}

function Add-AuthorizedKey {
    Write-Separator
    Write-Host "=== AGREGAR CLAVE AUTORIZADA ===" -ForegroundColor White
    Write-Separator
    Write-Host ""

    $defaultUser = $env:USERNAME
    msg_input "Usuario destino [Enter = $defaultUser]: "
    $usuario = Read-Host
    if ([string]::IsNullOrEmpty($usuario)) { $usuario = $defaultUser }

    try { Get-LocalUser -Name $usuario -ErrorAction Stop | Out-Null }
    catch {
        # -- DEBUG --
        msg_alert "Error del sistema al verificar usuario '$usuario': $_"
        msg_error "El usuario '$usuario' no existe"; return
    }

    $sshDir   = Get-UserSshDir $usuario
    $authKeys = "$sshDir\authorized_keys"

    Write-Host ""
    msg_info "Pega la clave publica (ssh-ed25519 / ssh-rsa / ...):"
    msg_input "> "
    $clavePublica = Read-Host
    if ([string]::IsNullOrEmpty($clavePublica)) { msg_error "No se ingreso ninguna clave"; return }

    # Validar formato
    $tipoClave = ($clavePublica -split '\s+')[0]
    $validTypes = @('ssh-ed25519','ssh-rsa','ecdsa-sha2-nistp256','ecdsa-sha2-nistp384','ecdsa-sha2-nistp521','sk-ssh-ed25519@openssh.com')
    if ($tipoClave -notin $validTypes) {
        msg_error "Formato de clave no reconocido: $tipoClave"; return
    }

    # Verificar duplicados
    if ((Test-Path $authKeys) -and (Get-Content $authKeys | Where-Object { $_ -eq $clavePublica })) {
        msg_alert "Esta clave ya existe en $authKeys"; return
    }

    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    Add-Content -Path $authKeys -Value $clavePublica -Encoding UTF8
    msg_success "Clave agregada a $authKeys"
    Write-Host ""
}

function Get-AuthorizedKeys {
    Write-Separator
    Write-Host "=== CLAVES AUTORIZADAS ===" -ForegroundColor White
    Write-Separator
    Write-Host ""

    $defaultUser = $env:USERNAME
    msg_input "Usuario [Enter = $defaultUser]: "
    $usuario = Read-Host
    if ([string]::IsNullOrEmpty($usuario)) { $usuario = $defaultUser }

    $authKeys = "$(Get-UserSshDir $usuario)\authorized_keys"
    if (-not (Test-Path $authKeys)) { msg_info "No hay claves autorizadas para '$usuario'"; return }

    $lines = Get-Content $authKeys | Where-Object { $_ -and -not $_.StartsWith('#') }
    msg_info "Claves autorizadas para '$usuario' ($($lines.Count)):"
    Write-Host ""
    $i = 1
    foreach ($line in $lines) {
        $parts = $line -split '\s+'
        $tipo     = $parts[0]
        $comment  = if ($parts.Count -ge 3) { $parts[2] } else { "(sin comentario)" }
        Write-Host "  " -NoNewline; Write-Host "[$i]" -ForegroundColor Cyan -NoNewline; Write-Host " $tipo  $comment"
        $i++
    }
    Write-Host ""
}

function Remove-AuthorizedKey {
    Write-Separator
    Write-Host "=== ELIMINAR CLAVE AUTORIZADA ===" -ForegroundColor White
    Write-Separator
    Write-Host ""

    $defaultUser = $env:USERNAME
    msg_input "Usuario [Enter = $defaultUser]: "
    $usuario = Read-Host
    if ([string]::IsNullOrEmpty($usuario)) { $usuario = $defaultUser }

    $authKeys = "$(Get-UserSshDir $usuario)\authorized_keys"
    if (-not (Test-Path $authKeys)) { msg_info "No hay claves autorizadas para '$usuario'"; return }

    $claves = Get-Content $authKeys | Where-Object { $_ -and -not $_.StartsWith('#') }
    if ($claves.Count -eq 0) { msg_info "No hay claves autorizadas para '$usuario'"; return }

    Write-Host ""
    for ($i = 0; $i -lt $claves.Count; $i++) {
        $parts = ($claves[$i]) -split '\s+'
        $tipo  = $parts[0]
        $comment = if ($parts.Count -ge 3) { $parts[2] } else { "(sin comentario)" }
        Write-Host "  " -NoNewline; Write-Host "[$($i+1)]" -ForegroundColor Cyan -NoNewline; Write-Host " $tipo  $comment"
    }
    Write-Host ""

    msg_input "Numero de clave a eliminar [0 = cancelar]: "
    $num = Read-Host
    if ($num -eq '0' -or [string]::IsNullOrEmpty($num)) { msg_alert "Operacion cancelada"; return }
    if (-not ($num -match '^\d+$') -or [int]$num -lt 1 -or [int]$num -gt $claves.Count) {
        msg_error "Numero invalido"; return
    }

    $claveAEliminar = $claves[[int]$num - 1]
    $newContent = Get-Content $authKeys | Where-Object { $_ -ne $claveAEliminar }
    $newContent | Set-Content $authKeys -Encoding UTF8
    msg_success "Clave eliminada"
    Write-Host ""
}

function Show-KeysMenu {
    while ($true) {
        Clear-Host; Write-Separator; Write-Host ""
        Write-Host "--- GESTION DE CLAVES SSH ---" -ForegroundColor White; Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "1." -ForegroundColor Green -NoNewline; Write-Host " Generar par de claves"
        Write-Host "  " -NoNewline; Write-Host "2." -ForegroundColor Green -NoNewline; Write-Host " Agregar clave autorizada"
        Write-Host "  " -NoNewline; Write-Host "3." -ForegroundColor Green -NoNewline; Write-Host " Listar claves autorizadas"
        Write-Host "  " -NoNewline; Write-Host "4." -ForegroundColor Green -NoNewline; Write-Host " Eliminar clave autorizada"
        Write-Host "  " -NoNewline; Write-Host "5." -ForegroundColor Green -NoNewline; Write-Host " Volver"
        Write-Host ""; Write-Separator; Write-Host ""
        msg_input "Seleccione una opcion: "
        $op = Read-Host; Write-Host ""
        switch ($op) {
            '1' { New-SshKeyPair }
            '2' { Add-AuthorizedKey }
            '3' { Get-AuthorizedKeys }
            '4' { Remove-AuthorizedKey }
            '5' { return }
            default { msg_error "Opcion invalida" }
        }
        Write-Host ""; Read-Host "Presione ENTER para continuar"
    }
}

# =============================================================================
# CONTROL DEL SERVICIO
# =============================================================================

function Invoke-ReloadService {
    msg_process "Validando configuracion..."
    $testResult = & sshd.exe -t 2>&1
    if ($LASTEXITCODE -eq 0) {
        msg_success "Configuracion valida"
        msg_process "Recargando servicio $SSH_SERVICE..."
        try {
            Restart-Service -Name $SSH_SERVICE -Force -ErrorAction Stop
            msg_success "Servicio recargado correctamente"
        } catch {
            # -- DEBUG --
            msg_alert "Error del sistema al recargar $SSH_SERVICE : $_"
            msg_error "No se pudo recargar el servicio: $_"
            return $false
        }
    } else {
        # -- DEBUG --
        msg_alert "Detalle del error sshd -t: $testResult"
        msg_error "Configuracion invalida - no se recargara el servicio"
        return $false
    }
    return $true
}

function Invoke-ServiceControl {
    param([string]$action)
    switch ($action) {
        'start' {
            msg_process "Iniciando $SSH_SERVICE..."
            try {
                Start-Service -Name $SSH_SERVICE -ErrorAction Stop
                msg_success "Servicio iniciado"
            } catch {
                # -- DEBUG --
                msg_alert "Error del sistema al iniciar $SSH_SERVICE : $_"
                msg_error "No se pudo iniciar: $_"
            }
        }
        'stop' {
            msg_alert "Detener SSH desconectara sesiones activas."
            msg_input "Confirmar? (s/N): "
            $c = Read-Host
            if ($c -notmatch '^[sS]$') { msg_alert "Cancelado"; return }
            try {
                Stop-Service -Name $SSH_SERVICE -Force -ErrorAction Stop
                msg_success "Servicio detenido"
            } catch {
                # -- DEBUG --
                msg_alert "Error del sistema al detener $SSH_SERVICE : $_"
                msg_error "No se pudo detener: $_"
            }
        }
        'restart' {
            msg_process "Reiniciando $SSH_SERVICE..."
            try {
                Restart-Service -Name $SSH_SERVICE -Force -ErrorAction Stop
                msg_success "Servicio reiniciado"
            } catch {
                # -- DEBUG --
                msg_alert "Error del sistema al reiniciar $SSH_SERVICE : $_"
                msg_error "No se pudo reiniciar: $_"
            }
        }
        'enable' {
            try {
                Set-Service -Name $SSH_SERVICE -StartupType Automatic -ErrorAction Stop
                msg_success "Servicio habilitado en el arranque"
            } catch {
                # -- DEBUG --
                msg_alert "Error del sistema al habilitar $SSH_SERVICE : $_"
                msg_error "No se pudo habilitar: $_"
            }
        }
        'disable' {
            msg_alert "Deshabilitar SSH impedira que arranque automaticamente."
            msg_input "Confirmar? (s/N): "
            $c = Read-Host
            if ($c -notmatch '^[sS]$') { msg_alert "Cancelado"; return }
            try {
                Set-Service -Name $SSH_SERVICE -StartupType Disabled -ErrorAction Stop
                msg_success "Servicio deshabilitado"
            } catch {
                # -- DEBUG --
                msg_alert "Error del sistema al deshabilitar $SSH_SERVICE : $_"
                msg_error "No se pudo deshabilitar: $_"
            }
        }
        'reload' { Invoke-ReloadService }
    }
}

function Show-ServiceMenu {
    while ($true) {
        Clear-Host; Write-Separator; Write-Host ""
        Write-Host "--- CONTROL DEL SERVICIO SSH ---" -ForegroundColor White; Write-Host ""
        $svc    = Get-Service -Name $SSH_SERVICE -ErrorAction SilentlyContinue
        $estado = if ($svc -and $svc.Status -eq 'Running') { 'ACTIVO' } else { 'INACTIVO' }
        $colorE = if ($svc -and $svc.Status -eq 'Running') { 'Green'  } else { 'Red'     }
        $startType  = if ($svc) { (Get-Service -Name $SSH_SERVICE).StartType } else { 'Desconocido' }
        $arrq       = if ($startType -eq 'Automatic') { 'HABILITADO'   } else { 'DESHABILITADO' }
        $arrqColor  = if ($startType -eq 'Automatic') { 'Green'        } else { 'Yellow'       }
        Write-Host "  Estado: " -NoNewline; Write-Host $estado -ForegroundColor $colorE -NoNewline
        Write-Host "  |  Arranque: " -NoNewline; Write-Host $arrq -ForegroundColor $arrqColor
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "1." -ForegroundColor Green -NoNewline; Write-Host " Iniciar"
        Write-Host "  " -NoNewline; Write-Host "2." -ForegroundColor Green -NoNewline; Write-Host " Detener"
        Write-Host "  " -NoNewline; Write-Host "3." -ForegroundColor Green -NoNewline; Write-Host " Reiniciar"
        Write-Host "  " -NoNewline; Write-Host "4." -ForegroundColor Green -NoNewline; Write-Host " Recargar configuracion"
        Write-Host "  " -NoNewline; Write-Host "5." -ForegroundColor Green -NoNewline; Write-Host " Habilitar en arranque"
        Write-Host "  " -NoNewline; Write-Host "6." -ForegroundColor Green -NoNewline; Write-Host " Deshabilitar en arranque"
        Write-Host "  " -NoNewline; Write-Host "7." -ForegroundColor Green -NoNewline; Write-Host " Volver"
        Write-Host ""; Write-Separator; Write-Host ""
        msg_input "Seleccione una opcion: "
        $op = Read-Host; Write-Host ""
        switch ($op) {
            '1' { Invoke-ServiceControl start }
            '2' { Invoke-ServiceControl stop }
            '3' { Invoke-ServiceControl restart }
            '4' { Invoke-ServiceControl reload }
            '5' { Invoke-ServiceControl enable }
            '6' { Invoke-ServiceControl disable }
            '7' { return }
            default { msg_error "Opcion invalida" }
        }
        Write-Host ""; Read-Host "Presione ENTER para continuar"
    }
}

# =============================================================================
# MONITOR
# =============================================================================

function Monitor-Ssh {
    Clear-Host; Write-Separator; Write-Host ""
    Write-Host "--- MONITOR SSH ---" -ForegroundColor White; Write-Host ""

    # Estado del servicio
    Start-Sleep -Seconds 1
    Write-Host "Estado del servicio:" -ForegroundColor White; Write-Host ""
    $svc = Get-Service -Name $SSH_SERVICE -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        $svcWmi = Get-WmiObject -Class Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
        Write-Host "  Estado:  " -NoNewline; Write-Host "ACTIVO" -ForegroundColor Green
        if ($svcWmi) { Write-Host "  PID:     $($svcWmi.ProcessId)" }
        # Puerto activo
        $sshConn = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $svcWmi.ProcessId }
        $portActivo = $sshConn | Select-Object -First 1 -ExpandProperty LocalPort
        if ($portActivo) { Write-Host "  Puerto:  $portActivo" }
    } else {
        Write-Host "  Estado:  " -NoNewline; Write-Host "INACTIVO" -ForegroundColor Red
        Write-Host ""
        msg_alert "El servicio SSH no esta corriendo"
        Write-Host ""; Write-Separator; return
    }

    # Conexiones activas
    Start-Sleep -Seconds 1; Write-Host ""
    Write-Host "Conexiones SSH activas:" -ForegroundColor White; Write-Host ""
    try {
        $portActivo = Read-SshdDirective "Port"
        $portMonitor = if ($portActivo) { [int]$portActivo } else { 22 }
        $conns = Get-NetTCPConnection -State Established -LocalPort $portMonitor -ErrorAction SilentlyContinue
        if ($conns) {
            msg_info "Conexiones establecidas: $($conns.Count)"; Write-Host ""
            foreach ($c in $conns) {
                Write-Host "  Local: $($c.LocalAddress):$($c.LocalPort)   Remoto: $($c.RemoteAddress):$($c.RemotePort)"
            }
        } else {
            msg_info "Sin conexiones activas"
        }
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al obtener conexiones TCP: $_"
        msg_info "Sin conexiones activas"
    }

    # Sesiones activas (equivalente a 'w')
    Start-Sleep -Seconds 1; Write-Host ""
    Write-Host "Sesiones de usuario activas:" -ForegroundColor White; Write-Host ""
    try {
        $sessions = query session 2>&1 | Select-Object -Skip 1 | Where-Object { $_ -match '\S' }
        if ($sessions) {
            foreach ($s in $sessions) { Write-Host "  $s" }
        } else {
            msg_info "Sin sesiones detectadas"
        }
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al ejecutar 'query session': $_"
        msg_info "Sin sesiones detectadas"
    }

    # Ultimos accesos (equivalente a 'last')
    Start-Sleep -Seconds 1; Write-Host ""
    Write-Host "Ultimos 10 accesos (Event Log):" -ForegroundColor White; Write-Host ""
    try {
        $events = Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 10 -ErrorAction Stop
        foreach ($ev in $events) {
            $msg = $ev.Message.Split([Environment]::NewLine)[0]
            if ($ev.Message -match 'Accepted|opened') {
                Write-Host "  $($ev.TimeCreated) $msg" -ForegroundColor Green
            } elseif ($ev.Message -match 'Failed|Invalid|error|disconnect') {
                Write-Host "  $($ev.TimeCreated) $msg" -ForegroundColor Red
            } else {
                Write-Host "  $($ev.TimeCreated) $msg"
            }
        }
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al leer OpenSSH/Operational log: $_"
        msg_info "Log OpenSSH/Operational no disponible"
    }

    # Intentos fallidos (ultimas 24h)
    Start-Sleep -Seconds 1; Write-Host ""
    Write-Host "Intentos de acceso fallidos (ultimas 24h):" -ForegroundColor White; Write-Host ""
    try {
        $since = (Get-Date).AddHours(-24)
        $failures = Get-WinEvent -LogName 'OpenSSH/Operational' -ErrorAction Stop |
            Where-Object { $_.TimeCreated -ge $since -and $_.Message -match 'Failed|Invalid|error' }
        if ($failures.Count -gt 0) {
            Write-Host "  " -NoNewline; Write-Host "$($failures.Count) intentos fallidos en las ultimas 24h" -ForegroundColor Red
            Write-Host ""
            msg_info "Eventos fallidos recientes:"
            $failures | Select-Object -First 5 | ForEach-Object {
                Write-Host "    $($_.TimeCreated) $($_.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Yellow
            }
        } else {
            msg_success "Sin intentos fallidos en las ultimas 24h"
        }
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al buscar intentos fallidos: $_"
        msg_info "No se pudo acceder al log de intentos fallidos"
    }

    # Logs recientes
    Start-Sleep -Seconds 1; Write-Host ""
    Write-Separator
    Write-Host "Actividad reciente (ultimas 20 entradas):" -ForegroundColor White; Write-Host ""
    try {
        $recent = Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 20 -ErrorAction Stop
        foreach ($ev in $recent) {
            $msg = $ev.Message.Split([Environment]::NewLine)[0]
            if ($ev.Message -match 'Accepted|opened') {
                Write-Host "  $msg" -ForegroundColor Green
            } elseif ($ev.Message -match 'Failed|Invalid|error|disconnect') {
                Write-Host "  $msg" -ForegroundColor Red
            } else {
                Write-Host "  $msg"
            }
        }
    } catch {
        # -- DEBUG --
        msg_alert "Error del sistema al leer actividad reciente SSH: $_"
        msg_info "Log no disponible"
    }

    Write-Host ""; Write-Separator; Write-Host ""
}

# =============================================================================
# VER Y RECONFIGURAR CONFIGURACION ACTUAL
# =============================================================================

function Show-Configuration {
    Clear-Host; Write-Separator; Write-Host ""
    Write-Host "--- CONFIGURACION SSH ACTUAL ---" -ForegroundColor White; Write-Host ""

    if (-not (Test-Path $SSHD_CONFIG)) {
        msg_error "No se encuentra $SSHD_CONFIG"
        return
    }

    Start-Sleep -Seconds 1
    Write-Host "Directivas activas en $SSHD_CONFIG :" -ForegroundColor White; Write-Host ""

    $directivas = @(
        "Port","ListenAddress","Protocol","PermitRootLogin","PasswordAuthentication",
        "PubkeyAuthentication","PermitEmptyPasswords","ChallengeResponseAuthentication",
        "MaxAuthTries","MaxSessions","LoginGraceTime","ClientAliveInterval","ClientAliveCountMax",
        "X11Forwarding","AllowTcpForwarding","AllowAgentForwarding","Banner","LogLevel","SyslogFacility","UsePAM"
    )
    foreach ($d in $directivas) {
        $val = Read-SshdDirective $d
        if ($val) {
            Write-Host ("  " + $d.PadRight(32)) -NoNewline -ForegroundColor Cyan
            Write-Host $val
        }
    }

    # Mostrar hardening conf si existe
    if (Test-Path $SSHD_HARDENING_CONF) {
        Write-Host ""
        Write-Host "Perfil de hardening activo ($SSHD_HARDENING_CONF):" -ForegroundColor White; Write-Host ""
        Get-Content $SSHD_HARDENING_CONF | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
            Write-Host "  $_" -ForegroundColor Magenta
        }
    }

    Write-Host ""
    Write-Separator; Write-Host ""
    msg_input "Desea reconfigurar SSH ahora? (s/N): "
    $resp = Read-Host
    if ($resp -match '^[sS]$') { Invoke-ConfigureSsh }
}

# =============================================================================
# AYUDA
# =============================================================================

function Show-Help {
    Write-Host @"

SSH Manager - OpenSSH SSH Server (Windows)

USO INTERACTIVO:
  .\ssh_manager.ps1

USO POR PARAMETROS:
  .\ssh_manager.ps1 [COMANDO] [OPCIONES]

COMANDOS:
  install                          Instala/verifica OpenSSH Server (idempotente)
  configure                        Configura sshd de forma interactiva
  harden                           Aplica perfil de hardening recomendado
  firewall [--port P] [--iface I]  Configura firewall para SSH
  status                           Monitor: estado, conexiones, logs
  show                             Muestra configuracion actual
  keys                             Menu de gestion de claves
  start | stop | restart           Control del servicio
  reload                           Recarga configuracion
  enable | disable                 Habilita/deshabilita en el arranque
  menu                             Abre el menu interactivo (por defecto)

  -h, --help                       Muestra esta ayuda

EJEMPLOS:
  .\ssh_manager.ps1 install
  .\ssh_manager.ps1 configure
  .\ssh_manager.ps1 harden
  .\ssh_manager.ps1 firewall --port 2222 --iface Ethernet
  .\ssh_manager.ps1 status
  .\ssh_manager.ps1 restart
"@
}

# =============================================================================
# MENU PRINCIPAL
# =============================================================================

function Show-Menu {
    while ($true) {
        Clear-Host; Start-Sleep -Seconds 1; Write-Separator; Write-Host ""
        Write-Host "--- SSH MANAGER ---" -ForegroundColor White; Write-Host ""

        $svc    = Get-Service -Name $SSH_SERVICE -ErrorAction SilentlyContinue
        $estado = if ($svc -and $svc.Status -eq 'Running') { 'ACTIVO' } else { 'INACTIVO' }
        $colorE = if ($svc -and $svc.Status -eq 'Running') { 'Green'  } else { 'Red'     }
        Write-Host "  Servicio: " -NoNewline; Write-Host $estado -ForegroundColor $colorE
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "1." -ForegroundColor Green -NoNewline; Write-Host "  Instalar/verificar OpenSSH SSH Server"
        Write-Host "  " -NoNewline; Write-Host "2." -ForegroundColor Green -NoNewline; Write-Host "  Configurar SSH"
        Write-Host "  " -NoNewline; Write-Host "3." -ForegroundColor Green -NoNewline; Write-Host "  Aplicar Hardening"
        Write-Host "  " -NoNewline; Write-Host "4." -ForegroundColor Green -NoNewline; Write-Host "  Configurar Firewall"
        Write-Host "  " -NoNewline; Write-Host "5." -ForegroundColor Green -NoNewline; Write-Host "  Gestion de Claves"
        Write-Host "  " -NoNewline; Write-Host "6." -ForegroundColor Green -NoNewline; Write-Host "  Monitor / Estado"
        Write-Host "  " -NoNewline; Write-Host "7." -ForegroundColor Green -NoNewline; Write-Host "  Ver y reconfigurar configuracion actual"
        Write-Host "  " -NoNewline; Write-Host "8." -ForegroundColor Green -NoNewline; Write-Host "  Control del servicio"
        Write-Host "  " -NoNewline; Write-Host "9." -ForegroundColor Green -NoNewline; Write-Host "  Salir"
        Write-Host ""; Write-Separator; Write-Host ""
        msg_input "Seleccione una opcion: "
        $opcion = Read-Host
        Start-Sleep -Seconds 1

        switch ($opcion) {
            '1' { Install-SshServer }
            '2' { Invoke-ConfigureSsh }
            '3' { Apply-Hardening }
            '4' {
                Write-Host ""
                msg_process "Interfaces disponibles:"; Write-Host ""
                Get-NetworkInterfaces | ForEach-Object { Write-Host $_ }; Write-Host ""
                msg_input "Interfaz [Enter = perfil Any]: "; $ifaceFw = Read-Host
                msg_input "Puerto [Enter = 22]: ";           $portFw  = Read-Host
                $fwPort  = if ($portFw)  { [int]$portFw } else { 22 }
                $fwIface = if ($ifaceFw) { $ifaceFw     } else { "" }
                Set-SshFirewall $fwPort $fwIface
            }
            '5' { Show-KeysMenu }
            '6' { Monitor-Ssh }
            '7' { Show-Configuration }
            '8' { Show-ServiceMenu }
            '9' { msg_info "Saliendo..."; Start-Sleep -Seconds 1; exit 0 }
            default { msg_error "Opcion invalida" }
        }

        Write-Host ""; Read-Host "Presione ENTER para continuar"
    }
}

# =============================================================================
# ROUTER DE COMANDOS
# =============================================================================

function Main {
    param([string[]]$CmdArgs)

    if ($CmdArgs.Count -eq 0) { Show-Menu; return }

    $command = $CmdArgs[0]
    $rest    = if ($CmdArgs.Count -gt 1) { $CmdArgs[1..($CmdArgs.Count-1)] } else { @() }

    # Helper local para --key value
    function Parse-SshArgs {
        param([string[]]$argList, [string[]]$validKeys)
        $result = @{}
        for ($i = 0; $i -lt $argList.Count; $i++) {
            $key = $argList[$i] -replace '^--',''
            if ($key -notin $validKeys) { msg_error "Opcion desconocida: $($argList[$i])"; exit 1 }
            if ($i+1 -ge $argList.Count) { msg_error "Falta valor para --$key"; exit 1 }
            $result[$key] = $argList[$i+1]; $i++
        }
        return $result
    }

    switch ($command) {
        { $_ -in '-h','--help' } { Show-Help }

        'install'   { Install-SshServer }
        'configure' { Invoke-ConfigureSsh }
        'harden'    { Apply-Hardening }

        'firewall' {
            $opts = Parse-SshArgs $rest @('port','iface')
            Set-SshFirewall (if ($opts['port']) { [int]$opts['port'] } else { 22 }) (if ($opts['iface']) { $opts['iface'] } else { "" })
        }

        'status'  { Monitor-Ssh }
        'show'    { Show-Configuration }
        'keys'    { Show-KeysMenu }

        'start'   { Invoke-ServiceControl start }
        'stop'    { Invoke-ServiceControl stop }
        'restart' { Invoke-ServiceControl restart }
        'reload'  { Invoke-ServiceControl reload }
        'enable'  { Invoke-ServiceControl enable }
        'disable' { Invoke-ServiceControl disable }

        'menu' { Show-Menu }

        default {
            msg_error "Comando desconocido: $command"
            Show-Help
            exit 1
        }
    }
}

Main $args