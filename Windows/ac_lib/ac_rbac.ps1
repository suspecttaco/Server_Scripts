#
# ac_rbac.ps1
#
# Modulo de Delegacion de Control Basado en Roles (RBAC) para AC Manager
# Adaptado de la Practica 9.
#

$script:VALID_ROLES = @("IAMOperator", "StorageOperator", "GPOCompliance", "SecurityAuditor")

# ---------------------------------------------------------------------------
# New-AdminInteractivo
# Crea un admin_* interactivamente.
# ---------------------------------------------------------------------------
function New-AdminInteractivo {
    draw_header "Alta de Administrador Delegado"

    $sam = Read-InputLoop -Prompt "Nombre de cuenta (ej: admin_soporte)" `
        -Validator { param($v) $v.Length -gt 0 } -ErrorMsg "Dato requerido."
    if ($sam -eq $false) { return }

    $nombre = Read-InputLoop -Prompt "Nombre completo  (ej: Admin Soporte)" `
        -Validator { param($v) $v.Length -gt 0 } -ErrorMsg "Dato requerido."
    if ($nombre -eq $false) { return }

    Write-Host "Password (min 12 caracteres, se ocultara): " -NoNewline -ForegroundColor Cyan
    $passValue = Read-Host -AsSecureString
    $pass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($passValue))

    if ($pass.Length -lt 12) {
        msg_error "La password debe tener al menos 12 caracteres (politica FGPP admins)."
        return $false
    }

    # Seleccion de roles
    Write-Host ""
    msg_info "Roles disponibles:"
    Write-Host "  [1] IAMOperator      - Gestion de identidad y acceso"
    Write-Host "  [2] StorageOperator  - Gestion FSRM (cuotas, file screening)"
    Write-Host "  [3] GPOCompliance    - Cumplimiento y directivas GPO"
    Write-Host "  [4] SecurityAuditor  - Auditor solo lectura"
    Write-Host ""
    
    $rolesInput = Read-InputLoop -Prompt "Roles a asignar separados por coma (ej: 1,3) (Opcional)" -Validator {
        param($v)
        if ([string]::IsNullOrWhiteSpace($v)) { return $true }
        $parts = $v -split ","
        foreach ($p in $parts) {
            $num = 0
            if (-not [int]::TryParse($p.Trim(), [ref]$num) -or $num -lt 1 -or $num -gt 4) { return $false }
        }
        return $true
    } -AllowEmpty $true -ErrorMsg "Formato invalido. Usa numeros del 1 al 4."

    $roles = @()
    if ($rolesInput) {
        $rolesInput -split "," | ForEach-Object {
            $idx = [int]$_.Trim() - 1
            $roles += $script:VALID_ROLES[$idx]
        }
    }

    if ($roles.Count -eq 0) {
        msg_alert "Ningun rol valido seleccionado. El usuario se creara sin roles asignados."
        msg_info "Se puede asignar roles despues con la opcion correspondiente del menu."
    }

    # Confirmacion
    Write-Host ""
    Write-Separator
    msg_info "Resumen del administrador a crear:"
    msg_info "  Cuenta:   $sam"
    msg_info "  Nombre:   $nombre"
    msg_info "  Roles:    $(if ($roles.Count -gt 0) { $roles -join ', ' } else { '(ninguno)' })"
    Write-Separator
    
    $confirm = Read-InputLoop -Prompt "Escriba 'SI' para crear" -Validator { param($v) $v -eq "SI" } -ErrorMsg "Se requiere SI."
    if ($confirm -ne "SI") { msg_info "Operacion cancelada."; return $false }

    if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -SearchBase $script:AD_DOMAIN_DN -ErrorAction SilentlyContinue) {
        msg_error "El usuario '$sam' ya existe en AD."
        return $false
    }

    try {
        $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
        New-ADUser -SamAccountName $sam -UserPrincipalName "$sam@$script:AD_DOMAIN" `
            -DisplayName $nombre -Name $nombre -Department "Admins" `
            -AccountPassword $secPass -Path "OU=Admins,$script:AD_DOMAIN_DN" `
            -Enabled $true -PasswordNeverExpires $true `
            -ChangePasswordAtLogon $false -ErrorAction Stop
        msg_success "Admin '$sam' creado en OU=Admins"
        Write-Log SUCCESS "Admin $sam creado interactivamente"
    }
    catch {
        msg_error "Error al crear admin: $_"
        return $false
    }

    try { Add-ADGroupMember -Identity "GRP_AdminDelegados" -Members $sam -EA Stop } catch {
        msg_alert "No se pudo agregar a GRP_AdminDelegados"
    }

    foreach ($rol in $roles) {
        try {
            Add-ADGroupMember -Identity "GRP_Role_$rol" -Members $sam -EA Stop
            msg_success "$sam -> GRP_Role_$rol"
            Write-Log SUCCESS "Admin $sam asignado rol $rol"
        }
        catch { msg_alert "No se pudo asignar rol $rol a $sam" }
    }

    msg_success "Admin '$sam' creado. Ejecute 'Configurar delegacion RBAC' para aplicar ACLs."
    return $true
}

# ---------------------------------------------------------------------------
# Set-DCInteractiveLogon
# ---------------------------------------------------------------------------
function Set-DCInteractiveLogon {
    msg_info "Configurando derecho de login local en DC para GRP_AdminDelegados..."

    try {
        $grpSid = (Get-ADGroup "GRP_AdminDelegados" -EA Stop).SID.Value
    }
    catch {
        msg_alert "GRP_AdminDelegados no encontrado."
        return $false
    }

    $infPath = "$env:TEMP\dclogon.inf"
    $sdbPath = "$env:TEMP\dclogon.sdb"

    $infContent = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeInteractiveLogonRight = *S-1-5-32-544,*S-1-5-32-548,*S-1-5-32-549,*S-1-5-32-550,*S-1-5-32-551,*$grpSid
"@
    $infContent | Out-File -FilePath $infPath -Encoding Unicode -Force

    if (Test-Path $sdbPath) { Remove-Item $sdbPath -Force }
    & secedit /configure /cfg $infPath /db $sdbPath /areas USER_RIGHTS 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        msg_success "SeInteractiveLogonRight aplicado. GRP_AdminDelegados puede hacer login local."
        Write-Log SUCCESS "SeInteractiveLogonRight: GRP_AdminDelegados agregado via secedit"
    }
    else {
        msg_alert "secedit /configure retorno codigo $LASTEXITCODE."
    }

    & gpupdate /force /quiet 2>&1 | Out-Null
    return $true
}

# ---------------------------------------------------------------------------
# Set-RBACDelegation
# ---------------------------------------------------------------------------
function Set-RBACDelegation {
    draw_header "Configurando Delegacion RBAC"
    Write-Log INFO "=== INICIO RBAC DELEGATION ==="

    $domainNC = $script:AD_DOMAIN_DN

    $sidMap = @{}
    foreach ($rol in $script:VALID_ROLES) {
        $grpName = "GRP_Role_$rol"
        try {
            $sid = (Get-ADGroup $grpName -ErrorAction Stop).SID.Value
            $sidMap[$rol] = $sid
            msg_info "SID $grpName : $sid"
        }
        catch {
            msg_alert "Grupo $grpName no encontrado."
        }
    }

    # IAMOperator
    msg_info "Configurando IAMOperator (admin_identidad)..."
    foreach ($ouName in @("Cuates", "NoCuates")) {
        $ouDN = "OU=$ouName,$domainNC"
        $aclsIAM = @(
            "dsacls `"$ouDN`" /I:T /G `"$($sidMap['IAMOperator']):CC;user`"",
            "dsacls `"$ouDN`" /I:S /G `"$($sidMap['IAMOperator']):DC;user`"",
            "dsacls `"$ouDN`" /I:S /G `"$($sidMap['IAMOperator']):RP;;user`"",
            "dsacls `"$ouDN`" /I:S /G `"$($sidMap['IAMOperator']):WP;displayName;user`"",
            "dsacls `"$ouDN`" /I:S /G `"$($sidMap['IAMOperator']):WP;telephoneNumber;user`"",
            "dsacls `"$ouDN`" /I:S /G `"$($sidMap['IAMOperator']):WP;physicalDeliveryOfficeName;user`"",
            "dsacls `"$ouDN`" /I:S /G `"$($sidMap['IAMOperator']):WP;mail;user`"",
            "dsacls `"$ouDN`" /I:S /G `"$($sidMap['IAMOperator']):CA;Reset Password;user`"",
            "dsacls `"$ouDN`" /I:S /G `"$($sidMap['IAMOperator']):WP;lockoutTime;user`""
        )
        foreach ($cmd in $aclsIAM) {
            try { Invoke-Expression $cmd | Out-Null } catch {}
        }
        msg_success "ACLs IAMOperator en $ouName listas."
    }

    # StorageOperator
    msg_info "Configurando StorageOperator (DENY Reset Password)..."
    if ($sidMap.ContainsKey("StorageOperator")) {
        try {
            $denyCmd = "dsacls `"$domainNC`" /I:S /D `"$($sidMap['StorageOperator']):CA;Reset Password;user`""
            Invoke-Expression $denyCmd | Out-Null
            msg_success "DENY Reset Password aplicado a StorageOperator"
        }
        catch {}
    }

    # GPOCompliance
    msg_info "Configurando GPOCompliance (lectura dominio + write GPOs)..."
    if ($sidMap.ContainsKey("GPOCompliance")) {
        try {
            $readCmd = "dsacls `"$domainNC`" /I:T /G `"$($sidMap['GPOCompliance']):GR`""
            Invoke-Expression $readCmd | Out-Null
            $policiesDN = "CN=Policies,CN=System,$domainNC"
            $writeGPOCmd = "dsacls `"$policiesDN`" /I:T /G `"$($sidMap['GPOCompliance']):GW`""
            Invoke-Expression $writeGPOCmd | Out-Null
            msg_success "GPOCompliance configurado."
        }
        catch {}
    }

    # SecurityAuditor
    msg_info "Configurando SecurityAuditor (solo lectura)..."
    if ($sidMap.ContainsKey("SecurityAuditor")) {
        try {
            $readOnlyCmd = "dsacls `"$domainNC`" /I:T /G `"$($sidMap['SecurityAuditor']):GR`""
            Invoke-Expression $readOnlyCmd | Out-Null
            msg_success "SecurityAuditor configurado."

            $evtGrp = "Event Log Readers"
            $allAdmins = Get-ADGroupMember "GRP_Role_SecurityAuditor" -EA Stop | Where-Object { $_.objectClass -eq "user" }
            foreach ($admin in $allAdmins) {
                try {
                    Add-LocalGroupMember -Group $evtGrp -Member "$script:AD_NETBIOS\$($admin.SamAccountName)" -EA SilentlyContinue
                }
                catch {}
            }
        }
        catch {}
    }

    Set-DCInteractiveLogon | Out-Null
    msg_success "Delegacion RBAC configurada."
    Write-Log SUCCESS "=== FIN RBAC DELEGATION ==="
    return $true
}

function Add-AdminRole {
    param([string]$SamAccount, [string]$Rol)
    if ($Rol -notin $script:VALID_ROLES) { msg_error "Rol invalido"; return }
    try { Add-ADGroupMember -Identity "GRP_Role_$Rol" -Members $SamAccount -EA Stop; msg_success "Rol '$Rol' agregado." } catch { msg_error "Error: $_" }
}

function Remove-AdminRole {
    param([string]$SamAccount, [string]$Rol)
    if ($Rol -notin $script:VALID_ROLES) { msg_error "Rol invalido"; return }
    try { Remove-ADGroupMember -Identity "GRP_Role_$Rol" -Members $SamAccount -Confirm:$false -EA Stop; msg_success "Rol '$Rol' removido." } catch { msg_error "Error: $_" }
}

function Get-AdminRoles {
    param([string]$SamAccount)
    $activeRoles = @()
    foreach ($rol in $script:VALID_ROLES) {
        try {
            if (Get-ADGroupMember "GRP_Role_$rol" -EA SilentlyContinue | Where-Object { $_.SamAccountName -eq $SamAccount }) {
                $activeRoles += $rol
            }
        }
        catch {}
    }
    return $activeRoles
}


# ---------------------------------------------------------------------------
# New-AdminBulkP9
# Crea los 4 administradores delegados de la Practica 9 en un solo paso.
# Solicita una password unica para todos (min 12 chars - FGPP-Admins).
# Idempotente: omite los que ya existen.
# ---------------------------------------------------------------------------
function New-AdminBulkP9 {
    draw_header "Alta masiva: administradores P09"

    if (-not $script:AD_DOMAIN_DN) {
        msg_error "No hay conexion al dominio."
        return $false
    }

    # Verificar que OU=Admins existe
    $adminOUDN = "OU=Admins,$script:AD_DOMAIN_DN"
    try {
        Get-ADOrganizationalUnit -Identity $adminOUDN -ErrorAction Stop | Out-Null
    }
    catch {
        msg_alert "OU=Admins no encontrada. Ejecuta primero 'Opcion 1 -> Gestion AD' para crearla."
        return $false
    }

    # Solicitar password unica para los 4 admins
    msg_info "Se crearan los 4 admins delegados de la Practica 09:"
    msg_info "  admin_identidad  (IAMOperator)"
    msg_info "  admin_storage    (StorageOperator)"
    msg_info "  admin_politicas  (GPOCompliance)"
    msg_info "  admin_auditoria  (SecurityAuditor)"
    Write-Host ""
    msg_alert "La politica FGPP-Admins exige minimo 12 caracteres con mayusculas, minusculas, numeros y simbolo."
    Write-Host ""

    Write-Host "  Password para los 4 admins (se ocultara): " -NoNewline -ForegroundColor Cyan
    $passValue = Read-Host -AsSecureString
    $pass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($passValue)
    )

    if ($pass.Length -lt 12) {
        msg_error "Password demasiado corta (min 12 caracteres)."
        return $false
    }

    # Confirmar
    Write-Host "  Confirmar password: " -NoNewline -ForegroundColor Cyan
    $passConf = Read-Host -AsSecureString
    $passC = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($passConf)
    )
    if ($pass -ne $passC) {
        msg_error "Las contrasenas no coinciden."
        return $false
    }

    $secPass = ConvertTo-SecureString $pass -AsPlainText -Force

    $admins = @(
        @{ Sam = "admin_identidad"; Name = "Admin Identidad y Acceso";        Rol = "IAMOperator"     }
        @{ Sam = "admin_storage";   Name = "Admin Almacenamiento y Recursos";  Rol = "StorageOperator" }
        @{ Sam = "admin_politicas"; Name = "Admin Cumplimiento y Directivas";  Rol = "GPOCompliance"   }
        @{ Sam = "admin_auditoria"; Name = "Auditor de Seguridad";             Rol = "SecurityAuditor" }
    )

    $created = 0; $skipped = 0; $failed = 0

    foreach ($a in $admins) {
        $existUser = Get-ADUser -Filter "SamAccountName -eq '$($a.Sam)'" -SearchBase $script:AD_DOMAIN_DN -EA SilentlyContinue
        if ($existUser) {
            msg_info "Ya existe: $($a.Sam) (omitido)"
            $skipped++
        }
        else {
            try {
                New-ADUser `
                    -SamAccountName        $a.Sam `
                    -UserPrincipalName     "$($a.Sam)@$script:AD_DOMAIN" `
                    -DisplayName           $a.Name `
                    -Name                  $a.Name `
                    -Department            "Admins" `
                    -AccountPassword       $secPass `
                    -Path                  $adminOUDN `
                    -Enabled               $true `
                    -PasswordNeverExpires   $true `
                    -ChangePasswordAtLogon  $false `
                    -ErrorAction Stop
                msg_success "Creado: $($a.Sam)"
                Write-Log SUCCESS "Admin P09 creado: $($a.Sam)"
                $created++
            }
            catch {
                msg_error "Error creando $($a.Sam): $_"
                Write-Log ERROR "Error creando admin $($a.Sam): $_"
                $failed++
                continue
            }
        }

        # Agregar a GRP_AdminDelegados
        try {
            Add-ADGroupMember -Identity "GRP_AdminDelegados" -Members $a.Sam -EA Stop
        }
        catch {
            if ($_ -notmatch "already") {
                msg_alert "No se pudo agregar $($a.Sam) a GRP_AdminDelegados: $_"
            }
        }

        # Agregar al grupo de rol
        $rolGroup = "GRP_Role_$($a.Rol)"
        try {
            Add-ADGroupMember -Identity $rolGroup -Members $a.Sam -EA Stop
            msg_success "$($a.Sam) -> $rolGroup"
            Write-Log SUCCESS "$($a.Sam) asignado a $rolGroup"
        }
        catch {
            if ($_ -notmatch "already") {
                msg_alert "No se pudo asignar $($a.Sam) a $rolGroup"
            }
        }
    }

    Write-Host ""
    msg_success "Alta masiva completada: Creados=$created | Omitidos=$skipped | Fallidos=$failed"
    msg_info "Ejecuta 'Configurar delegacion RBAC' para aplicar las ACLs dsacls."
    return ($failed -eq 0)
}

# ---------------------------------------------------------------------------
# Invoke-RBACMenu
# ---------------------------------------------------------------------------
function Invoke-RBACMenu {
    while ($true) {
        Show-Banner
        draw_header "Administradores Delegados - RBAC P09"

        try {
            $admins = Get-ADGroupMember "GRP_AdminDelegados" -EA SilentlyContinue | Where-Object { $_.objectClass -eq "user" }
            if ($admins) {
                Write-Host "  Administradores registrados:"
                foreach ($a in $admins) {
                    $roles = Get-AdminRoles -SamAccount $a.SamAccountName
                    $rolesStr = if ($roles.Count -gt 0) { $roles -join ", " } else { "Sin roles" }
                    Write-Host "  ● $($a.SamAccountName)  [$rolesStr]" -ForegroundColor Green
                }
            }
            else {
                msg_alert "No hay administradores delegados creados aun."
            }
        }
        catch {}

        Write-Host ""
        Write-Host "    [A]  Crear los 4 admins de Practica 09 (alta masiva)"
        Write-Host "    [1]  Crear admin interactivamente"
        Write-Host "    [2]  Configurar delegacion RBAC (ACLs)"
        Write-Host "    [3]  Agregar rol a un admin"
        Write-Host "    [4]  Quitar rol a un admin"
        Write-Host "    [5]  Ver detalle de un admin"
        Write-Host "    [0]  Volver"
        Write-Host ""

        msg_input "Opcion: "
        $op = Read-Host

        switch ($op.Trim().ToUpper()) {
            "A" { New-AdminBulkP9 | Out-Null; msg_pause }
            "1" { New-AdminInteractivo | Out-Null; msg_pause }
            "2" {
                msg_alert "Esto configura ACLs en los contenedores del dominio."
                $confirm = Read-InputLoop -Prompt "Escriba 'SI' para continuar" -Validator { param($v) $v -eq "SI" }
                if ($confirm -eq "SI") { Set-RBACDelegation | Out-Null }
                msg_pause
            }
            "3" {
                $sam = Read-InputLoop -Prompt "Nombre de cuenta" -Validator { param($v) $v.Length -gt 0 }
                if ($sam) {
                    $rolSel = Read-Selection -Prompt "Selecciona el rol a agregar" -Options $script:VALID_ROLES -AllowBack $true
                    if ($rolSel) { Add-AdminRole -SamAccount $sam -Rol $rolSel.Value }
                }
                msg_pause
            }
            "4" {
                $sam = Read-InputLoop -Prompt "Nombre de cuenta" -Validator { param($v) $v.Length -gt 0 }
                if ($sam) {
                    $current = Get-AdminRoles -SamAccount $sam
                    if ($current.Count -gt 0) {
                        $rolSel = Read-Selection -Prompt "Selecciona el rol a quitar" -Options $current -AllowBack $true
                        if ($rolSel) { Remove-AdminRole -SamAccount $sam -Rol $rolSel.Value }
                    } else {
                        msg_alert "El administrador '$sam' no tiene roles asignados actualmente."
                    }
                }
                msg_pause
            }
            "5" {
                $sam = Read-InputLoop -Prompt "Nombre de cuenta" -Validator { param($v) $v.Length -gt 0 }
                if ($sam) {
                    try {
                        $u = Get-ADUser $sam -Properties * -EA Stop
                        msg_info "Cuenta:  $($u.SamAccountName)"
                        msg_info "Nombre:  $($u.DisplayName)"
                        msg_info "Activo:  $($u.Enabled)"
                        $rs = Get-AdminRoles -SamAccount $sam
                        msg_info "Roles:   $(if ($rs) { $rs -join ', ' } else { 'ninguno' })"
                    }
                    catch { msg_error "No encontrado." }
                }
                msg_pause
            }
            "0" { return }
            default { msg_alert "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}