# =============================================================================
# ssl_lib/ssl_apache.ps1 — SSL/TLS para Apache en Windows
#
# Estrategia: genera ssl-reprobados.conf en la carpeta extra/ de Apache
# con VirtualHost HTTPS y VirtualHost HTTP con redirect.
# Usa los archivos .crt y .key extraídos del PFX por openssl.
# =============================================================================

function _ssl_apache_leer_puerto_http {
    if (Test-Path $script:HTTP_CONF_APACHE) {
        $linea = Get-Content $script:HTTP_CONF_APACHE |
                 Where-Object { $_ -match '^\s*Listen\s+\d+' } |
                 Select-Object -First 1
        if ($linea) { return [int](($linea -replace '.*Listen\s+', '').Trim()) }
    }
    return 80
}

function _ssl_apache_leer_puerto_https {
    $confDir = Split-Path $script:HTTP_CONF_APACHE
    $sslConf = Join-Path $confDir "extra\ssl-reprobados.conf"
    if (Test-Path $sslConf) {
        $linea = Get-Content $sslConf |
                 Where-Object { $_ -match '^\s*Listen\s+\d+' } |
                 Select-Object -First 1
        if ($linea) { return [int](($linea -replace '.*Listen\s+', '').Trim()) }
    }
    return 443
}

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_apache_verificar_mod_ssl  (interna)
# Verifica que mod_ssl esté habilitado en httpd.conf.
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_apache_verificar_mod_ssl {
    if (-not (Test-Path $script:HTTP_CONF_APACHE)) {
        msg_error "httpd.conf no encontrado: $($script:HTTP_CONF_APACHE)"
        return $false
    }

    $bytes = [System.IO.File]::ReadAllBytes($script:HTTP_CONF_APACHE)
    $bom   = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $httpdContent = if ($bom) {
        [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    } else { [System.Text.Encoding]::UTF8.GetString($bytes) }

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $changed   = $false

    # Módulos requeridos para SSL con redirect
    $modulos = @(
        "LoadModule ssl_module modules/mod_ssl.so",
        "LoadModule rewrite_module modules/mod_rewrite.so",
        "LoadModule headers_module modules/mod_headers.so",
        "LoadModule socache_shmcb_module modules/mod_socache_shmcb.so"
    )

    foreach ($mod in $modulos) {
        $modName = ($mod -split ' ')[1]
        # Si existe pero está comentado → descomentar
        if ($httpdContent -match "(?m)^#\s*$([regex]::Escape($mod))") {
            $httpdContent = $httpdContent -replace "(?m)^#\s*($([regex]::Escape($mod)))", '$1'
            msg_success "$modName habilitado (descomentado)"
            $changed = $true
        } elseif ($httpdContent -notmatch [regex]::Escape($mod)) {
            # No existe → agregar
            $httpdContent += "`n$mod`n"
            msg_success "$modName agregado"
            $changed = $true
        } else {
            msg_info "$modName ya activo"
        }
    }

    if ($changed) {
        [System.IO.File]::WriteAllText($script:HTTP_CONF_APACHE, $httpdContent, $utf8NoBom)
        msg_success "httpd.conf actualizado con módulos SSL"
    }

    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_apache_escribir_conf  (interna)
# Genera ssl-reprobados.conf con VirtualHost HTTPS y redirect HTTP→HTTPS.
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_apache_escribir_conf {
    param([int]$HttpPort, [int]$HttpsPort)

    $confDir  = Split-Path $script:HTTP_CONF_APACHE
    $extraDir = Join-Path $confDir "extra"
    $sslConf  = Join-Path $extraDir "ssl-reprobados.conf"

    if (-not (Test-Path $extraDir)) {
        New-Item -ItemType Directory -Path $extraDir -Force | Out-Null
    }

    $certPath    = Join-Path $script:SSL_DIR_APACHE $script:SSL_CERT_FILE
    $keyPath     = Join-Path $script:SSL_DIR_APACHE $script:SSL_KEY_FILE
    $serverName  = $script:SSL_CERT_CN
    $webroot     = $script:HTTP_DIR_APACHE

    # Normalizar rutas para Apache (barras hacia adelante)
    $certPathFwd = $certPath  -replace '\\', '/'
    $keyPathFwd  = $keyPath   -replace '\\', '/'
    $webrootFwd  = $webroot   -replace '\\', '/'

    msg_process "Escribiendo ssl-reprobados.conf..."

    $contenido = @"
# ssl-reprobados.conf
# Generado por ssl_manager — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Reescribir completo al reconfigurar — no editar manualmente.

Listen ${HttpsPort}

# ── VirtualHost HTTPS ─────────────────────────────────────────────────────
<VirtualHost *:${HttpsPort}>
    ServerName ${serverName}
    DocumentRoot "${webrootFwd}"

    SSLEngine on
    SSLCertificateFile    "${certPathFwd}"
    SSLCertificateKeyFile "${keyPathFwd}"

    SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite HIGH:!aNULL:!MD5:!3DES
    SSLHonorCipherOrder on
    SSLCompression off

    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-Content-Type-Options "nosniff"
        Header always set Referrer-Policy "strict-origin-when-cross-origin"
        Header always set X-XSS-Protection "1; mode=block"
    </IfModule>

    ErrorLog  logs/ssl_error.log
    CustomLog logs/ssl_access.log combined

    <Directory "${webrootFwd}">
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
</VirtualHost>

# ── Redirect HTTP → HTTPS ─────────────────────────────────────────────────
<VirtualHost *:${HttpPort}>
    ServerName ${serverName}
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{SERVER_NAME}:${HttpsPort}`$1 [R=301,L]
</VirtualHost>
"@

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($sslConf, $contenido, $utf8NoBom)
        msg_success "ssl-reprobados.conf escrito: $sslConf"
    }
    catch {
        msg_error "Error al escribir ssl-reprobados.conf: $($_.Exception.Message)"
        return $false
    }

    # Incluir ssl-reprobados.conf desde httpd.conf si no está ya
    $httpdContent = Get-Content $script:HTTP_CONF_APACHE -Raw
    $sslConfFwd   = $sslConf -replace '\\', '/'
    if ($httpdContent -notmatch 'ssl-reprobados\.conf') {
        $httpdContent += "`nInclude `"${sslConfFwd}`"`n"
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($script:HTTP_CONF_APACHE, $httpdContent, $utf8NoBom)
        msg_success "Include ssl-reprobados.conf agregado a httpd.conf"
    }

    return $true
}

function _ssl_apache_verificar_sintaxis {
    $apacheRoot = Split-Path (Split-Path $script:HTTP_CONF_APACHE)
    $httpdExe   = Join-Path $apacheRoot "bin\httpd.exe"
    if (-not (Test-Path $httpdExe)) {
        msg_alert "httpd.exe no encontrado — sintaxis no verificada"
        return $true
    }
    msg_process "Verificando sintaxis Apache..."
    $out = & $httpdExe -t 2>&1
    if ($out -match "Syntax OK") {
        msg_success "Sintaxis: OK"
        return $true
    }
    msg_error "Error de sintaxis:"
    $out | ForEach-Object { Write-Host "    $_" }
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_configurar_apache  (pública)
# ─────────────────────────────────────────────────────────────────────────────
function ssl_configurar_apache {
    Write-Separator
    msg_info "Configuración SSL/TLS — Apache (Windows)"
    Write-Separator
    Write-Host ""

    if (-not (Test-Path $script:HTTP_CONF_APACHE)) {
        msg_error "Apache no está instalado o httpd.conf no encontrado"
        return
    }

    $httpPort = _ssl_apache_leer_puerto_http

    msg_info "PASO 1/7 — Verificar mod_ssl"
    if (-not (_ssl_apache_verificar_mod_ssl)) { return }
    Write-Host ""

    msg_info "PASO 2/7 — Datos del certificado"
    ssl_recopilar_datos_certificado "Apache"
    Write-Host ""

    msg_info "PASO 3/7 — Puerto HTTPS"
    $httpsPort = 0
    ssl_seleccionar_puerto_https "Apache" $httpPort ([ref]$httpsPort)
    Write-Host ""

    msg_input "¿Confirmar configuración SSL para Apache? [S/N]: "
    $conf = Read-Host
    if ($conf -notmatch '^[SsYy]') { msg_info "Cancelado"; return }
    Write-Host ""

    msg_info "PASO 4/7 — Generar certificado (CRT + KEY)"
    if (-not (ssl_generar_certificado $script:SSL_DIR_APACHE "Apache" $true)) { return }
    Write-Host ""

    msg_info "PASO 5/7 — Escribir ssl-reprobados.conf"
    if (-not (_ssl_apache_escribir_conf $httpPort $httpsPort)) { return }
    Write-Host ""

    msg_info "PASO 6/7 — Verificar sintaxis"
    if (-not (_ssl_apache_verificar_sintaxis)) {
        msg_error "Error de sintaxis — eliminando ssl-reprobados.conf"
        $confDir = Split-Path $script:HTTP_CONF_APACHE
        Remove-Item (Join-Path $confDir "extra\ssl-reprobados.conf") -ErrorAction SilentlyContinue
        return
    }
    Write-Host ""

    msg_info "PASO 7/7 — Reiniciar Apache"
    if (-not (http_reiniciar_servicio "apache")) {
        msg_error "Apache no levantó — verifique la configuración"
        return
    }
    Start-Sleep -Seconds 2

    ssl_abrir_firewall $httpsPort "Apache"

    $resp = curl.exe -sk -o NUL -w "%{http_code}" `
            "https://localhost:${httpsPort}" 2>$null
    if ($resp -match '^(200|301|302|400|404)$') {
        msg_success "HTTPS responde: HTTP $resp"
    } else {
        msg_alert "HTTPS devolvió $resp — verifique: curl.exe -kv https://localhost:${httpsPort}"
    }

    Write-Separator
    msg_success "SSL/TLS configurado en Apache"
    Write-Separator
    Write-Host ""
    Write-Host "    CRT     : $(Join-Path $script:SSL_DIR_APACHE $script:SSL_CERT_FILE)"
    Write-Host "    HTTP  :${httpPort}  → redirect HTTPS"
    Write-Host "    HTTPS :${httpsPort}  (activo)"
    Write-Host ""

    $script:_SSL_LAST_HTTP_PORT  = $httpPort
    $script:_SSL_LAST_HTTPS_PORT = $httpsPort
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_apache_actualizar_puertos  (pública)
# ─────────────────────────────────────────────────────────────────────────────
function ssl_apache_actualizar_puertos {
    param([int]$HttpPort, [int]$HttpsPort)
    msg_info "Actualizando puertos Apache SSL: HTTP=${HttpPort} HTTPS=${HttpsPort}"

    if ([string]::IsNullOrEmpty($script:SSL_CERT_CN)) {
        $certPath = Join-Path $script:SSL_DIR_APACHE $script:SSL_CERT_FILE
        if (Test-Path $certPath) {
            $subject = & openssl x509 -in "$certPath" -noout -subject 2>$null
            if ($subject -match 'CN\s*=\s*([^,/]+)') { $script:SSL_CERT_CN = $Matches[1].Trim() }
        }
    }

    if (-not (_ssl_apache_escribir_conf $HttpPort $HttpsPort)) { return }
    if (-not (_ssl_apache_verificar_sintaxis)) { return }
    # NO reiniciar aquí — ws_config.ps1 hace el restart único en PASO 4
    ssl_abrir_firewall $HttpsPort "Apache"
    msg_success "Puertos Apache SSL actualizados"
    msg_info  "Pendiente restart — se ejecutara en PASO 4"
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_desactivar_apache  (pública)
# ─────────────────────────────────────────────────────────────────────────────
function ssl_desactivar_apache {
    msg_alert "Desactivando SSL en Apache..."
    $confDir = Split-Path $script:HTTP_CONF_APACHE
    $sslConf = Join-Path $confDir "extra\ssl-reprobados.conf"
    $ts      = Get-Date -Format "yyyyMMdd_HHmmss"
    if (Test-Path $sslConf) {
        Rename-Item $sslConf "${sslConf}.disabled_${ts}" -ErrorAction SilentlyContinue
        msg_success "ssl-reprobados.conf desactivado"
    }
    _ssl_apache_verificar_sintaxis | Out-Null
    http_reiniciar_servicio "apache" | Out-Null
    msg_success "Apache reiniciado sin SSL"
}