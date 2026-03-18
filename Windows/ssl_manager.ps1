# =============================================================================
# ssl_manager.ps1 — Gestor SSL/TLS standalone para Windows Server 2022
# Uso: powershell -ExecutionPolicy Bypass -File ssl_manager.ps1
# Requiere: ejecución como Administrador
# =============================================================================

#Requires -RunAsAdministrator

param([switch]$Help)

if ($Help) {
    Write-Host "Uso: .\ssl_manager.ps1"
    Write-Host "Requiere PowerShell como Administrador"
    exit 0
}

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# Cargar librerías base
. "$SCRIPT_DIR\lib\ui.ps1"
. "$SCRIPT_DIR\lib\utils.ps1"

# Cargar ws_lib para funciones de servicios (necesario para reiniciar servicios)
. "$SCRIPT_DIR\ws_lib\ws_utils.ps1"
. "$SCRIPT_DIR\ws_lib\ws_validators.ps1"

# Cargar ftp_lib para $script:FTP_SITE_NAME, $script:FTP_PORT, etc.
# Solo si ftp_lib está disponible
if (Test-Path "$SCRIPT_DIR\ftp_lib\ftp.ps1") {
    . "$SCRIPT_DIR\ftp_lib\ftp.ps1"
}

# Cargar ssl_lib
. "$SCRIPT_DIR\ssl_lib\ssl.ps1"

# Inicializar rutas reales
http_detectar_rutas_reales

# ─────────────────────────────────────────────────────────────────────────────
# Menú principal SSL
# ─────────────────────────────────────────────────────────────────────────────
function Show-SslMainMenu {
    while ($true) {
        Clear-Host
        draw_header "SSL/TLS Manager — Windows Server 2022"
        Write-Host ""
        Write-Host "  Servicios HTTP:"
        Write-Host "  1) Configurar SSL en IIS"
        Write-Host "  2) Configurar SSL en Apache"
        Write-Host "  3) Configurar SSL en Nginx"
        Write-Host "  4) Configurar SSL en Tomcat"
        Write-Host ""
        Write-Host "  Servicio FTP:"
        Write-Host "  5) Configurar FTPS en IIS FTP"
        Write-Host ""
        Write-Host "  Gestión:"
        Write-Host "  6) Ver estado SSL de todos los servicios"
        Write-Host "  7) Desactivar SSL en un servicio"
        Write-Host "  0) Salir"
        Write-Host ""

        msg_input "Opción: "
        $op = Read-Host

        switch ($op) {
            "1" { ssl_configurar_iis;    Write-Host ""; msg_pause }
            "2" { ssl_configurar_apache; Write-Host ""; msg_pause }
            "3" { ssl_configurar_nginx;  Write-Host ""; msg_pause }
            "4" { ssl_configurar_tomcat; Write-Host ""; msg_pause }
            "5" { ssl_configurar_ftp;    Write-Host ""; msg_pause }
            "6" { Show-SslStatus;        Write-Host ""; msg_pause }
            "7" { Show-SslDesactivar;    Write-Host ""; msg_pause }
            "0" { msg_info "Saliendo..."; exit 0 }
            default { msg_error "Opción inválida"; Start-Sleep -Seconds 1 }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Show-SslStatus — panel de estado SSL de todos los servicios
# ─────────────────────────────────────────────────────────────────────────────
function Show-SslStatus {
    Clear-Host
    draw_header "Estado SSL/TLS — Todos los servicios"
    Write-Host ""

    $servicios = @(
        @{ Nombre = "IIS (HTTP)";     Interno = "iis"    }
        @{ Nombre = "Apache (HTTP)";  Interno = "apache" }
        @{ Nombre = "Nginx (HTTP)";   Interno = "nginx"  }
        @{ Nombre = "Tomcat (HTTP)";  Interno = "tomcat" }
        @{ Nombre = "IIS FTP (FTPS)"; Interno = "ftp"    }
    )

    foreach ($svc in $servicios) {
        $activo = ssl_esta_activo $svc.Interno
        $estado = if ($activo) { "${GREEN}ACTIVO${NC}" } else { "${YELLOW}INACTIVO${NC}" }
        Write-Host ("  {0,-22}: " -f $svc.Nombre) -NoNewline
        Write-Host $estado

        if ($activo) {
            switch ($svc.Interno) {
                "iis" {
                    Import-Module WebAdministration -ErrorAction SilentlyContinue
                    $b = Get-WebBinding "Default Web Site" -Protocol "https" `
                         -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($b) {
                        $p = ($b.bindingInformation -split ':')[1]
                        Write-Host "    Puerto HTTPS: ${p}/tcp"
                    }
                }
                "apache" {
                    $p = _ssl_apache_leer_puerto_https
                    Write-Host "    Puerto HTTPS: ${p}/tcp"
                }
                "nginx" {
                    $p = _ssl_nginx_leer_puerto_https
                    Write-Host "    Puerto HTTPS: ${p}/tcp"
                }
                "tomcat" {
                    $p = _ssl_tomcat_leer_puerto_https
                    Write-Host "    Puerto HTTPS: ${p}/tcp"
                }
                "ftp" {
                    ssl_ftp_estado
                }
            }
        }
        Write-Host ""
    }

    Write-Separator

    # Verificación rápida con curl
    Write-Host ""
    msg_info "Verificación rápida de respuesta HTTPS:"
    Write-Host ""

    $puertos = @()
    if (ssl_esta_activo "iis") {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $b = Get-WebBinding "Default Web Site" -Protocol "https" `
             -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($b) { $puertos += [int](($b.bindingInformation -split ':')[1]) }
    }
    if (ssl_esta_activo "apache")  { $puertos += _ssl_apache_leer_puerto_https }
    if (ssl_esta_activo "nginx")   { $puertos += _ssl_nginx_leer_puerto_https  }
    if (ssl_esta_activo "tomcat")  { $puertos += _ssl_tomcat_leer_puerto_https }

    foreach ($p in ($puertos | Select-Object -Unique)) {
        $code = curl.exe -sk -o NUL -w "%{http_code}" "https://localhost:${p}" 2>$null
        if ($code -match '^(200|301|302|400|404)$') {
            Write-Host ("  ${GREEN}[OK]${NC}   https://localhost:${p}  → HTTP $code")
        } else {
            Write-Host ("  ${YELLOW}[--]${NC}   https://localhost:${p}  → HTTP $code")
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Show-SslDesactivar — menú para desactivar SSL en un servicio
# ─────────────────────────────────────────────────────────────────────────────
function Show-SslDesactivar {
    Clear-Host
    draw_header "Desactivar SSL — Seleccionar servicio"
    Write-Host ""
    Write-Host "  1) IIS"
    Write-Host "  2) Apache"
    Write-Host "  3) Nginx"
    Write-Host "  4) Tomcat"
    Write-Host "  5) IIS FTP (FTPS)"
    Write-Host "  0) Cancelar"
    Write-Host ""
    msg_input "Opción: "
    $op = Read-Host

    switch ($op) {
        "1" { ssl_desactivar_iis    }
        "2" { ssl_desactivar_apache }
        "3" { ssl_desactivar_nginx  }
        "4" { ssl_desactivar_tomcat }
        "5" { ssl_desactivar_ftp    }
        "0" { return }
        default { msg_error "Opción inválida" }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Inicio
# ─────────────────────────────────────────────────────────────────────────────
Show-SslMainMenu