# =============================================================================
# ssl_lib/ssl_iis.ps1 — SSL/TLS para IIS (HTTP + redirect)
#
# IIS usa el Certificate Store directamente vía thumbprint.
# No necesita archivos .crt/.key — usa el certificado del Store.
# El redirect HTTP→HTTPS se implementa con URL Rewrite Module.
# =============================================================================
 
# ─────────────────────────────────────────────────────────────────────────────
# _ssl_iis_leer_puerto_http  (interna)
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_iis_leer_puerto_http {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $binding = Get-WebBinding "Default Web Site" -Protocol "http" `
               -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($binding) {
        $p = ($binding.bindingInformation -split ':')[1]
        if ($p -match '^\d+$') { return [int]$p }
    }
    return 80
}
 
# ─────────────────────────────────────────────────────────────────────────────
# _ssl_iis_instalar_url_rewrite  (interna)
# Instala URL Rewrite Module si no está presente (necesario para redirect).
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_iis_instalar_url_rewrite {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
 
    # Verificar si ya está instalado
    $modulos = Get-WebConfiguration "/system.webServer/globalModules/add" `
               -ErrorAction SilentlyContinue
    if ($modulos | Where-Object { $_.name -match "RewriteModule" }) {
        msg_info "URL Rewrite Module ya está instalado"
        return $true
    }
 
    msg_alert "URL Rewrite Module no encontrado — instalando via choco..."
    & choco install urlrewrite -y 2>&1 | Out-Null
 
    if ($LASTEXITCODE -eq 0) {
        msg_success "URL Rewrite Module instalado"
        return $true
    }
 
    msg_alert "choco falló — intentando descarga directa..."
    $urlRewriteUrl = "https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi"
    $msiPath = "$env:TEMP\urlrewrite.msi"
    try {
        Invoke-WebRequest -Uri $urlRewriteUrl -OutFile $msiPath -ErrorAction Stop
        Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart" `
            -Wait -ErrorAction Stop
        msg_success "URL Rewrite Module instalado desde Microsoft"
        return $true
    }
    catch {
        msg_alert "No se pudo instalar URL Rewrite — el redirect HTTP→HTTPS no estará disponible"
        msg_info  "Instale manualmente: choco install urlrewrite -y"
        return $false
    }
}
 
# ─────────────────────────────────────────────────────────────────────────────
# _ssl_iis_configurar_redirect  (interna)
# Configura redirect HTTP→HTTPS via URL Rewrite en web.config del sitio.
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_iis_configurar_redirect {
    param([int]$HttpsPort)
 
    $webConfig = "C:\inetpub\wwwroot\web.config"
 
    msg_process "Configurando redirect HTTP→HTTPS en web.config..."
 
    # Leer contenido existente o crear base
    $existente = ""
    if (Test-Path $webConfig) {
        $existente = Get-Content $webConfig -Raw -ErrorAction SilentlyContinue
    }
 
    # Construir regla de redirect
    $redirectRule = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <!-- ssl_manager: HTTP a HTTPS redirect -->
        <rule name="HTTP to HTTPS" stopProcessing="true">
          <match url="(.*)" />
          <conditions>
            <add input="{HTTPS}" pattern="^OFF$" />
          </conditions>
          <action type="Redirect"
                  url="https://{SERVER_NAME}:${HttpsPort}/{R:1}"
                  redirectType="Permanent" />
        </rule>
        <!-- /ssl_manager -->
      </rules>
    </rewrite>
    <httpProtocol>
      <customHeaders>
        <add name="Strict-Transport-Security"
             value="max-age=31536000; includeSubDomains" />
        <add name="X-Frame-Options" value="SAMEORIGIN" />
        <add name="X-Content-Type-Options" value="nosniff" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
"@
 
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($webConfig, $redirectRule, $utf8NoBom)
        msg_success "web.config con redirect escrito: $webConfig"
        return $true
    }
    catch {
        msg_error "Error al escribir web.config: $($_.Exception.Message)"
        return $false
    }
}
 
# ─────────────────────────────────────────────────────────────────────────────
# ssl_configurar_iis  (pública)
# Flujo completo SSL para IIS:
#   datos cert → puerto HTTPS → generar cert → binding HTTPS → redirect → restart
# ─────────────────────────────────────────────────────────────────────────────
function ssl_configurar_iis {
    Write-Separator
    msg_info "Configuración SSL/TLS — IIS"
    Write-Separator
    Write-Host ""
 
    Import-Module WebAdministration -ErrorAction SilentlyContinue
 
    $httpPort = _ssl_iis_leer_puerto_http
 
    msg_info "PASO 1/6 — Datos del certificado"
    ssl_recopilar_datos_certificado "IIS"
    Write-Host ""
 
    msg_info "PASO 2/6 — Puerto HTTPS"
    $httpsPort = 0
    ssl_seleccionar_puerto_https "IIS" $httpPort ([ref]$httpsPort)
    Write-Host ""
 
    msg_input "¿Confirmar configuración SSL para IIS? [S/N]: "
    $conf = Read-Host
    if ($conf -notmatch '^[SsYy]') { msg_info "Cancelado"; return }
    Write-Host ""
 
    msg_info "PASO 3/6 — Generar certificado"
    # IIS usa el Store directamente — no necesita PEM
    if (-not (ssl_generar_certificado $script:SSL_DIR_IIS "IIS" $false)) { return }
    Write-Host ""
 
    msg_info "PASO 4/6 — Configurar binding HTTPS en IIS"
    try {
        # Eliminar binding HTTPS anterior si existe
        Get-WebBinding "Default Web Site" -Protocol "https" `
            -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
 
        # Crear nuevo binding HTTPS
        New-WebBinding -Name "Default Web Site" `
            -Protocol "https" `
            -Port $httpsPort `
            -SslFlags 0 `
            -ErrorAction Stop | Out-Null
 
        # Asignar certificado al binding via thumbprint
        # Limpiar SslBindings huerfanos primero
        Get-ChildItem "IIS:\SslBindings" -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.PSPath -ErrorAction SilentlyContinue }
 
        $cert = Get-Item "Cert:\LocalMachine\My\$($script:SSL_THUMBPRINT)" -ErrorAction Stop
        try {
            $binding = Get-WebBinding -Name "Default Web Site" -Protocol "https" `
                       -Port $httpsPort -ErrorAction SilentlyContinue
            if ($binding) {
                $binding.AddSslCertificate($script:SSL_THUMBPRINT, "MY")
                msg_success "Binding HTTPS configurado via AddSslCertificate en puerto ${httpsPort}/tcp"
            } else {
                $cert | New-Item "IIS:\SslBindings.0.0.0!${httpsPort}" -ErrorAction Stop | Out-Null
                msg_success "Binding HTTPS configurado via New-Item en puerto ${httpsPort}/tcp"
            }
        } catch {
            msg_error "Error al asignar certificado: $_"
            return
        }
    }
    catch {
        msg_error "Error al configurar binding HTTPS: $($_.Exception.Message)"
        return
    }
    Write-Host ""
 
    msg_info "PASO 5/6 — Configurar redirect HTTP→HTTPS"
    $urlRewriteOk = _ssl_iis_instalar_url_rewrite
    if ($urlRewriteOk) {
        _ssl_iis_configurar_redirect $httpsPort | Out-Null
    }
    Write-Host ""
 
    msg_info "PASO 6/6 — Reiniciar IIS y verificar"
    try {
        Restart-Service W3SVC -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        msg_success "IIS reiniciado"
    }
    catch {
        msg_error "Error al reiniciar IIS: $($_.Exception.Message)"
        return
    }
 
    ssl_abrir_firewall $httpsPort "IIS"
 
    # Verificar respuesta HTTPS
    $resp = curl.exe -sk -o NUL -w "%{http_code}" `
            "https://localhost:${httpsPort}" 2>$null
    if ($resp -match '^(200|301|302|400|404)$') {
        msg_success "HTTPS responde: HTTP $resp"
    } else {
        msg_alert "HTTPS devolvió $resp — verifique: curl.exe -kv https://localhost:${httpsPort}"
    }
 
    Write-Separator
    msg_success "SSL/TLS configurado en IIS"
    Write-Separator
    Write-Host ""
    Write-Host "    Thumbprint : $($script:SSL_THUMBPRINT)"
    Write-Host "    HTTP  :${httpPort}  → redirect HTTPS"
    Write-Host "    HTTPS :${httpsPort}  (activo)"
    Write-Host ""
 
    # Exportar para actualizar index.html desde el hook
    $script:_SSL_LAST_HTTP_PORT  = $httpPort
    $script:_SSL_LAST_HTTPS_PORT = $httpsPort
}
 
# ─────────────────────────────────────────────────────────────────────────────
# ssl_iis_actualizar_puertos  (pública)
# Actualiza los puertos HTTP/HTTPS cuando el usuario los cambia desde ws_config.
# ─────────────────────────────────────────────────────────────────────────────
function ssl_iis_actualizar_puertos {
    param([int]$HttpPort, [int]$HttpsPort)
 
    msg_info "Actualizando puertos IIS SSL: HTTP=${HttpPort} HTTPS=${HttpsPort}"
 
    Import-Module WebAdministration -ErrorAction SilentlyContinue
 
    # 1. Actualizar binding HTTP (solo HTTP, preservar nada más)
    Get-WebBinding -Name "Default Web Site" -Protocol "http" `
        -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
    New-WebBinding -Name "Default Web Site" -Protocol "http" -Port $HttpPort | Out-Null
    msg_success "Binding HTTP actualizado: ${HttpPort}/tcp"
 
    # 2. Eliminar binding HTTPS anterior
    Get-WebBinding -Name "Default Web Site" -Protocol "https" `
        -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
 
    # 3. Limpiar SslBindings huerfanos (evita IndexOutOfRange en New-Item)
    Get-ChildItem "IIS:\SslBindings" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.PSPath -ErrorAction SilentlyContinue }
 
    # 4. Crear nuevo binding HTTPS
    New-WebBinding -Name "Default Web Site" `
        -Protocol "https" -Port $HttpsPort -SslFlags 0 | Out-Null
    msg_success "Binding HTTPS creado: ${HttpsPort}/tcp"
 
    # 5. Asignar certificado — buscar thumbprint en el Store si no está en memoria
    $thumbprint = $script:SSL_THUMBPRINT
    if ([string]::IsNullOrEmpty($thumbprint)) {
        # Buscar cert por CN si el thumbprint no está en memoria
        $cert = Get-ChildItem "Cert:\LocalMachine\My" |
                Where-Object { $_.Subject -match "CN=" } |
                Sort-Object NotAfter -Descending |
                Select-Object -First 1
        if ($cert) { $thumbprint = $cert.Thumbprint }
    }
 
    if (-not [string]::IsNullOrEmpty($thumbprint)) {
        $cert = Get-Item "Cert:\LocalMachine\My\$thumbprint" -ErrorAction SilentlyContinue
        if ($cert) {
            try {
                # Crear SslBinding de forma segura
                $binding = Get-WebBinding -Name "Default Web Site" -Protocol "https" `
                           -Port $HttpsPort -ErrorAction SilentlyContinue
                if ($binding) {
                    $binding.AddSslCertificate($thumbprint, "MY")
                    msg_success "Certificado asignado al binding HTTPS"
                }
            } catch {
                msg_alert "AddSslCertificate fallo: $_ — intentando via New-Item"
                try {
                    $cert | New-Item "IIS:\SslBindings.0.0.0!${HttpsPort}" `
                            -ErrorAction Stop | Out-Null
                    msg_success "Certificado asignado via New-Item"
                } catch {
                    msg_error "No se pudo asignar certificado: $_"
                }
            }
        }
    } else {
        msg_alert "Thumbprint no disponible — el binding HTTPS no tendra certificado"
        msg_info  "Reconfigure SSL desde ssl_manager.ps1"
    }
 
    # 6. Actualizar redirect y firewall
    # NO reiniciar aquí — ws_config.ps1 hace el restart único en PASO 4
    _ssl_iis_configurar_redirect $HttpsPort | Out-Null
    ssl_abrir_firewall $HttpsPort "IIS"
    msg_success "Puertos IIS SSL actualizados: HTTP=${HttpPort} HTTPS=${HttpsPort}"
    msg_info  "Pendiente restart — se ejecutara en PASO 4"
}
 
# ─────────────────────────────────────────────────────────────────────────────
# ssl_desactivar_iis  (pública)
# ─────────────────────────────────────────────────────────────────────────────
function ssl_desactivar_iis {
    msg_alert "Desactivando SSL en IIS..."
    Import-Module WebAdministration -ErrorAction SilentlyContinue
 
    Get-WebBinding "Default Web Site" -Protocol "https" `
        -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
 
    # Limpiar SslBindings
    Get-ChildItem "IIS:\SslBindings" -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
 
    # Eliminar redirect del web.config
    $webConfig = "C:\inetpub\wwwroot\web.config"
    if (Test-Path $webConfig) {
        $content = Get-Content $webConfig -Raw
        $content = $content -replace '(?s)<!-- ssl_manager: HTTP a HTTPS redirect -->.*?<!-- /ssl_manager -->', ''
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($webConfig, $content, $utf8NoBom)
    }
 
    Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
    msg_success "SSL desactivado en IIS"
}
 