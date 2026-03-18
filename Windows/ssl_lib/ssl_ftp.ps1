# =============================================================================
# ssl_lib/ssl_ftp.ps1 — FTPS para IIS FTP (Windows)
#
# IIS-FTP soporta tres modos SSL:
#   0 = Desactivado
#   1 = Permitido (el cliente puede o no usar SSL)
#   2 = Requerido (SSL obligatorio para control y datos)
#
# Estrategia:
#   1. Reutilizar el certificado de IIS (ya en el Store) o generar uno nuevo
#   2. Asignar el certificado al sitio FTP via IIS:\Sites\<FTP_SITE_NAME>
#   3. Configurar controlChannelPolicy y dataChannelPolicy
#   4. Instrucciones post-config para FileZilla (FTPS Explícito)
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_ftp_leer_estado  (interna)
# Devuelve el modo SSL actual del sitio FTP.
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_ftp_leer_estado {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $sitePath = "IIS:\Sites\$script:FTP_SITE_NAME"
    if (-not (Test-Path $sitePath)) { return -1 }

    try {
        $ctrl = (Get-ItemProperty $sitePath `
                 -Name ftpServer.security.ssl.controlChannelPolicy `
                 -ErrorAction SilentlyContinue).Value
        return [int]$ctrl
    } catch { return 0 }
}

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_ftp_asignar_certificado  (interna)
# Asigna el certificado SSL al sitio FTP por thumbprint.
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_ftp_asignar_certificado {
    param([string]$Thumbprint)

    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $sitePath = "IIS:\Sites\$script:FTP_SITE_NAME"

    msg_process "Asignando certificado al sitio FTP..."

    try {
        Set-ItemProperty $sitePath `
            -Name ftpServer.security.ssl.serverCertHash `
            -Value $Thumbprint `
            -ErrorAction Stop
        msg_success "Certificado asignado (Thumbprint: $($Thumbprint.Substring(0,16))...)"
        return $true
    } catch {
        msg_error "Error al asignar certificado: $($_.Exception.Message)"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_ftp_configurar_politica  (interna)
# Configura controlChannelPolicy y dataChannelPolicy.
# $1 = modo: 1 (Permitido) o 2 (Requerido)
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_ftp_configurar_politica {
    param([int]$Modo)

    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $sitePath = "IIS:\Sites\$script:FTP_SITE_NAME"

    $modoStr = if ($Modo -eq 2) { "Requerido (SSL obligatorio)" }
               else             { "Permitido (SSL opcional)" }
    msg_process "Configurando política SSL: $modoStr..."

    try {
        Set-ItemProperty $sitePath `
            -Name ftpServer.security.ssl.controlChannelPolicy `
            -Value $Modo -ErrorAction Stop
        Set-ItemProperty $sitePath `
            -Name ftpServer.security.ssl.dataChannelPolicy `
            -Value $Modo -ErrorAction Stop

        # allow_anon_ssl equivalente: anonymous puede conectar sin SSL
        # En IIS-FTP esto se maneja dejando el modo en 1 (Permitido)
        # o configurando una regla de autorización separada para anonymous.
        if ($Modo -eq 1) {
            msg_info "Modo Permitido: anonymous puede conectar sin SSL"
        } else {
            msg_info "Modo Requerido: todos los clientes deben usar FTPS"
        }

        msg_success "Política SSL configurada: $modoStr"
        return $true
    } catch {
        msg_error "Error al configurar política SSL: $($_.Exception.Message)"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_ftp_mostrar_instrucciones  (interna)
# Muestra instrucciones post-config para FileZilla.
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_ftp_mostrar_instrucciones {
    param([string]$ServerIp, [int]$Puerto, [int]$Modo)

    Write-Host ""
    Write-Separator
    msg_info "Instrucciones para conectar con FileZilla"
    Write-Separator
    Write-Host ""
    Write-Host "  En FileZilla → Gestor de Sitios → Nuevo Sitio:"
    Write-Host ""
    Write-Host "    Protocolo  : FTP - Protocolo de Transferencia de Archivos"
    Write-Host "    Servidor   : $ServerIp"
    Write-Host "    Puerto     : $Puerto"

    if ($Modo -eq 2) {
        Write-Host "    Cifrado    : Require explicit FTP over TLS  (FTPS explícito obligatorio)"
    } else {
        Write-Host "    Cifrado    : Use explicit FTP over TLS if available  (FTPS explícito)"
    }

    Write-Host "    Modo acceso: Normal (usuario + contraseña)"
    Write-Host ""
    Write-Host "  Al conectar, FileZilla mostrará el certificado self-signed."
    Write-Host "  Haga clic en 'Aceptar' o 'Confiar siempre en este certificado'."
    Write-Host ""
    Write-Host "  Nota: El rango de puertos pasivos debe estar abierto en el Firewall."
    Write-Host "  Rango actual: $($script:FTP_PASV_MIN)-$($script:FTP_PASV_MAX)/tcp"
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_configurar_ftp  (pública)
# Flujo completo FTPS para IIS FTP.
# ─────────────────────────────────────────────────────────────────────────────
function ssl_configurar_ftp {
    Write-Separator
    msg_info "Configuración FTPS — IIS FTP"
    Write-Separator
    Write-Host ""

    Import-Module WebAdministration -ErrorAction SilentlyContinue

    # Verificar que el sitio FTP existe
    $sitePath = "IIS:\Sites\$script:FTP_SITE_NAME"
    if (-not (Test-Path $sitePath)) {
        msg_error "Sitio FTP '$($script:FTP_SITE_NAME)' no encontrado"
        msg_info  "Instale el servidor FTP primero desde ftp_manager.ps1"
        return
    }

    # Mostrar estado actual
    $estadoActual = _ssl_ftp_leer_estado
    $estadoStr = switch ($estadoActual) {
        0       { "Desactivado" }
        1       { "Permitido (SSL opcional)" }
        2       { "Requerido (SSL obligatorio)" }
        default { "Desconocido" }
    }
    msg_info "Estado SSL actual: $estadoStr"
    Write-Host ""

    # ── Paso 1: Seleccionar o generar certificado ─────────────────────────
    msg_info "PASO 1/4 — Certificado SSL"
    Write-Host ""

    # Intentar reutilizar el cert de IIS si ya fue generado
    $thumbprint = $script:SSL_THUMBPRINT
    if ([string]::IsNullOrEmpty($thumbprint)) {
        # Buscar cert de IIS en el Store
        $certIIS = Get-ChildItem "Cert:\LocalMachine\My" |
                   Where-Object { $_.Subject -match $script:SSL_CERT_CN } |
                   Select-Object -First 1
        if ($certIIS) {
            $thumbprint = $certIIS.Thumbprint
            msg_info "Reutilizando certificado IIS existente:"
            msg_info "  CN: $($certIIS.Subject)"
            msg_info "  Thumbprint: $($thumbprint.Substring(0,16))..."
            Write-Host ""
            msg_input "¿Usar este certificado para FTP? [S/N] (N = generar nuevo): "
            $resp = Read-Host
            if ($resp -notmatch '^[SsYy]') { $thumbprint = "" }
        }
    }

    if ([string]::IsNullOrEmpty($thumbprint)) {
        msg_info "Generando nuevo certificado para FTP..."
        ssl_recopilar_datos_certificado "IIS-FTP"
        Write-Host ""
        if (-not (ssl_generar_certificado $script:SSL_DIR_FTP "IIS-FTP" $false)) { return }
        $thumbprint = $script:SSL_THUMBPRINT
    } else {
        $script:SSL_THUMBPRINT = $thumbprint
    }
    Write-Host ""

    # ── Paso 2: Seleccionar modo SSL ──────────────────────────────────────
    msg_info "PASO 2/4 — Modo SSL"
    Write-Host ""
    Write-Host "  1) Permitido  — SSL opcional (anonymous puede conectar sin SSL)"
    Write-Host "  2) Requerido  — SSL obligatorio para todos los clientes"
    Write-Host ""

    $modo = 0
    while ($true) {
        msg_input "Modo SSL [1/2]: "
        $m = Read-Host
        if ($m -eq "1") { $modo = 1; break }
        if ($m -eq "2") { $modo = 2; break }
        msg_error "Ingrese 1 o 2"
    }
    Write-Host ""

    msg_input "¿Confirmar configuración FTPS? [S/N]: "
    $conf = Read-Host
    if ($conf -notmatch '^[SsYy]') { msg_info "Cancelado"; return }
    Write-Host ""

    # ── Paso 3: Asignar certificado y configurar política ─────────────────
    msg_info "PASO 3/4 — Aplicar configuración SSL"
    if (-not (_ssl_ftp_asignar_certificado $thumbprint)) { return }
    if (-not (_ssl_ftp_configurar_politica $modo)) { return }
    Write-Host ""

    # ── Paso 4: Reiniciar FTP y verificar ─────────────────────────────────
    msg_info "PASO 4/4 — Reiniciar servicio FTP"
    try {
        Restart-Service FTPSVC -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        msg_success "Servicio FTP reiniciado"
    } catch {
        msg_error "Error al reiniciar FTPSVC: $($_.Exception.Message)"
        return
    }

    # Obtener IP del servidor para las instrucciones
    $serverIp = (Get-NetIPAddress -AddressFamily IPv4 |
                 Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } |
                 Select-Object -First 1).IPAddress
    if (-not $serverIp) { $serverIp = "IP_DEL_SERVIDOR" }

    Write-Separator
    msg_success "FTPS configurado en IIS FTP"
    Write-Separator
    Write-Host ""
    $modoStr = if ($modo -eq 2) { "Requerido (SSL obligatorio)" } else { "Permitido (SSL opcional)" }
    Write-Host "    Thumbprint : $($thumbprint.Substring(0,16))..."
    Write-Host "    Modo SSL   : $modoStr"
    Write-Host "    Puerto FTP : $($script:FTP_PORT)"
    Write-Host ""

    _ssl_ftp_mostrar_instrucciones $serverIp $script:FTP_PORT $modo
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_desactivar_ftp  (pública)
# ─────────────────────────────────────────────────────────────────────────────
function ssl_desactivar_ftp {
    msg_alert "Desactivando SSL en IIS FTP..."
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $sitePath = "IIS:\Sites\$script:FTP_SITE_NAME"

    if (-not (Test-Path $sitePath)) {
        msg_error "Sitio FTP no encontrado"
        return
    }

    Set-ItemProperty $sitePath -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty $sitePath -Name ftpServer.security.ssl.dataChannelPolicy     -Value 0
    Restart-Service FTPSVC -Force -ErrorAction SilentlyContinue
    msg_success "SSL desactivado en IIS FTP — modo: FTP estándar"
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_ftp_estado  (pública)
# Muestra el estado SSL actual del sitio FTP.
# ─────────────────────────────────────────────────────────────────────────────
function ssl_ftp_estado {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $sitePath = "IIS:\Sites\$script:FTP_SITE_NAME"

    if (-not (Test-Path $sitePath)) {
        msg_error "Sitio FTP no encontrado"
        return
    }

    $ctrl = _ssl_ftp_leer_estado
    $hash = (Get-ItemProperty $sitePath `
             -Name ftpServer.security.ssl.serverCertHash `
             -ErrorAction SilentlyContinue).Value

    Write-Separator
    msg_info "Estado FTPS — IIS FTP"
    Write-Separator
    Write-Host ""

    $modoStr = switch ($ctrl) {
        0       { "Desactivado (FTP estándar)" }
        1       { "Permitido (SSL opcional)" }
        2       { "Requerido (SSL obligatorio)" }
        default { "Desconocido ($ctrl)" }
    }
    Write-Host "    Modo SSL       : $modoStr"
    Write-Host "    Certificado    : $(if ($hash) { $hash.Substring(0,[Math]::Min(16,$hash.Length)) + '...' } else { 'No asignado' })"
    Write-Host "    Puerto FTP     : $($script:FTP_PORT)"
    Write-Host "    Pasivo         : $($script:FTP_PASV_MIN)-$($script:FTP_PASV_MAX)/tcp"
    Write-Host ""
}