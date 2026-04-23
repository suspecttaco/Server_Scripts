#
# ac_audit.ps1
#
# Modulo de Auditoria (Eventos y Auditpol) para AC Manager
# Adaptado de la Practica 9.
#

# ---------------------------------------------------------------------------
# Set-ACAuditPolicy
# Habilita las subcategorias de auditoria necesarias mediante auditpol.
# ---------------------------------------------------------------------------
function Set-ACAuditPolicy {
    draw_header "Configurando Politica de Auditoria"
    Write-Log INFO "=== INICIO AUDITPOL ==="

    $auditConfigs = @(
        @{ Sub = "Logon"; GUID = "{0CCE9215-69AE-11D9-BED3-505054503030}"; Type = "/success:enable /failure:enable" }
        @{ Sub = "Logoff"; GUID = "{0CCE9216-69AE-11D9-BED3-505054503030}"; Type = "/success:enable /failure:enable" }
        @{ Sub = "Account Lockout"; GUID = "{0CCE9217-69AE-11D9-BED3-505054503030}"; Type = "/success:enable /failure:enable" }
        @{ Sub = "Object Access"; GUID = "{0CCE9223-69AE-11D9-BED3-505054503030}"; Type = "/success:enable /failure:enable" }
        @{ Sub = "User Account Management"; GUID = "{0CCE9235-69AE-11D9-BED3-505054503030}"; Type = "/success:enable /failure:enable" }
        @{ Sub = "Security Group Management"; GUID = "{0CCE9237-69AE-11D9-BED3-505054503030}"; Type = "/success:enable /failure:enable" }
        @{ Sub = "Audit Policy Change"; GUID = "{0CCE922F-69AE-11D9-BED3-505054503030}"; Type = "/success:enable /failure:enable" }
        @{ Sub = "Directory Service Access"; GUID = "{0CCE923B-69AE-11D9-BED3-505054503030}"; Type = "/success:enable /failure:enable" }
    )

    foreach ($cfg in $auditConfigs) {
        try {
            $typeArgs = $cfg.Type -split ' '
            $result = & auditpol /set /subcategory:"$($cfg.GUID)" @typeArgs 2>&1
            if ($LASTEXITCODE -eq 0) {
                msg_success "Auditoria habilitada: $($cfg.Sub)"
            }
            else {
                msg_alert "auditpol retorno $LASTEXITCODE para: $($cfg.Sub)"
            }
        }
        catch {
            msg_error "Error configurando $($cfg.Sub): $_"
        }
    }

    if ($script:AD_DOMAIN_DN) {
        msg_info "Habilitando auditoria de acceso a objetos de Active Directory..."
        try {
            $dsCmd = "dsacls `"CN=Users,$script:AD_DOMAIN_DN`" /I:S /SDDL:D:(A;;RPWPCRCCDCLCLORCWOWDSDDTSW;;;DA)"
            Invoke-Expression $dsCmd | Out-Null
            msg_success "Configuracion de SACL para auditoria de objetos AD lista."
        }
        catch {
            msg_alert "No se pudo aplicar SACL a CN=Users."
        }
    }

    msg_success "Politica de auditoria configurada."
    Write-Log SUCCESS "=== FIN AUDITPOL ==="
    return $true
}

# ---------------------------------------------------------------------------
# Get-AccessDeniedEvents
# ---------------------------------------------------------------------------
function Get-AccessDeniedEvents {
    param([int]$MaxEvents = 10)

    draw_header "Extraccion de Eventos de Acceso Denegado (ID 4625)"

    $reportDir = "C:\AC_Manager\reports"
    if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    
    $OutputTxt = "$reportDir\accesos_denegados.txt"
    $OutputCsv = "$reportDir\accesos_denegados.csv"

    msg_info "Buscando los ultimos $MaxEvents eventos ID 4625 en Security Log..."

    try {
        $events = Get-WinEvent `
            -FilterHashtable @{ LogName = "Security"; Id = 4625 } `
            -MaxEvents $MaxEvents `
            -ErrorAction Stop
    }
    catch {
        msg_alert "No se encontraron eventos ID 4625 recientes o el log esta limpio."
        return $false
    }

    if ($events.Count -eq 0) {
        msg_alert "El filtro no retorno eventos."
        return $false
    }

    msg_success "Encontrados $($events.Count) eventos. Extrayendo detalles..."

    $results = @()
    foreach ($evt in $events) {
        try {
            $xml = [xml]$evt.ToXml()
            $data = $xml.Event.EventData.Data

            $entry = [PSCustomObject]@{
                Timestamp     = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                EventID       = $evt.Id
                SubjectUser   = ($data | Where-Object { $_.Name -eq "SubjectUserName" })."#text"
                TargetUser    = ($data | Where-Object { $_.Name -eq "TargetUserName" })."#text"
                Workstation   = ($data | Where-Object { $_.Name -eq "WorkstationName" })."#text"
                IpAddress     = ($data | Where-Object { $_.Name -eq "IpAddress" })."#text"
                FailureReason = ($data | Where-Object { $_.Name -eq "FailureReason" })."#text"
                LogonType     = ($data | Where-Object { $_.Name -eq "LogonType" })."#text"
            }
            $results += $entry
        }
        catch {
            $results += [PSCustomObject]@{
                Timestamp     = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                EventID       = $evt.Id
                SubjectUser   = "N/A"
                TargetUser    = "N/A"
                Workstation   = "N/A"
                IpAddress     = "N/A"
                FailureReason = $evt.Message.Substring(0, [Math]::Min(150, $evt.Message.Length))
                LogonType     = "N/A"
            }
        }
    }

    try {
        $results | Export-Csv -Path $OutputCsv -Encoding UTF8 -NoTypeInformation -ErrorAction Stop
        msg_success "CSV exportado: $OutputCsv"
    }
    catch { msg_error "Fallo CSV: $_" }

    try {
        $txtContent = @()
        $txtContent += "=" * 60
        $txtContent += "REPORTE DE ACCESOS DENEGADOS - ID 4625"
        $txtContent += "Generado: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $txtContent += "=" * 60
        $txtContent += ""

        $i = 1
        foreach ($r in $results) {
            $txtContent += "Evento #$i"
            $txtContent += "  Timestamp: $($r.Timestamp)"
            $txtContent += "  Usuario:   $($r.TargetUser)"
            $txtContent += "  IP Origen: $($r.IpAddress)"
            $txtContent += "  Motivo:    $($r.FailureReason)"
            $txtContent += "-" * 40
            $i++
        }
        $txtContent | Out-File -FilePath $OutputTxt -Encoding UTF8 -Force
        msg_success "TXT exportado: $OutputTxt"
    }
    catch { msg_error "Fallo TXT: $_" }

    Write-Host ""
    Write-Host ("  {0,-20} {1,-15} {2,-15} {3}" -f "Timestamp", "Usuario", "IP", "Motivo") -ForegroundColor Cyan
    Write-Host ("  " + "─" * 70) -ForegroundColor DarkGray
    foreach ($r in $results) {
        $ts = $r.Timestamp.Substring(11)
        $user = if ($r.TargetUser.Length -gt 14) { $r.TargetUser.Substring(0, 14) } else { $r.TargetUser }
        $ip = if ($r.IpAddress.Length -gt 14) { $r.IpAddress.Substring(0, 14) } else { $r.IpAddress }
        $motivo = if ($r.FailureReason.Length -gt 30) { $r.FailureReason.Substring(0, 30) } else { $r.FailureReason }
        Write-Host ("  {0,-20} {1,-15} {2,-15} {3}" -f $ts, $user, $ip, $motivo)
    }

    Write-Log SUCCESS "Extraccion ID 4625: $($results.Count) eventos a $reportDir"
    return $true
}

# ---------------------------------------------------------------------------
# Invoke-AuditMenu
# ---------------------------------------------------------------------------
function Invoke-AuditMenu {
    while ($true) {
        Show-Banner
        draw_header "Auditoria de Eventos"

        Write-Host ""
        Write-Host "    [1]  Habilitar auditoria integral (Auditpol)"
        Write-Host "    [2]  Extraer reportes de accesos denegados (ID 4625)"
        Write-Host "    [3]  Ver estado actual de auditpol"
        Write-Host "    [4]  Ver ultimos eventos de bloqueo de cuenta (ID 4740)"
        Write-Host "    [0]  Volver"
        Write-Host ""

        msg_input "Opcion: "
        $op = Read-Host

        switch ($op.Trim()) {
            "1" { Set-ACAuditPolicy | Out-Null; msg_pause }
            "2" { Get-AccessDeniedEvents | Out-Null; msg_pause }
            "3" {
                draw_header "Estado de Auditpol"
                $subcats = @(
                    @{ Name = "Logon"; GUID = "{0CCE9215-69AE-11D9-BED3-505054503030}" }
                    @{ Name = "Logoff"; GUID = "{0CCE9216-69AE-11D9-BED3-505054503030}" }
                    @{ Name = "Account Lockout"; GUID = "{0CCE9217-69AE-11D9-BED3-505054503030}" }
                    @{ Name = "Object Access"; GUID = "{0CCE9223-69AE-11D9-BED3-505054503030}" }
                    @{ Name = "User Account Management"; GUID = "{0CCE9235-69AE-11D9-BED3-505054503030}" }
                    @{ Name = "Security Group Management"; GUID = "{0CCE9237-69AE-11D9-BED3-505054503030}" }
                )
                foreach ($sub in $subcats) {
                    $result = & auditpol /get /subcategory:"$($sub.GUID)" 2>&1
                    $line = $result | Where-Object { $_ -match "Success|Failure|Exito|Error|No Auditing|Sin auditoria" } | Select-Object -First 1
                    if ($line) {
                        if ($line -match "Success and Failure|Exito y Error") {
                            Write-Host "  ● $($sub.Name)" -ForegroundColor Green
                        }
                        elseif ($line -match "Success|Exito") {
                            Write-Host "  ● $($sub.Name) (solo exito)" -ForegroundColor Yellow
                        }
                        else {
                            Write-Host "  ○ $($sub.Name) (no configurado)" -ForegroundColor Red
                        }
                    }
                }
                msg_pause
            }
            "4" {
                draw_header "Eventos de Bloqueo"
                try {
                    $lockEvents = Get-WinEvent -FilterHashtable @{ LogName = "Security"; Id = 4740 } -MaxEvents 10 -EA Stop
                    if ($lockEvents.Count -eq 0) {
                        msg_info "No hay eventos de bloqueo recientes."
                    }
                    else {
                        foreach ($ev in $lockEvents) {
                            $xml = [xml]$ev.ToXml()
                            $data = $xml.Event.EventData.Data
                            $user = ($data | Where-Object { $_.Name -eq "TargetUserName" })."#text"
                            $src = ($data | Where-Object { $_.Name -eq "TargetDomainName" })."#text"
                            msg_info "$($ev.TimeCreated.ToString('HH:mm:ss'))  Bloqueado: $user  desde: $src"
                        }
                    }
                }
                catch {
                    msg_alert "No se encontraron eventos ID 4740."
                }
                msg_pause
            }
            "0" { return }
            default { msg_alert "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}