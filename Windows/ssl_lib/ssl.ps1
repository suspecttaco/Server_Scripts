# =============================================================================
# ssl_lib/ssl.ps1 — Entry point SSL/TLS para Windows Server 2022
# Variables globales y funciones comunes compartidas por todos los módulos.
# Uso: . .\ssl_lib\ssl.ps1   (requiere lib/ui.ps1 cargado antes)
# =============================================================================

[CmdletBinding()]
param()

# ─────────────────────────────────────────────────────────────────────────────
# Variables globales
# ─────────────────────────────────────────────────────────────────────────────

# Directorio base donde se guardan los certificados exportados
$script:SSL_DIR_BASE    = "C:\SSL\reprobados"
$script:SSL_DIR_IIS     = "$script:SSL_DIR_BASE\iis"
$script:SSL_DIR_APACHE  = "$script:SSL_DIR_BASE\apache"
$script:SSL_DIR_NGINX   = "$script:SSL_DIR_BASE\nginx"
$script:SSL_DIR_TOMCAT  = "$script:SSL_DIR_BASE\tomcat"
$script:SSL_DIR_FTP     = "$script:SSL_DIR_BASE\ftp"

# Nombres de archivo estándar
$script:SSL_CERT_FILE   = "reprobados.crt"
$script:SSL_KEY_FILE    = "reprobados.key"
$script:SSL_PFX_FILE    = "reprobados.pfx"

# Datos del certificado (se rellenan en ssl_recopilar_datos_certificado)
$script:SSL_CERT_CN      = ""
$script:SSL_CERT_ORG     = ""
$script:SSL_CERT_OU      = ""
$script:SSL_CERT_COUNTRY = ""
$script:SSL_CERT_STATE   = ""
$script:SSL_CERT_CITY    = ""
$script:SSL_CERT_DAYS    = 365

# Thumbprint del certificado en el Certificate Store (IIS lo usa directamente)
$script:SSL_THUMBPRINT   = ""

# Contraseña del PFX (se pide al usuario)
$script:SSL_PFX_PASS     = ""

# ─────────────────────────────────────────────────────────────────────────────
# Cargar submódulos
# ─────────────────────────────────────────────────────────────────────────────
$_SSL_LIB_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

. "$_SSL_LIB_DIR\ssl_certs.ps1"
. "$_SSL_LIB_DIR\ssl_iis.ps1"
. "$_SSL_LIB_DIR\ssl_apache.ps1"
. "$_SSL_LIB_DIR\ssl_nginx.ps1"
. "$_SSL_LIB_DIR\ssl_tomcat.ps1"
. "$_SSL_LIB_DIR\ssl_ftp.ps1"

# ─────────────────────────────────────────────────────────────────────────────
# ssl_verificar_openssl
# Verifica que openssl esté disponible; lo instala con choco si no está.
# ─────────────────────────────────────────────────────────────────────────────
function ssl_verificar_openssl {
    if (Get-Command openssl -ErrorAction SilentlyContinue) {
        msg_success "openssl disponible: $(openssl version 2>$null)"
        return $true
    }

    msg_alert "openssl no encontrado — instalando via Chocolatey..."
    & choco install openssl -y 2>&1 | Out-Null

    # Refrescar PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")

    if (Get-Command openssl -ErrorAction SilentlyContinue) {
        msg_success "openssl instalado: $(openssl version 2>$null)"
        return $true
    }

    # Buscar en rutas conocidas de choco
    $candidatos = @(
        "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
        "C:\ProgramData\chocolatey\bin\openssl.exe",
        "C:\tools\openssl\openssl.exe"
    )
    foreach ($c in $candidatos) {
        if (Test-Path $c) {
            $env:PATH += ";$(Split-Path $c)"
            msg_success "openssl encontrado: $c"
            return $true
        }
    }

    msg_error "No se pudo instalar openssl — Apache, Nginx y Tomcat requieren openssl"
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_seleccionar_puerto_https
# Sugiere un puerto HTTPS basado en el puerto HTTP actual.
# $1 = nombre del servicio (display)
# $2 = puerto HTTP actual
# $3 = variable destino para el puerto HTTPS elegido
# ─────────────────────────────────────────────────────────────────────────────
function ssl_seleccionar_puerto_https {
    param([string]$Servicio, [int]$HttpPort, [ref]$OutPort)

    # Sugerir puerto HTTPS basado en el HTTP
    $sugerido = switch ($HttpPort) {
        80   { 443  }
        8080 { 8443 }
        default { $HttpPort + 363 }
    }

    msg_info "Puerto HTTP actual  : ${HttpPort}/tcp"
    msg_info "Puerto HTTPS sugerido: ${sugerido}/tcp"
    Write-Host ""

    while ($true) {
        msg_input "Puerto HTTPS para ${Servicio} [Enter = ${sugerido}]: "
        $entrada = Read-Host
        if ([string]::IsNullOrWhiteSpace($entrada)) { $entrada = "$sugerido" }

        if ($entrada -notmatch '^\d+$') {
            msg_error "Debe ingresar un número de puerto"
            continue
        }
        $p = [int]$entrada
        if ($p -lt 1 -or $p -gt 65535) {
            msg_error "Puerto fuera de rango (1-65535)"
            continue
        }
        if ($p -eq $HttpPort) {
            msg_error "El puerto HTTPS no puede ser igual al HTTP"
            continue
        }

        # Verificar disponibilidad
        $enUso = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
        if ($enUso) {
            $proc = Get-Process -Id ($enUso | Select-Object -First 1).OwningProcess `
                    -ErrorAction SilentlyContinue
            $nombre = if ($proc) { $proc.Name } else { "desconocido" }
            # Permitir si es el propio servicio web (reconfiguración)
            if ($nombre -match 'httpd|nginx|tomcat|w3wp') {
                msg_alert "Puerto ${p} en uso por '${nombre}' (reconfiguración SSL)"
            } else {
                msg_error "Puerto ${p} en uso por '${nombre}'"
                continue
            }
        }

        $OutPort.Value = $p
        msg_success "Puerto HTTPS seleccionado: ${p}/tcp"
        return $true
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_esta_activo
# Retorna $true si SSL está activo para el servicio dado.
# No depende de ssl_lib cargado — solo lee archivos/config.
# ─────────────────────────────────────────────────────────────────────────────
function ssl_esta_activo {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "iis" {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $binding = Get-WebBinding "Default Web Site" -Protocol "https" `
                       -ErrorAction SilentlyContinue
            return ($null -ne $binding)
        }
        "apache" {
            $confDir = Split-Path $script:HTTP_CONF_APACHE -ErrorAction SilentlyContinue
            return (Test-Path "$confDir\extra\ssl-reprobados.conf")
        }
        "nginx" {
            return (Select-String -Path $script:HTTP_CONF_NGINX `
                    -Pattern "ssl_manager: SSL block" -Quiet `
                    -ErrorAction SilentlyContinue)
        }
        "tomcat" {
            if (Test-Path $script:HTTP_CONF_TOMCAT) {
                [xml]$xml = Get-Content $script:HTTP_CONF_TOMCAT -ErrorAction SilentlyContinue
                $sslConn = $xml.Server.Service.Connector | `
                    Where-Object { $_.SSLEnabled -eq "true" }
                return ($null -ne $sslConn)
            }
            return $false
        }
        "ftp" {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $ssl = (Get-ItemProperty "IIS:\Sites\$script:FTP_SITE_NAME" `
                   -Name ftpServer.security.ssl.controlChannelPolicy `
                   -ErrorAction SilentlyContinue).Value
            return ($ssl -gt 0)
        }
        default { return $false }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_abrir_firewall
# Abre un puerto en Windows Firewall.
# ─────────────────────────────────────────────────────────────────────────────
function ssl_abrir_firewall {
    param([int]$Puerto, [string]$Nombre)
    $regla = "SSL_${Nombre}_${Puerto}"
    $existe = Get-NetFirewallRule -DisplayName $regla -ErrorAction SilentlyContinue
    if (-not $existe) {
        New-NetFirewallRule -DisplayName $regla `
            -Direction Inbound -Protocol TCP `
            -LocalPort $Puerto -Action Allow | Out-Null
        msg_success "Puerto ${Puerto}/tcp abierto en Firewall (${regla})"
    } else {
        msg_info "Regla de Firewall ya existe para ${Puerto}/tcp"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_hook_ws
# Hook que ws_install.ps1 llama después de instalar/reconfigurar un servicio.
# Pregunta si desea activar SSL y llama al módulo correspondiente.
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_hook_ws {
    param([string]$Servicio, [string]$Contexto)

    $sslLibPath = Join-Path (Split-Path $MyInvocation.ScriptName) "ssl_lib\ssl.ps1"
    if (-not (Test-Path $sslLibPath)) { return }

    Write-Host ""
    Write-Separator
    msg_input "¿Desea activar SSL/TLS en ${Servicio}? [S/N]: "
    $resp = Read-Host
    if ($resp -notmatch '^[SsYy]') {
        msg_info "SSL omitido"
        return
    }

    switch ($Servicio.ToLower()) {
        "iis"    { ssl_configurar_iis    }
        "apache" { ssl_configurar_apache }
        "nginx"  { ssl_configurar_nginx  }
        "tomcat" { ssl_configurar_tomcat }
    }
}