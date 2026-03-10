# =============================================================================
# ftp_lib/ftp_install.ps1 - Instalacion, configuracion inicial y desinstalacion
#
# IIS FTP con User Isolation:
#   - Cada usuario se aisla automaticamente en C:\FTP\LocalUser\<usuario>\
#   - Autenticacion via cuentas locales Windows (Basic Authentication)
#   - Anonymous mapea a C:\FTP\LocalUser\Public
#   - Virtual Directories exponen general\ y <grupo>\ dentro del chroot
# =============================================================================

$script:FTP_CONTROL_TIMEOUT = 900   # segundos — default 15 min

function Install-FtpServer {
    Write-Separator
    msg_process "Verificando caracteristicas de Windows necesarias..."

    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service", "Web-Scripting-Tools")
    $toInstall = $features | Where-Object { -not (Get-WindowsFeature $_).Installed }

    if ($toInstall.Count -gt 0) {
        msg_process "Instalando: $($toInstall -join ', ')..."
        try {
            Install-WindowsFeature -Name $toInstall -IncludeManagementTools -ErrorAction Stop | Out-Null
            msg_success "Caracteristicas instaladas"
        } catch {
            msg_error "No se pudieron instalar las caracteristicas: $_"; return
        }
    } else {
        msg_info "Dependencias ya presentes"
    }

    try {
        Import-Module WebAdministration -ErrorAction Stop
    } catch {
        msg_error "No se pudo cargar el modulo WebAdministration: $_"; return
    }

    Request-InitialGroups
    New-FtpWindowsGroups
    New-FtpDirectoryStructure
    Init-FtpMeta
    New-FtpSite
    Set-FtpFirewallRules
    Enable-FtpService

    msg_success "Servidor FTP instalado y configurado"
}

function New-FtpWindowsGroups {
    if (-not (Get-LocalGroup -Name $script:FTP_GROUP_ALL -ErrorAction SilentlyContinue)) {
        New-LocalGroup -Name $script:FTP_GROUP_ALL -Description "Todos los usuarios FTP" | Out-Null
        msg_success "Grupo '$script:FTP_GROUP_ALL' creado"
    } else {
        msg_info "Grupo '$script:FTP_GROUP_ALL' ya existe"
    }

    foreach ($grupo in $script:FTP_GROUPS) {
        if (-not (Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP: $grupo" | Out-Null
            msg_success "Grupo '$grupo' creado"
        } else {
            msg_info "Grupo '$grupo' ya existe"
        }
    }
}

function New-FtpSite {
    msg_process "Configurando sitio FTP en IIS..."

    Import-Module WebAdministration -ErrorAction SilentlyContinue

    if (Test-Path "IIS:\Sites\$script:FTP_SITE_NAME") {
        Remove-WebSite -Name $script:FTP_SITE_NAME -ErrorAction SilentlyContinue
    }

    try {
        New-WebFtpSite -Name $script:FTP_SITE_NAME `
            -Port $script:FTP_PORT `
            -PhysicalPath $script:FTP_ROOT `
            -ErrorAction Stop | Out-Null
    } catch {
        msg_error "No se pudo crear el sitio FTP: $_"; return
    }

    $sitePath = "IIS:\Sites\$script:FTP_SITE_NAME"

    # User Isolation: cada usuario entra a C:\FTP\LocalUser\<usuario>\
    # User Isolation: IsolateRootDirectoryOnly
    # Este modo requiere directorios fisicos para el home del usuario y permite
    # global virtual directories. Los VDirs se registran bajo LocalUser/<usuario>/
    # y son visibles para todos los usuarios que los tengan configurados.
    # IsolateAllDirectories ignoraria los global VDirs — incorrecto para este caso.
    Set-ItemProperty $sitePath -Name ftpServer.userIsolation.mode -Value "IsolateRootDirectoryOnly"

    # Autenticacion
    Set-ItemProperty $sitePath -Name ftpServer.security.authentication.basicAuthentication.enabled     -Value $true
    Set-ItemProperty $sitePath -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty $sitePath -Name ftpServer.security.authentication.anonymousAuthentication.userName           -Value "IUSR"
    Set-ItemProperty $sitePath -Name ftpServer.security.authentication.anonymousAuthentication.password           -Value ""
    Set-ItemProperty $sitePath -Name ftpServer.security.authentication.anonymousAuthentication.defaultLogonDomain -Value ""

    # Modo pasivo
    Set-WebConfiguration "/system.ftpServer/firewallSupport" -Value @{
        lowDataChannelPort  = $script:FTP_PASV_MIN
        highDataChannelPort = $script:FTP_PASV_MAX
    }

    # Banner
    Set-ItemProperty $sitePath -Name ftpServer.messages.bannerMessage -Value $script:FTP_BANNER

    # Desbloquear seccion authorization a nivel de sitio
    Set-WebConfiguration "/system.ftpServer/security/authorization" `
        -Metadata overrideMode -Value Allow -PSPath "IIS:" -ErrorAction SilentlyContinue

    # Limpiar reglas existentes
    Clear-WebConfiguration "/system.ftpServer/security/authorization" -PSPath $sitePath -ErrorAction SilentlyContinue

    # Anonimo: denegar escritura
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:" -Location $script:FTP_SITE_NAME `
        -Value @{ accessType = "Deny"; users = ""; roles = ""; permissions = "Write" }

    # Anonimo: permitir lectura
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:" -Location $script:FTP_SITE_NAME `
        -Value @{ accessType = "Allow"; users = ""; roles = ""; permissions = "Read" }

    # Usuarios autenticados: lectura y escritura
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -PSPath "IIS:" -Location $script:FTP_SITE_NAME `
        -Value @{ accessType = "Allow"; users = "*"; permissions = "Read,Write" }

    # SSL desactivado
    Set-ItemProperty $sitePath -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty $sitePath -Name ftpServer.security.ssl.dataChannelPolicy     -Value 0

    # Timeouts
    Set-ItemProperty $sitePath -Name ftpServer.connections.controlChannelTimeout -Value $script:FTP_CONTROL_TIMEOUT
    Set-ItemProperty $sitePath -Name ftpServer.connections.dataChannelTimeout     -Value 30

    # Logging
    Set-ItemProperty $sitePath -Name ftpServer.logFile.enabled -Value $true

    # Keep-alive
    Set-ItemProperty $sitePath -Name ftpServer.connections.disableSocketPooling -Value $true

    msg_success "Sitio FTP '$script:FTP_SITE_NAME' configurado"
}

function Enable-FtpService {
    msg_process "Iniciando servicio FTP..."
    try {
        Set-Service -Name "FTPSVC" -StartupType Automatic
        Start-Service -Name "FTPSVC" -ErrorAction Stop
        msg_success "Servicio FTP iniciado"
    } catch {
        msg_error "No se pudo iniciar el servicio FTP: $_"
    }
}

function Set-FtpFirewallRules {
    msg_process "Configurando firewall..."

    $r21 = Get-NetFirewallRule -DisplayName "FTP Manager - Puerto 21" -ErrorAction SilentlyContinue
    if (-not $r21) {
        New-NetFirewallRule -DisplayName "FTP Manager - Puerto 21" `
            -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
    }

    $rPasv = Get-NetFirewallRule -DisplayName "FTP Manager - Pasivo" -ErrorAction SilentlyContinue
    if (-not $rPasv) {
        New-NetFirewallRule -DisplayName "FTP Manager - Pasivo" `
            -Direction Inbound -Protocol TCP `
            -LocalPort "$script:FTP_PASV_MIN-$script:FTP_PASV_MAX" `
            -Action Allow | Out-Null
    }

    msg_success "Firewall configurado (21, $script:FTP_PASV_MIN-$script:FTP_PASV_MAX)"
}

function Uninstall-FtpServer {
    if (-not (Confirm-Action "Confirma desinstalacion del servidor FTP")) { return }

    msg_process "Eliminando sitio FTP..."
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    if (Test-Path "IIS:\Sites\$script:FTP_SITE_NAME") {
        Stop-WebSite   -Name $script:FTP_SITE_NAME -ErrorAction SilentlyContinue
        Remove-WebSite -Name $script:FTP_SITE_NAME -ErrorAction SilentlyContinue
        msg_success "Sitio FTP eliminado"
    }

    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue

    if (Confirm-Action "Eliminar usuarios FTP del sistema?") {
        if (Test-Path $script:FTP_META) {
            Get-Content $script:FTP_META | ForEach-Object {
                if ($_ -match '^(.+):') {
                    $u = $Matches[1]
                    try { Remove-LocalUser -Name $u -ErrorAction Stop; msg_success "Usuario '$u' eliminado" }
                    catch { msg_alert "No se pudo eliminar '$u': $_" }
                }
            }
        }
    }

    if (Confirm-Action "Eliminar datos ($script:FTP_ROOT y configuracion)?") {
        Remove-Item $script:FTP_ROOT -Recurse -Force -ErrorAction SilentlyContinue
        msg_success "Datos eliminados"
    }

    Remove-NetFirewallRule -DisplayName "FTP Manager - Puerto 21" -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "FTP Manager - Pasivo"    -ErrorAction SilentlyContinue
    msg_success "Reglas de firewall eliminadas"

    if (Confirm-Action "Desinstalar IIS FTP Service del sistema?") {
        Uninstall-WindowsFeature -Name "Web-Ftp-Server","Web-Ftp-Service" | Out-Null
        msg_success "Caracteristicas IIS FTP desinstaladas"
    }

    msg_success "Desinstalacion completada"
}