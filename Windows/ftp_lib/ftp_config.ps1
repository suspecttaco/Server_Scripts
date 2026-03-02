# =============================================================================
# ftp_lib/ftp_config.ps1 — Edicion de configuracion FTP y gestion de firewall
# =============================================================================

function Show-FtpConfig {
    Write-Separator
    msg_info "Configuracion activa del sitio FTP:"
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $sitePath = "IIS:\Sites\$script:FTP_SITE_NAME"
    if (-not (Test-Path $sitePath)) { msg_alert "Sitio '$script:FTP_SITE_NAME' no existe"; return }

    $site = Get-Item $sitePath
    Write-Host ""
    Write-Host "  Sitio       : $script:FTP_SITE_NAME"
    Write-Host "  Puerto      : $script:FTP_PORT"
    Write-Host "  Ruta fisica : $($site.PhysicalPath)"
    Write-Host "  Estado      : $($site.State)"

    $banner = (Get-ItemProperty $sitePath -Name ftpServer.messages.bannerMessage).Value
    Write-Host "  Banner      : $banner"

    $ssl = (Get-ItemProperty $sitePath -Name ftpServer.security.ssl.controlChannelPolicy).Value
    Write-Host "  SSL         : $(if ($ssl -eq 0) { 'Desactivado' } elseif ($ssl -eq 1) { 'Permitido' } else { 'Requerido' })"

    $anon = (Get-ItemProperty $sitePath -Name ftpServer.security.authentication.anonymousAuthentication.enabled).Value
    Write-Host "  Anonimo     : $(if ($anon) { 'SI' } else { 'NO' })"

    $iso = (Get-ItemProperty $sitePath -Name ftpServer.userIsolation.mode).Value
    Write-Host "  Aislamiento : $(if ($iso -eq 3) { 'Por usuario (LocalUser)' } else { $iso })"

    $pasvConf = Get-WebConfiguration "/system.ftpServer/firewallSupport"
    Write-Host "  PASV        : $($pasvConf.lowDataChannelPort) - $($pasvConf.highDataChannelPort)"
    $ctTimeout = (Get-ItemProperty $sitePath -Name ftpServer.connections.controlChannelTimeout).Value
    Write-Host "  Timeout ctrl: ${ctTimeout}s  ($([math]::Round($ctTimeout/60, 1)) min)"
    $dtTimeout = (Get-ItemProperty $sitePath -Name ftpServer.connections.dataChannelTimeout).Value
    Write-Host "  Timeout data: ${dtTimeout}s"
    Write-Host ""
}

function Edit-FtpConfig {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $sitePath = "IIS:\Sites\$script:FTP_SITE_NAME"
    if (-not (Test-Path $sitePath)) { msg_alert "Instala el servidor FTP primero"; return }

    msg_info "Backup de configuracion IIS no requerido (IIS gestiona historico internamente)"
    msg_info "Enter = sin cambios"
    Write-Separator

    # Banner
    $bannerActual = (Get-ItemProperty $sitePath -Name ftpServer.messages.bannerMessage).Value
    $nuevoBanner = Read-Input "Banner [$bannerActual]: "
    if (-not [string]::IsNullOrWhiteSpace($nuevoBanner)) {
        Set-ItemProperty $sitePath -Name ftpServer.messages.bannerMessage -Value $nuevoBanner
        $script:FTP_BANNER = $nuevoBanner
        msg_success "Banner actualizado"
    }

    # Puertos pasivos
    $pasvConf = Get-WebConfiguration "/system.ftpServer/firewallSupport"
    $pmin = $pasvConf.lowDataChannelPort
    $pmax = $pasvConf.highDataChannelPort

    $nmin = Read-Input "Puerto pasivo minimo [$pmin]: "
    $nmax = Read-Input "Puerto pasivo maximo [$pmax]: "

    $fmin = if ([string]::IsNullOrWhiteSpace($nmin)) { $pmin } else { [int]$nmin }
    $fmax = if ([string]::IsNullOrWhiteSpace($nmax)) { $pmax } else { [int]$nmax }

    if ((-not [string]::IsNullOrWhiteSpace($nmin)) -or (-not [string]::IsNullOrWhiteSpace($nmax))) {
        if ($fmin -ge 1024 -and $fmax -le 65535 -and $fmin -lt $fmax) {
            Set-WebConfiguration "/system.ftpServer/firewallSupport" -Value @{
                lowDataChannelPort  = $fmin
                highDataChannelPort = $fmax
            }
            $script:FTP_PASV_MIN = $fmin
            $script:FTP_PASV_MAX = $fmax
            msg_success "Puertos pasivos actualizados: $fmin - $fmax"
        } else {
            msg_error "Rango invalido o minimo >= maximo — sin cambios"
        }
    }

    # Timeout de conexion de control
    $ctActual  = (Get-ItemProperty $sitePath -Name ftpServer.connections.controlChannelTimeout).Value
    $nuevoCt   = Read-Input "Timeout de conexion en segundos [$ctActual]: "
    if (-not [string]::IsNullOrWhiteSpace($nuevoCt)) {
        $ctVal = [int]$nuevoCt
        if ($ctVal -ge 30 -and $ctVal -le 3600) {
            Set-ItemProperty $sitePath -Name ftpServer.connections.controlChannelTimeout -Value $ctVal
            $script:FTP_CONTROL_TIMEOUT = $ctVal
            msg_success "Timeout actualizado a ${ctVal}s"
        } else {
            msg_error "Valor invalido — usa entre 30 y 3600 segundos"
        }
    }

    # Acceso anonimo
    $anonActual = (Get-ItemProperty $sitePath -Name ftpServer.security.authentication.anonymousAuthentication.enabled).Value
    $nuevoAnon  = Read-Input "Acceso anonimo YES/NO [$(if ($anonActual) { 'YES' } else { 'NO' })]: "
    if (-not [string]::IsNullOrWhiteSpace($nuevoAnon)) {
        switch ($nuevoAnon.ToUpper()) {
            { $_ -in 'YES','Y' } {
                Set-ItemProperty $sitePath -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
                msg_success "Acceso anonimo habilitado"
            }
            { $_ -in 'NO','N' } {
                Set-ItemProperty $sitePath -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $false
                msg_success "Acceso anonimo deshabilitado"
            }
            default { msg_error "Usa YES o NO" }
        }
    }

    if (Confirm-Action "Reiniciar servicio FTP?") { Restart-FtpService }
}

function Manage-FtpFirewall {
    Write-Separator
    msg_info "Firewall — Reglas FTP activas:"

    $rules = Get-NetFirewallRule -DisplayName "FTP Manager*" -ErrorAction SilentlyContinue
    if ($rules) {
        $rules | ForEach-Object {
            $ports = ($_ | Get-NetFirewallPortFilter).LocalPort
            Write-Host "  $($_.DisplayName) — Puerto(s): $ports — $($_.Enabled)"
        }
    } else {
        msg_alert "No se encontraron reglas FTP Manager en el firewall"
    }

    Write-Separator
    Write-Host "  1) Abrir puertos FTP (21 + $script:FTP_PASV_MIN-$script:FTP_PASV_MAX)"
    Write-Host "  2) Cerrar puertos FTP"
    Write-Host "  3) Ver todas las reglas de firewall"
    Write-Host "  0) Volver"
    Write-Separator

    $op = Read-Input "Opcion: "
    switch ($op) {
        "1" {
            # Puerto 21
            $r21 = Get-NetFirewallRule -DisplayName "FTP Manager - Puerto 21" -ErrorAction SilentlyContinue
            if ($r21) { Enable-NetFirewallRule -DisplayName "FTP Manager - Puerto 21" }
            else {
                New-NetFirewallRule -DisplayName "FTP Manager - Puerto 21" `
                    -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
            }
            # Pasivo
            $rPasv = Get-NetFirewallRule -DisplayName "FTP Manager - Pasivo" -ErrorAction SilentlyContinue
            if ($rPasv) { Enable-NetFirewallRule -DisplayName "FTP Manager - Pasivo" }
            else {
                New-NetFirewallRule -DisplayName "FTP Manager - Pasivo" `
                    -Direction Inbound -Protocol TCP `
                    -LocalPort "$script:FTP_PASV_MIN-$script:FTP_PASV_MAX" `
                    -Action Allow | Out-Null
            }
            msg_success "Puertos abiertos"
        }
        "2" {
            Disable-NetFirewallRule -DisplayName "FTP Manager - Puerto 21" -ErrorAction SilentlyContinue
            Disable-NetFirewallRule -DisplayName "FTP Manager - Pasivo"    -ErrorAction SilentlyContinue
            msg_success "Reglas FTP deshabilitadas"
        }
        "3" {
            Get-NetFirewallRule | Where-Object { $_.Enabled -eq $true } | Format-Table DisplayName, Direction, Action -AutoSize
        }
        "0" { return }
        default { msg_alert "Opcion invalida" }
    }
}