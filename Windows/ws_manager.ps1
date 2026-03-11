# =============================================================================
# ws_manager.ps1 — Gestor de servicios web (IIS, Apache, Nginx, Tomcat)
#                  Windows Server 2022
#
# Uso: .\ws_manager.ps1 [OPCIONES]
#
# Opciones:
#   -Debug          Activa Set-PSDebug -Trace 1
#   -Verify         Verifica dependencias y sale
#   -Help           Muestra esta ayuda
# =============================================================================

#Requires -Version 5.1

param(
    [switch]$Debug   = $false,
    [switch]$Verify  = $false,
    [switch]$Help    = $false
)

$_scriptDir = $PSScriptRoot

# -----------------------------------------------------------------------------
# Ayuda
# -----------------------------------------------------------------------------
if ($Help) {
    Write-Host ""
    Write-Host "  Uso: .\ws_manager.ps1 [OPCIONES]"
    Write-Host ""
    Write-Host "  Opciones:"
    Write-Host "    -Debug     Activa trazado de ejecucion"
    Write-Host "    -Verify    Verifica dependencias y sale"
    Write-Host "    -Help      Muestra esta ayuda"
    Write-Host ""
    exit 0
}

if ($Debug) { Set-PSDebug -Trace 1 }

# -----------------------------------------------------------------------------
# Carga de librerias
# -----------------------------------------------------------------------------

# lib/ — reutilizables, independientes del tema web
. (Join-Path $_scriptDir "lib\ui.ps1")
. (Join-Path $_scriptDir "lib\utils.ps1")

# ws_lib/ — especificos del servicio web
. (Join-Path $_scriptDir "ws_lib\ws_utils.ps1")
. (Join-Path $_scriptDir "ws_lib\ws_validators.ps1")
. (Join-Path $_scriptDir "ws_lib\ws_status.ps1")
. (Join-Path $_scriptDir "ws_lib\ws_install.ps1")
. (Join-Path $_scriptDir "ws_lib\ws_config.ps1")
. (Join-Path $_scriptDir "ws_lib\ws_versions.ps1")
. (Join-Path $_scriptDir "ws_lib\ws_monitor.ps1")

# -----------------------------------------------------------------------------
# Solo verificar dependencias si se pidio
# -----------------------------------------------------------------------------
if ($Verify) {
    draw_header "Verificacion de dependencias"
    Write-Host ""
    http_verificar_dependencias
    exit 0
}

# -----------------------------------------------------------------------------
# Verificaciones previas al inicio
# -----------------------------------------------------------------------------
if (-not (check_privileges)) { exit 1 }

http_detectar_rutas_reales

if (-not (http_verificar_dependencias 2>$null)) {
    draw_header "Advertencia de dependencias"
    Write-Host ""
    http_verificar_dependencias
    Write-Host ""
    msg_alert "Algunas herramientas criticas no estan disponibles"
    msg_info  "El script puede no funcionar correctamente"
    Write-Host ""
    msg_input "Continuar de todas formas? [s/n]"
    $resp = Read-Host
    if (-not (http_validar_confirmacion $resp)) { exit 0 }
}

# -----------------------------------------------------------------------------
# Menu principal
# -----------------------------------------------------------------------------
function main_menu {
    while ($true) {
        Clear-Host
        draw_header "Gestor de Servicios Web — Windows Server 2022"
        Write-Host ""
        Write-Host "  1) Verificar estado de servicios"
        Write-Host "  2) Instalar servicio HTTP"
        Write-Host "  3) Configurar / Seguridad"
        Write-Host "  4) Monitoreo"
        Write-Host "  5) Gestionar versiones (upgrade / downgrade)"
        Write-Host "  6) Verificar dependencias del sistema"
        Write-Host "  7) Salir"
        Write-Host ""
        if ($Debug) { Write-Host "  [DEBUG ACTIVO]" -ForegroundColor Yellow }
        Write-Host ""

        msg_input "Opcion"
        $op = Read-Host

        switch ($op) {
            "1" { http_menu_verificar }
            "2" { http_menu_instalar }
            "3" { http_menu_configurar }
            "4" { http_menu_monitoreo }
            "5" { http_menu_versiones }
            "6" {
                draw_header "Verificacion de dependencias"
                Write-Host ""
                http_verificar_dependencias
                Write-Host ""
                msg_pause
            }
            "7" {
                Write-Host ""
                msg_info "Hasta luego."
                Write-Host ""
                exit 0
            }
            default {
                msg_error "Opcion invalida. Seleccione entre 1 y 8"
                Start-Sleep -Seconds 2
            }
        }
    }
}

main_menu