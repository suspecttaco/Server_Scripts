# =============================================================================
# ftp_manager.ps1 — Instalacion y configuracion de servidor FTP (IIS FTP)
# Uso: powershell -ExecutionPolicy Bypass -File ftp_manager.ps1
# Requiere: Windows Server 2022, PowerShell 5.1+, ejecucion como Administrador
# =============================================================================

#Requires -RunAsAdministrator

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# Cargar libreria UI
. "$SCRIPT_DIR\lib\ui.ps1"
. "$SCRIPT_DIR\lib\net.ps1"

# Cargar modulos FTP (variables globales + submodulos)
. "$SCRIPT_DIR\ftp_lib\ftp.ps1"

# Importar WebAdministration al inicio para tenerlo disponible en todos los modulos
Import-Module WebAdministration -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# Menus
# -----------------------------------------------------------------------------
function Show-MainMenu {
    while ($true) {
        Write-Separator
        msg_info "FTP Manager — IIS FTP Service"
        Write-Separator
        Write-Host "  1) Instalar y configurar IIS FTP"
        Write-Host "  2) Gestionar usuarios FTP"
        Write-Host "  3) Gestionar grupos y permisos"
        Write-Host "  4) Gestion del servicio"
        Write-Host "  5) Gestion de configuracion"
        Write-Host "  6) SSL/TLS (FTPS)"
        Write-Host "  7) Desinstalar IIS FTP"
        Write-Host "  0) Salir"
        Write-Separator

        $op = Read-Input "Opcion: "
        switch ($op) {
            "1" { Install-FtpServer }
            "2" { Show-UsersMenu }
            "3" { Show-GroupsMenu }
            "4" { Show-ServiceMenu }
            "5" { Show-ConfigMenu }
            "6" { Show-FtpSslMenu }
            "7" { Uninstall-FtpServer }
            "0" { msg_info "Saliendo..."; exit 0 }
            default { msg_alert "Opcion invalida" }
        }
    }
}

function Show-UsersMenu {
    while ($true) {
        Write-Separator
        msg_info "Gestion de Usuarios FTP"
        Write-Separator
        Write-Host "  1) Crear usuarios en lote"
        Write-Host "  2) Actualizar usuario (nombre / contrasena / grupo)"
        Write-Host "  3) Eliminar usuario"
        Write-Host "  4) Listar usuarios FTP"
        Write-Host "  0) Volver"
        Write-Separator

        $op = Read-Input "Opcion: "
        switch ($op) {
            "1" { New-FtpUsersLote }
            "2" { Update-FtpUser }
            "3" { Remove-FtpUser }
            "4" { Show-FtpUsers }
            "0" { return }
            default { msg_alert "Opcion invalida" }
        }
    }
}

function Show-GroupsMenu {
    while ($true) {
        Write-Separator
        msg_info "Gestion de Grupos y Permisos"
        Write-Separator
        Write-Host "  1) Listar grupos y permisos"
        Write-Host "  2) Crear grupo"
        Write-Host "  3) Eliminar grupo"
        Write-Host "  4) Ver / reparar permisos de directorios"
        Write-Host "  5) Reparar grupos de usuarios"
        Write-Host "  0) Volver"
        Write-Separator

        $op = Read-Input "Opcion: "
        switch ($op) {
            "1" { Show-FtpGroups }
            "2" { New-FtpGroup }
            "3" { Remove-FtpGroup }
            "4" { Manage-GroupDirectoryPermissions }
            "5" { Repair-FtpGroupMemberships }
            "0" { return }
            default { msg_alert "Opcion invalida" }
        }
    }
}

function Show-ServiceMenu {
    while ($true) {
        Write-Separator
        msg_info "Gestion del Servicio FTP"
        Write-Separator
        Write-Host "  1) Ver estado detallado"
        Write-Host "  2) Iniciar servicio"
        Write-Host "  3) Detener servicio"
        Write-Host "  4) Reiniciar servicio"
        Write-Host "  5) Habilitar / deshabilitar arranque automatico"
        Write-Host "  0) Volver"
        Write-Separator

        $op = Read-Input "Opcion: "
        switch ($op) {
            "1" { Show-FtpStatus }
            "2" { Start-FtpService }
            "3" { Stop-FtpService }
            "4" { Restart-FtpService }
            "5" { Toggle-FtpAutoStart }
            "0" { return }
            default { msg_alert "Opcion invalida" }
        }
    }
}

function Show-ConfigMenu {
    while ($true) {
        Write-Separator
        msg_info "Gestion de Configuracion"
        Write-Separator
        Write-Host "  1) Ver configuracion activa"
        Write-Host "  2) Editar parametros del servidor"
        Write-Host "  3) Gestionar firewall (puertos FTP)"
        Write-Host "  0) Volver"
        Write-Separator

        $op = Read-Input "Opcion: "
        switch ($op) {
            "1" { Show-FtpConfig }
            "2" { Edit-FtpConfig }
            "3" { Manage-FtpFirewall }
            "0" { return }
            default { msg_alert "Opcion invalida" }
        }
    }
}

function Show-FtpSslMenu {
    # Cargar ssl_lib si no está ya cargado
    $sslLibPath = Join-Path $SCRIPT_DIR "ssl_lib\ssl.ps1"
    if (-not (Test-Path $sslLibPath)) {
        msg_error "ssl_lib\ssl.ps1 no encontrado en: $sslLibPath"
        msg_info  "Asegúrese de que ssl_lib\ está en el mismo directorio que ftp_manager.ps1"
        msg_pause
        return
    }
    . $sslLibPath

    while ($true) {
        Write-Separator
        msg_info "SSL/TLS — IIS FTP (FTPS)"
        Write-Separator
        Write-Host "  1) Configurar FTPS"
        Write-Host "  2) Ver estado SSL/FTPS"
        Write-Host "  3) Desactivar FTPS"
        Write-Host "  0) Volver"
        Write-Separator

        $op = Read-Input "Opción: "
        switch ($op) {
            "1" { ssl_configurar_ftp;  Write-Host ""; msg_pause }
            "2" { ssl_ftp_estado;      Write-Host ""; msg_pause }
            "3" { ssl_desactivar_ftp;  Write-Host ""; msg_pause }
            "0" { return }
            default { msg_alert "Opción inválida" }
        }
    }
}

# -----------------------------------------------------------------------------
# Inicio
# -----------------------------------------------------------------------------
Show-MainMenu