#
# ac_fgpp.ps1
#
# Modulo de Politicas de Contrasena (FGPP) para AC Manager
# Adaptado de la Practica 9.
#

# ---------------------------------------------------------------------------
# Invoke-ACFGPP
# Crea dos Fine Grained Password Policies:
#   FGPP-Admins:    12 caracteres minimo, para GRP_AdminDelegados
#   FGPP-Estandar:   8 caracteres minimo, para GRP_Cuates y GRP_NoCuates
# ---------------------------------------------------------------------------
function Invoke-ACFGPP {
    draw_header "Configurando FGPP (Fine Grained Password Policies)"
    Write-Log INFO "=== INICIO FGPP ==="

    $domain = $script:AD_DOMAIN
    if (-not $domain) { msg_alert "No hay conexion al dominio."; return $false }

    # ---- FGPP Admins ----
    $fgppAdminName = "FGPP-Admins"
    $existingAdmin = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$fgppAdminName'" -Server $domain -EA SilentlyContinue

    if ($existingAdmin) {
        msg_info "FGPP '$fgppAdminName' ya existe."
    }
    else {
        try {
            New-ADFineGrainedPasswordPolicy `
                -Name                   $fgppAdminName `
                -Precedence             10 `
                -MinPasswordLength      12 `
                -ComplexityEnabled      $true `
                -PasswordHistoryCount   5 `
                -MaxPasswordAge         "90.00:00:00" `
                -MinPasswordAge         "1.00:00:00" `
                -ReversibleEncryptionEnabled $false `
                -LockoutThreshold       3 `
                -LockoutDuration        "00:30:00" `
                -LockoutObservationWindow "00:30:00" `
                -Server                 $domain `
                -ErrorAction Stop
            msg_success "FGPP '$fgppAdminName' creada (12 chars, lockout 3x/30min)"
            Write-Log SUCCESS "FGPP $fgppAdminName creada"
        }
        catch {
            msg_error "Error creando FGPP admins: $_"
        }
    }

    try {
        Add-ADFineGrainedPasswordPolicySubject -Identity $fgppAdminName -Subjects "GRP_AdminDelegados" -Server $domain -ErrorAction Stop
        msg_success "FGPP-Admins aplicada a GRP_AdminDelegados"
    }
    catch {
        if ($_.Exception.Message -match "already") { msg_info "FGPP-Admins ya aplicada a GRP_AdminDelegados." }
        else { msg_alert "No se pudo aplicar FGPP-Admins a GRP_AdminDelegados." }
    }

    # ---- FGPP Estandar ----
    $fgppEstandarName = "FGPP-Estandar"
    $existingEstandar = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$fgppEstandarName'" -Server $domain -EA SilentlyContinue

    if ($existingEstandar) {
        msg_info "FGPP '$fgppEstandarName' ya existe."
    }
    else {
        try {
            New-ADFineGrainedPasswordPolicy `
                -Name                   $fgppEstandarName `
                -Precedence             20 `
                -MinPasswordLength      8 `
                -ComplexityEnabled      $true `
                -PasswordHistoryCount   3 `
                -MaxPasswordAge         "180.00:00:00" `
                -MinPasswordAge         "1.00:00:00" `
                -ReversibleEncryptionEnabled $false `
                -LockoutThreshold       5 `
                -LockoutDuration        "00:15:00" `
                -LockoutObservationWindow "00:15:00" `
                -Server                 $domain `
                -ErrorAction Stop
            msg_success "FGPP '$fgppEstandarName' creada (8 chars, lockout 5x/15min)"
            Write-Log SUCCESS "FGPP $fgppEstandarName creada"
        }
        catch {
            msg_error "Error creando FGPP estandar: $_"
        }
    }

    foreach ($grp in @("GRP_Cuates", "GRP_NoCuates")) {
        try {
            Add-ADFineGrainedPasswordPolicySubject -Identity $fgppEstandarName -Subjects $grp -Server $domain -ErrorAction Stop
            msg_success "FGPP-Estandar aplicada a $grp"
        }
        catch {
            if ($_.Exception.Message -match "already") { msg_info "FGPP-Estandar ya aplicada a $grp." }
            else { msg_alert "Error aplicando FGPP-Estandar a $grp." }
        }
    }

    msg_success "FGPP configuradas correctamente."
    Write-Log SUCCESS "=== FIN FGPP ==="
    return $true
}

# ---------------------------------------------------------------------------
# Invoke-FGPPMenu
# ---------------------------------------------------------------------------
function Invoke-FGPPMenu {
    while ($true) {
        Show-Banner
        draw_header "FGPP - Politicas de Contrasena"

        # Estado rapido
        $domain = $script:AD_DOMAIN
        if ($domain) {
            $fgppA = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP-Admins'" -Server $domain -EA SilentlyContinue
            $fgppE = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP-Estandar'" -Server $domain -EA SilentlyContinue
            
            Write-Host "  $(if ($fgppA) { '●' } else { '○' })  FGPP-Admins    (12 chars, lockout 3x/30min)" -ForegroundColor $(if ($fgppA) { 'Green' } else { 'Red' })
            Write-Host "  $(if ($fgppE) { '●' } else { '○' })  FGPP-Estandar  (8 chars, lockout 5x/15min)" -ForegroundColor $(if ($fgppE) { 'Green' } else { 'Red' })
        }
        else {
            msg_alert "Sin conexion al dominio"
        }

        Write-Host ""
        Write-Host "    [1]  Configurar FGPP (Crear y asignar)"
        Write-Host "    [2]  Ver FGPP aplicadas a un usuario especifico"
        Write-Host "    [0]  Volver"
        Write-Host ""

        msg_input "Opcion: "
        $op = Read-Host

        switch ($op.Trim()) {
            "1" { Invoke-ACFGPP | Out-Null; msg_pause }
            "2" {
                $sam = Read-InputLoop -Prompt "Nombre de cuenta" -Validator { param($v) $v.Length -gt 0 }
                if ($sam -and $domain) {
                    try {
                        $rsop = Get-ADUserResultantPasswordPolicy -Identity $sam -Server $domain -EA Stop
                        msg_info "Politica aplicada a '$sam':"
                        msg_info "  Nombre:          $($rsop.Name)"
                        msg_info "  Min longitud:    $($rsop.MinPasswordLength) caracteres"
                        msg_info "  Complejidad:     $($rsop.ComplexityEnabled)"
                        msg_info "  Lockout thresh:  $($rsop.LockoutThreshold) intentos"
                        msg_info "  Lockout duracion:$($rsop.LockoutDuration)"
                    }
                    catch {
                        msg_alert "No se encontro FGPP especifica para '$sam', aplica la de dominio."
                    }
                }
                msg_pause
            }
            "0" { return }
            default { msg_alert "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

