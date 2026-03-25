# =============================================================================
# ac_manager.ps1 — Orquestador principal de AC Manager
# Uso: .\ac_manager.ps1
# Ejecutar en: SRV-DC01 (Windows Server 2022) como Administrador
# =============================================================================

#Requires -Version 5.1
#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# RUTAS BASE
# -----------------------------------------------------------------------------
$script:ROOT_PATH   = $PSScriptRoot
$script:LIB_PATH    = Join-Path $ROOT_PATH 'lib'
$script:AC_LIB_PATH = Join-Path $ROOT_PATH 'ac_lib'

# Exportar para uso en scripts de cliente
$env:AC_LIB_PATH = $script:AC_LIB_PATH

# -----------------------------------------------------------------------------
# VERSION
# -----------------------------------------------------------------------------
$script:AC_VERSION  = '1.0.0'
$script:AC_NAME     = 'AC Manager'
$script:AC_DATE     = '2025-03-20'

# -----------------------------------------------------------------------------
# CARGA DE MODULOS
# Orden estricto: ui -> utils -> input -> log -> modulos AC
# -----------------------------------------------------------------------------

function Import-ACModules {
    $failed = @()

    $mods = @(
        "$script:LIB_PATH\ui.ps1|UI|0"
        "$script:LIB_PATH\utils.ps1|Utils|0"
        "$script:LIB_PATH\input.ps1|Input|0"
        "$script:AC_LIB_PATH\ac_log.ps1|Logger|0"
        "$script:AC_LIB_PATH\ac_ad.ps1|AD|0"
        "$script:AC_LIB_PATH\ac_csv.ps1|CSV|0"
        "$script:AC_LIB_PATH\ac_logon.ps1|Logon|0"
        "$script:AC_LIB_PATH\ac_fsrm.ps1|FSRM|0"
        "$script:AC_LIB_PATH\ac_applocker.ps1|AppLocker|0"
        "$script:AC_LIB_PATH\ac_rbac.ps1|RBAC|1"
        "$script:AC_LIB_PATH\ac_fgpp.ps1|FGPP|1"
        "$script:AC_LIB_PATH\ac_audit.ps1|Audit|1"
        "$script:AC_LIB_PATH\ac_mfa.ps1|MFA|1"
    )

    foreach ($entry in $mods) {
        $parts    = $entry -split '\|'
        $path     = $parts[0]
        $name     = $parts[1]
        $optional = $parts[2] -eq '1'

        if (Test-Path $path) {
            try {
                . $path
                Write-Host "  [  OK  ] $name"
            } catch {
                Write-Host "  [  ERR ] $name : $_"
                if (-not $optional) { $failed += $name }
            }
        } else {
            if ($optional) {
                Write-Host "  [  N/D ] $name (no disponible)"
            } else {
                Write-Host "  [  --- ] $name : no encontrado en $path"
                $failed += $name
            }
        }
    }

    return $failed
}

# -----------------------------------------------------------------------------
# VERIFICACION DE PREREQUISITES
# Comprueba los requisitos del entorno antes de mostrar el menu.
# -----------------------------------------------------------------------------

function Test-Prerequisites {
    $results  = [System.Collections.Generic.List[hashtable]]::new()
    $critical = $false

    # ── PowerShell version ────────────────────────────────────────────────────
    $psVer = $PSVersionTable.PSVersion
    $psOK  = $psVer.Major -ge 5 -and ($psVer.Major -gt 5 -or $psVer.Minor -ge 1)
    $results.Add(@{ Item = "PowerShell >= 5.1";      OK = $psOK;  Value = "$psVer";          Critical = $true })
    if (-not $psOK) { $critical = $true }

    # ── Privilegios de administrador ──────────────────────────────────────────
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $results.Add(@{ Item = "Ejecutando como Administrador"; OK = $isAdmin; Value = $(if ($isAdmin) { 'Si' } else { 'No' }); Critical = $true })
    if (-not $isAdmin) { $critical = $true }

    # ── Modulo Active Directory ───────────────────────────────────────────────
    $adMod = [bool](Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
    $results.Add(@{ Item = "Modulo ActiveDirectory";  OK = $adMod; Value = $(if ($adMod) { 'Disponible' } else { 'No encontrado' }); Critical = $true })
    if (-not $adMod) { $critical = $true }

    # ── Modulo GroupPolicy ────────────────────────────────────────────────────
    $gpMod = [bool](Get-Module -ListAvailable -Name GroupPolicy -ErrorAction SilentlyContinue)
    $results.Add(@{ Item = "Modulo GroupPolicy";       OK = $gpMod; Value = $(if ($gpMod) { 'Disponible' } else { 'No encontrado' }); Critical = $false })

    # ── Servicio AD DS ────────────────────────────────────────────────────────
    $adSvcObj = Get-Service -Name 'NTDS' -ErrorAction SilentlyContinue
    $adSvc    = ($null -ne $adSvcObj -and $adSvcObj.Status -eq 'Running')
    $results.Add(@{ Item = "Servicio AD DS (NTDS)";   OK = $adSvc; Value = $(if ($adSvc) { 'Running' } else { 'No activo' }); Critical = $true })
    if (-not $adSvc) { $critical = $true }

    # ── Servicio DNS ──────────────────────────────────────────────────────────
    $dnsSvcObj = Get-Service -Name 'DNS' -ErrorAction SilentlyContinue
    $dnsSvc    = ($null -ne $dnsSvcObj -and $dnsSvcObj.Status -eq 'Running')
    $results.Add(@{ Item = "Servicio DNS";             OK = $dnsSvc; Value = $(if ($dnsSvc) { 'Running' } else { 'No activo' }); Critical = $false })

    # ── FSRM instalado ────────────────────────────────────────────────────────
    $fsrmFeature = Get-WindowsFeature -Name 'FS-Resource-Manager' -ErrorAction SilentlyContinue
    $fsrm        = ($null -ne $fsrmFeature -and $fsrmFeature.InstallState -eq 'Installed')
    $results.Add(@{ Item = "Rol FSRM";                 OK = $fsrm;  Value = $(if ($fsrm) { 'Instalado' } else { 'No instalado (se instalara al usar)' }); Critical = $false })

    # ── AppIdSvc ──────────────────────────────────────────────────────────────
    $appIdObj = Get-Service -Name 'AppIdSvc' -ErrorAction SilentlyContinue
    $appId    = ($null -ne $appIdObj -and $appIdObj.Status -eq 'Running')
    $results.Add(@{ Item = "Servicio AppIdSvc";        OK = $appId; Value = $(if ($appId) { 'Running' } else { 'No activo (se activara al usar AppLocker)' }); Critical = $false })

    # ── Espacio en disco ──────────────────────────────────────────────────────
    try {
        $disk   = Get-PSDrive -Name C -ErrorAction Stop
        $freeGB = [Math]::Round($disk.Free / 1GB, 1)
        $diskOK = $freeGB -ge 1
        $results.Add(@{ Item = "Espacio libre en C:";  OK = $diskOK; Value = "$freeGB GB"; Critical = $false })
    } catch {
        $results.Add(@{ Item = "Espacio libre en C:";  OK = $false; Value = "No determinado"; Critical = $false })
    }

    # ── Mostrar resultados ────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  Verificacion de prerequisites:" -ForegroundColor Cyan
    Write-Host ""
    foreach ($r in $results) {
        $icon  = if ($r.OK) { "[  OK  ]" } else { if ($r.Critical) { "[ FAIL ]" } else { "[ WARN ]" } }
        $color = if ($r.OK) { 'Green'    } else { if ($r.Critical) { 'Red'      } else { 'Yellow'  } }
        Write-Host "    " -NoNewline
        Write-Host $icon -ForegroundColor $color -NoNewline
        Write-Host " $($r.Item.PadRight(35)) $($r.Value)"
    }
    Write-Host ""

    return @{ Critical = $critical; Results = $results }
}

# -----------------------------------------------------------------------------
# PANTALLA DE BIENVENIDA
# -----------------------------------------------------------------------------

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║                                                          ║" -ForegroundColor Cyan
    Write-Host "  ║   " -ForegroundColor Cyan -NoNewline
    Write-Host "  AC MANAGER  " -ForegroundColor White -NoNewline
    Write-Host "v$script:AC_VERSION                                   " -ForegroundColor DarkGray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║   " -ForegroundColor Cyan -NoNewline
    Write-Host "  Administracion de Dominio Active Directory           " -ForegroundColor Gray -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║                                                          ║" -ForegroundColor Cyan
    Write-Host "  ║   " -ForegroundColor Cyan -NoNewline
    Write-Host "  Server  : " -ForegroundColor DarkGray -NoNewline
    Write-Host "$($env:COMPUTERNAME)$((' ' * [Math]::Max(0, 36 - $env:COMPUTERNAME.Length)))    " -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║   " -ForegroundColor Cyan -NoNewline
    Write-Host "  Usuario : " -ForegroundColor DarkGray -NoNewline
    Write-Host "$($env:USERNAME)$((' ' * [Math]::Max(0, 36 - $env:USERNAME.Length)))    " -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║   " -ForegroundColor Cyan -NoNewline
    Write-Host "  Fecha   : " -ForegroundColor DarkGray -NoNewline
    $dateStr = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Write-Host "$dateStr$((' ' * [Math]::Max(0, 36 - $dateStr.Length)))    " -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    Write-Host "  ║                                                          ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

# -----------------------------------------------------------------------------
# INDICADORES DE ESTADO EN TIEMPO REAL
# Consultan AD en vivo — cada funcion devuelve icono coloreado
# -----------------------------------------------------------------------------

function Get-StatusIcon {
    param([bool] $Ok)
    if ($Ok) {
        Write-Host "●" -ForegroundColor Green -NoNewline
    } else {
        Write-Host "○" -ForegroundColor Red -NoNewline
    }
}

function Test-StatusAD {
    try { Get-ADDomain -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

function Test-StatusOUs {
    if (-not (Test-StatusAD)) { return $false }
    try {
        $dn = $script:AD_DOMAIN_DN
        $c  = Get-ADOrganizationalUnit -Filter "Name -eq 'Cuates'"   -SearchBase $dn -EA Stop
        $n  = Get-ADOrganizationalUnit -Filter "Name -eq 'NoCuates'" -SearchBase $dn -EA Stop
        return ($null -ne $c -and $null -ne $n)
    } catch { return $false }
}

function Test-StatusUsers {
    try {
        $c = @(Get-ADGroupMember 'GRP_Cuates'   -EA Stop).Count
        $n = @(Get-ADGroupMember 'GRP_NoCuates' -EA Stop).Count
        return ($c -gt 0 -and $n -gt 0)
    } catch { return $false }
}

function Test-StatusLogonHours {
    try {
        $b = @(Get-ADUser -Filter * -SearchBase $script:AD_DOMAIN_DN `
              -Properties LogonHours -EA Stop | Where-Object { $null -ne $_.LogonHours }).Count
        return ($b -gt 0)
    } catch { return $false }
}

function Test-StatusFSRM {
    try {
        $f = Get-WindowsFeature -Name 'FS-Resource-Manager' -EA Stop
        if ($f.InstallState -ne 'Installed') { return $false }
        $q = Get-FsrmQuota -EA SilentlyContinue | Select-Object -First 1
        return ($null -ne $q)
    } catch { return $false }
}

function Test-StatusAppLocker {
    try {
        $g1 = Get-GPO -Name 'AppLocker-Cuates-T08'   -EA SilentlyContinue
        $g2 = Get-GPO -Name 'AppLocker-NoCuates-T08' -EA SilentlyContinue
        return ($null -ne $g1 -and $null -ne $g2)
    } catch { return $false }
}

function Test-StatusAppIDSvc {
    $s = Get-Service -Name 'AppIdSvc' -EA SilentlyContinue
    return ($null -ne $s -and $s.Status -eq 'Running')
}

# -----------------------------------------------------------------------------
# MENU PRINCIPAL con indicadores de estado en tiempo real
# -----------------------------------------------------------------------------

function Show-MainMenu {
    $domainInfo = if ($script:AD_DOMAIN) { $script:AD_DOMAIN } else { "No conectado" }
    $logInfo    = if ($script:LOG_PATH)  { [System.IO.Path]::GetFileName($script:LOG_PATH) } else { "Sin log" }

    Write-Host "  " -NoNewline
    Write-Host "Dominio: " -ForegroundColor DarkGray -NoNewline
    Write-Host $domainInfo -ForegroundColor $(if ($script:AD_DOMAIN) { 'Green' } else { 'Yellow' }) -NoNewline
    Write-Host "   Log: " -ForegroundColor DarkGray -NoNewline
    Write-Host $logInfo -ForegroundColor $(if ($script:LOG_PATH) { 'Green' } else { 'Yellow' })
    Write-Host ""

    # Calcular indicadores una vez
    if ($script:AD_DOMAIN_DN) {
        $stAD    = Test-StatusAD
        $stOUs   = Test-StatusOUs
        $stUsers = Test-StatusUsers
        $stLH    = Test-StatusLogonHours
        $stFSRM  = Test-StatusFSRM
        $stAL    = Test-StatusAppLocker
        $stSvc   = Test-StatusAppIDSvc
    } else {
        $stAD = $stOUs = $stUsers = $stLH = $stFSRM = $stAL = $stSvc = $false
    }

    # ── Parte 1 ───────────────────────────────────────────────────────────────
    Write-Host "  " -NoNewline
    Write-Host "[ PARTE 1 — Gestion de Recursos ]" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "    [1]  " -NoNewline
    Get-StatusIcon $stOUs;  Write-Host "  " -NoNewline
    Get-StatusIcon $stUsers
    Write-Host "  Gestion de Active Directory    " -NoNewline
    Write-Host "(OUs, Usuarios, Grupos, CSV/ABC)" -ForegroundColor DarkGray

    Write-Host "    [2]  " -NoNewline
    Get-StatusIcon $stLH
    Write-Host "     Control de Acceso Temporal     " -NoNewline
    Write-Host "(Logon Hours + GPO cierre de sesion)" -ForegroundColor DarkGray

    Write-Host "    [3]  " -NoNewline
    Get-StatusIcon $stFSRM
    Write-Host "     Gestion de Almacenamiento      " -NoNewline
    Write-Host "(FSRM: cuotas, file screening)" -ForegroundColor DarkGray

    Write-Host "    [4]  " -NoNewline
    Get-StatusIcon $stAL; Write-Host " " -NoNewline
    Get-StatusIcon $stSvc
    Write-Host "  Control de Ejecucion           " -NoNewline
    Write-Host "(AppLocker: reglas por grupo)" -ForegroundColor DarkGray

    Write-Host ""

    # ── Parte 2 ───────────────────────────────────────────────────────────────
    Write-Host "  " -NoNewline
    Write-Host "[ PARTE 2 — Hardening y Seguridad ]" -ForegroundColor Cyan
    Write-Host ""

    $p2Modules = @(
        @{ Num = '5'; Label = 'Delegacion de Control         '; Desc = '(RBAC: 4 roles delegados, ACLs)';    Mod = 'Invoke-RBACMenu'  }
        @{ Num = '6'; Label = 'Directivas de Contrasena      '; Desc = '(FGPP: admins 12 / estandar 8)';    Mod = 'Invoke-FGPPMenu'  }
        @{ Num = '7'; Label = 'Auditoria de Eventos          '; Desc = '(auditpol, extraccion eventos)';     Mod = 'Invoke-AuditMenu' }
        @{ Num = '8'; Label = 'Autenticacion MFA             '; Desc = '(multiOTP + Google Authenticator)';  Mod = 'Invoke-MFAMenu'   }
    )

    foreach ($item in $p2Modules) {
        $available = [bool](Get-Command $item.Mod -ErrorAction SilentlyContinue)
        $color     = if ($available) { 'White' } else { 'DarkGray' }
        $status    = if ($available) { '' } else { ' [no disponible]' }
        Write-Host "    [$($item.Num)]  " -NoNewline
        Write-Host "$($item.Label)" -ForegroundColor $color -NoNewline
        Write-Host "$($item.Desc)$status" -ForegroundColor DarkGray
    }

    Write-Host ""

    # ── Utilidades ────────────────────────────────────────────────────────────
    Write-Host "  " -NoNewline
    Write-Host "[ UTILIDADES ]" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    [U]  Gestion de Usuarios          " -NoNewline
    Write-Host "(alta, baja, detalle, habilitar/deshabilitar)" -ForegroundColor DarkGray
    Write-Host "    [M]  Monitoreo del Dominio         " -NoNewline
    Write-Host "(cuotas, eventos FSRM, sesiones, cuentas)" -ForegroundColor DarkGray
    Write-Host "    [K]  Clientes del Dominio          " -NoNewline
    Write-Host "(Win10 + Linux, DNS, OU, LogonHours)" -ForegroundColor DarkGray
    Write-Host "    [V]  Verificacion General"
    Write-Host "    [9]  Ver logs del sistema"
    Write-Host "    [C]  Conectar / cambiar dominio"
    Write-Host "    [I]  Informacion del sistema"
    Write-Host "    [0]  Salir"
    Write-Host ""
    Write-Host "  ────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
}

# -----------------------------------------------------------------------------
# MENU USUARIOS — alta, baja, detalle, habilitar/deshabilitar, password
# -----------------------------------------------------------------------------
function Invoke-UsersMenu {
    while ($true) {
        Show-Banner
        draw_header "Gestion de Usuarios del Dominio"

        $cC = 0; $cN = 0
        try { $cC = @(Get-ADGroupMember 'GRP_Cuates'   -EA Stop).Count } catch {}
        try { $cN = @(Get-ADGroupMember 'GRP_NoCuates' -EA Stop).Count } catch {}
        msg_info "GRP_Cuates: $cC usuarios  |  GRP_NoCuates: $cN usuarios"
        Write-Host ""
        Write-Host "    [1]  Listar todos los usuarios"
        Write-Host "    [2]  Listar Cuates"
        Write-Host "    [3]  Listar NoCuates"
        Write-Host "    [4]  Alta de nuevo usuario"
        Write-Host "    [5]  Baja de usuario (deshabilitar)"
        Write-Host "    [6]  Ver detalle de un usuario"
        Write-Host "    [7]  Habilitar / Deshabilitar usuario"
        Write-Host "    [8]  Cambiar contrasena"
        Write-Host "    [0]  Volver"
        Write-Host ""

        msg_input "Opcion: "
        $op = Read-Host

        switch ($op.Trim()) {
            '1' {
                draw_header "Todos los Usuarios"
                Get-ADUser -Filter * -SearchBase $script:AD_DOMAIN_DN `
                    -Properties Department -EA SilentlyContinue |
                    Select-Object SamAccountName, Name, Department, Enabled |
                    Sort-Object Department, SamAccountName |
                    Format-Table -AutoSize
                msg_pause
            }
            '2' {
                draw_header "Usuarios Cuates"
                Get-ADGroupMember 'GRP_Cuates' -EA SilentlyContinue | ForEach-Object {
                    $u = Get-ADUser $_.SamAccountName -Properties Enabled -EA SilentlyContinue
                    if ($u) {
                        $c = if ($u.Enabled) { 'Green' } else { 'Red' }
                        Write-Host "  $($u.SamAccountName.PadRight(15)) $($u.Name.PadRight(25)) " -NoNewline
                        Write-Host $(if ($u.Enabled) { 'Activo' } else { 'Inactivo' }) -ForegroundColor $c
                    }
                }
                msg_pause
            }
            '3' {
                draw_header "Usuarios NoCuates"
                Get-ADGroupMember 'GRP_NoCuates' -EA SilentlyContinue | ForEach-Object {
                    $u = Get-ADUser $_.SamAccountName -Properties Enabled -EA SilentlyContinue
                    if ($u) {
                        $c = if ($u.Enabled) { 'Green' } else { 'Red' }
                        Write-Host "  $($u.SamAccountName.PadRight(15)) $($u.Name.PadRight(25)) " -NoNewline
                        Write-Host $(if ($u.Enabled) { 'Activo' } else { 'Inactivo' }) -ForegroundColor $c
                    }
                }
                msg_pause
            }
            '4' {
                draw_header "Alta de Nuevo Usuario"
                Invoke-ManualUserCreation
                msg_pause
            }
            '5' {
                draw_header "Baja de Usuario"
                $sam = Read-InputLoop -Prompt "Nombre de cuenta" `
                    -Validator { param($v) $v.Length -ge 2 } -ErrorMsg "Nombre invalido."
                if ($sam -eq $false) { msg_pause; break }
                $confirm = Read-InputLoop -Prompt "Confirma el nombre de cuenta" `
                    -Validator { param($v) $v -eq $sam } -ErrorMsg "No coincide."
                if ($confirm -eq $false) { msg_pause; break }
                try {
                    Disable-ADAccount -Identity $sam -EA Stop
                    Write-Log SUCCESS "Cuenta $sam deshabilitada."
                    msg_success "Cuenta $sam deshabilitada."
                    msg_info "Para eliminar permanentemente: Remove-ADUser $sam"
                } catch {
                    Write-Log ERROR "Error al deshabilitar $sam : $_"
                    msg_error "No se pudo deshabilitar la cuenta: $_"
                }
                msg_pause
            }
            '6' {
                draw_header "Detalle de Usuario"
                $sam = Read-InputLoop -Prompt "Nombre de cuenta" `
                    -Validator { param($v) $v.Length -ge 2 } -ErrorMsg "Nombre invalido."
                if ($sam -ne $false) { Show-UserDetail -SamAccountName $sam }
                msg_pause
            }
            '7' {
                draw_header "Habilitar / Deshabilitar"
                $sam = Read-InputLoop -Prompt "Nombre de cuenta" `
                    -Validator { param($v) $v.Length -ge 2 } -ErrorMsg "Nombre invalido."
                if ($sam -eq $false) { msg_pause; break }
                try {
                    $u = Get-ADUser $sam -Properties Enabled -EA Stop
                    if ($u.Enabled) {
                        Disable-ADAccount -Identity $sam -EA Stop
                        msg_success "Cuenta $sam deshabilitada."
                    } else {
                        Enable-ADAccount -Identity $sam -EA Stop
                        msg_success "Cuenta $sam habilitada."
                    }
                    Write-Log INFO "Toggle cuenta $sam : Enabled=$(-not $u.Enabled)"
                } catch {
                    msg_error "Error: $_"
                }
                msg_pause
            }
            '8' {
                draw_header "Cambiar Contrasena"
                $sam = Read-InputLoop -Prompt "Nombre de cuenta" `
                    -Validator { param($v) $v.Length -ge 2 } -ErrorMsg "Nombre invalido."
                if ($sam -eq $false) { msg_pause; break }
                $newPass = Read-SecureInput -Prompt "Nueva contrasena" -Confirm $true -MinLength 8
                if ($newPass -eq $false) { msg_pause; break }
                try {
                    Set-ADAccountPassword -Identity $sam -NewPassword $newPass -Reset -EA Stop
                    msg_success "Contrasena de $sam actualizada."
                    Write-Log SUCCESS "Contrasena cambiada para: $sam"
                } catch {
                    msg_error "Error: $_"
                }
                msg_pause
            }
            '0' { return }
            default { msg_alert "Opcion no valida."; Start-Sleep -Milliseconds 600 }
        }
    }
}

# -----------------------------------------------------------------------------
# Show-UserDetail — vista completa de un usuario individual
# Muestra LastLogonDate, estado LogonHours, OU, grupos, etc.
# -----------------------------------------------------------------------------
function Show-UserDetail {
    param([Parameter(Mandatory)] [string] $SamAccountName)

    try {
        $u = Get-ADUser $SamAccountName `
             -Properties DisplayName, UserPrincipalName, Department, Enabled,
                         LastLogonDate, LogonHours, DistinguishedName,
                         LockedOut, PasswordExpired, MemberOf `
             -ErrorAction Stop

        draw_header "Detalle: $($u.SamAccountName)"
        msg_info "Nombre:          $($u.DisplayName)"
        msg_info "UPN:             $($u.UserPrincipalName)"
        msg_info "Departamento:    $($u.Department)"
        msg_info "OU:              $($u.DistinguishedName)"

        $estadoCuenta = if ($u.Enabled) {
            Write-Host "  " -NoNewline
            Write-Host "[INFO]  " -ForegroundColor Blue -NoNewline
            Write-Host "Habilitado: " -NoNewline
            Write-Host "Si" -ForegroundColor Green
        } else {
            msg_alert "Habilitado: No"
        }

        if ($u.LockedOut)       { msg_alert "Cuenta BLOQUEADA" }
        if ($u.PasswordExpired) { msg_alert "Contrasena EXPIRADA" }

        $ultimoLogin = if ($u.LastLogonDate) {
            $u.LastLogonDate.ToString('yyyy-MM-dd HH:mm')
        } else { "(nunca)" }
        msg_info "Ultimo login:    $ultimoLogin"

        $tieneHoras = ($null -ne $u.LogonHours -and $u.LogonHours.Count -eq 21)
        $lhEstado   = if ($tieneHoras) { "Configurado (21 bytes)" } else { "Sin restriccion" }
        msg_info "LogonHours:      $lhEstado"

        if ($u.MemberOf -and $u.MemberOf.Count -gt 0) {
            msg_info "Grupos ($($u.MemberOf.Count)):"
            $u.MemberOf | ForEach-Object {
                $gname = ($_ -split ',')[0] -replace '^CN=',''
                Write-Host "                 • $gname"
            }
        }
    } catch {
        msg_error "Usuario '$SamAccountName' no encontrado: $_"
    }
}

# -----------------------------------------------------------------------------
# MENU MONITOREO — cuotas, eventos FSRM, sesiones, cuentas bloqueadas
# -----------------------------------------------------------------------------
function Invoke-MonitorMenu {
    while ($true) {
        Show-Banner
        draw_header "Monitoreo del Dominio"
        Write-Host ""
        Write-Host "    [1]  Uso de cuotas en tiempo real"
        Write-Host "    [2]  Eventos de bloqueo FSRM (archivos rechazados)"
        Write-Host "    [3]  Ultimos inicios de sesion"
        Write-Host "    [4]  Sesiones activas en el DC"
        Write-Host "    [5]  Usuarios con LogonHours configurados"
        Write-Host "    [6]  Cuentas bloqueadas o deshabilitadas"
        Write-Host "    [7]  GPOs del dominio"
        Write-Host "    [0]  Volver"
        Write-Host ""

        msg_input "Opcion: "
        $op = Read-Host

        switch ($op.Trim()) {
            '1' {
                draw_header "Uso de Cuotas en Tiempo Real"
                try {
                    $quotas = @(Get-FsrmQuota -EA Stop | Sort-Object Usage -Descending)
                    if ($quotas.Count -eq 0) {
                        msg_alert "No hay cuotas configuradas."
                    } else {
                        Write-Host ""
                        Write-Host ("  {0,-20} {1,-8} {2,-8} {3,-6}  {4}" -f `
                            "Usuario","Limite","Uso","Pct","Estado")
                        Write-Host "  ────────────────────────────────────────────────────"
                        foreach ($q in $quotas) {
                            $pct    = if ($q.Size -gt 0) { [Math]::Round(($q.Usage/$q.Size)*100,1) } else { 0 }
                            $limite = "$([Math]::Round($q.Size/1MB,0))MB"
                            $uso    = "$([Math]::Round($q.Usage/1KB,0))KB"
                            $user   = Split-Path $q.Path -Leaf
                            $color  = if ($pct -gt 90) { 'Red' } elseif ($pct -gt 70) { 'Yellow' } else { 'Green' }
                            $estado = if ($pct -gt 90) { 'CRITICO' } elseif ($pct -gt 70) { 'ADVERTENCIA' } else { 'OK' }
                            Write-Host ("  {0,-20} {1,-8} {2,-8} {3,-6}  " -f $user,$limite,$uso,"$pct%") -NoNewline
                            Write-Host $estado -ForegroundColor $color
                        }
                    }
                } catch {
                    msg_error "FSRM no disponible: $_"
                }
                msg_pause
            }
            '2' {
                draw_header "Eventos de Bloqueo FSRM"
                msg_process "Consultando log de FSRM..."
                try {
                    $events = @(Get-WinEvent -LogName 'Microsoft-Windows-FSRM/Operational' `
                        -MaxEvents 20 -EA Stop |
                        Where-Object { $_.Id -in @(8215, 8214, 8210) })
                    if ($events.Count -eq 0) {
                        msg_info "No hay eventos de bloqueo recientes."
                        msg_info "Los eventos ID 8215 aparecen cuando se rechaza un archivo."
                    } else {
                        $events | ForEach-Object {
                            $msg = $_.Message.Substring(0, [Math]::Min(80, $_.Message.Length))
                            Write-Host "  $($_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))  ID:$($_.Id)  $msg"
                        }
                    }
                } catch {
                    msg_alert "No se encontraron eventos FSRM (log puede estar vacio)."
                }
                msg_pause
            }
            '3' {
                draw_header "Ultimos Inicios de Sesion"
                try {
                    Get-ADUser -Filter * -SearchBase $script:AD_DOMAIN_DN `
                        -Properties LastLogonDate, Department -EA Stop |
                        Where-Object { $null -ne $_.LastLogonDate } |
                        Sort-Object LastLogonDate -Descending |
                        Select-Object -First 20 |
                        Select-Object SamAccountName, Name, Department, LastLogonDate |
                        Format-Table -AutoSize
                } catch {
                    msg_error "Error: $_"
                }
                msg_pause
            }
            '4' {
                draw_header "Sesiones Activas en el DC"
                msg_process "Consultando sesiones activas (query session)..."
                try {
                    query session 2>&1 | ForEach-Object { Write-Host "  $_" }
                } catch {
                    msg_alert "No se pudo obtener sesiones: $_"
                }
                msg_pause
            }
            '5' {
                draw_header "Estado de LogonHours por Usuario"
                try {
                    $users = Get-ADUser -Filter * -SearchBase $script:AD_DOMAIN_DN `
                        -Properties LogonHours, Department -EA Stop |
                        Sort-Object Department, SamAccountName

                    Write-Host ""
                    Write-Host ("  {0,-12} {1,-15} {2}" -f "Usuario","Departamento","LogonHours")
                    Write-Host "  ──────────────────────────────────────────"
                    foreach ($u in $users) {
                        $tieneHoras = ($null -ne $u.LogonHours -and $u.LogonHours.Count -eq 21)
                        $color      = if ($tieneHoras) { 'Green' } else { 'Yellow' }
                        $estado     = if ($tieneHoras) { "Configurado" } else { "Sin restriccion" }
                        Write-Host ("  {0,-12} {1,-15} " -f $u.SamAccountName,$u.Department) -NoNewline
                        Write-Host $estado -ForegroundColor $color
                    }
                } catch {
                    msg_error "Error: $_"
                }
                msg_pause
            }
            '6' {
                draw_header "Cuentas Bloqueadas o Deshabilitadas"
                try {
                    # Search-ADAccount -LockedOut es el metodo correcto.
                    # Get-ADUser -Filter { LockedOut -eq $true } NO funciona —
                    # LockedOut no es filtrable en LDAP.
                    $bloqueadas     = @(Search-ADAccount -LockedOut -SearchBase $script:AD_DOMAIN_DN `
                                        -EA SilentlyContinue)
                    $deshabilitadas = @(Get-ADUser -Filter { Enabled -eq $false } `
                                        -SearchBase $script:AD_DOMAIN_DN `
                                        -Properties Department -EA SilentlyContinue |
                                        Where-Object { $_.SamAccountName -notin @('Guest','krbtgt') })

                    $todas = @(($bloqueadas + $deshabilitadas) |
                             Sort-Object SamAccountName -Unique)

                    if ($todas.Count -eq 0) {
                        msg_success "No hay cuentas bloqueadas ni deshabilitadas."
                    } else {
                        Write-Host ""
                        foreach ($u in $todas) {
                            $full = Get-ADUser $u.SamAccountName `
                                    -Properties Enabled, LockedOut, Department `
                                    -EA SilentlyContinue
                            if ($full) {
                                Write-Host "  $($full.SamAccountName.PadRight(15)) $($full.Department.PadRight(12)) " -NoNewline
                                if ($full.LockedOut) {
                                    Write-Host "BLOQUEADA " -ForegroundColor Red -NoNewline
                                }
                                if (-not $full.Enabled) {
                                    Write-Host "DESHABILITADA" -ForegroundColor Yellow -NoNewline
                                }
                                Write-Host ""
                            }
                        }
                    }
                } catch {
                    msg_error "Error al consultar cuentas: $_"
                }
                msg_pause
            }
            '7' {
                draw_header "GPOs del Dominio"
                try {
                    Get-GPO -All -EA Stop |
                        Select-Object DisplayName, GpoStatus, CreationTime |
                        Format-Table -AutoSize
                } catch {
                    msg_error "Modulo GroupPolicy no disponible."
                }
                msg_pause
            }
            '0' { return }
            default { msg_alert "Opcion no valida."; Start-Sleep -Milliseconds 600 }
        }
    }
}

# -----------------------------------------------------------------------------
# MENU CLIENTES — detecta clientes desde AD, maneja DNS, OU, LogonHours
# -----------------------------------------------------------------------------
function Invoke-ClientsMenu {
    while ($true) {
        Show-Banner
        draw_header "Gestion de Clientes del Dominio"

        # Detectar clientes dinamicamente desde AD
        $domainDNS    = $script:AD_DOMAIN
        $allComputers = @(Get-ADComputer -Filter * -Properties OperatingSystem -EA SilentlyContinue |
                          Where-Object { $_.Name -ne $env:COMPUTERNAME })

        $linuxClients = @($allComputers | Where-Object {
            $_.OperatingSystem -like '*Linux*'   -or
            $_.OperatingSystem -like '*Fedora*'  -or
            $_.OperatingSystem -like '*Ubuntu*'  -or
            $_.OperatingSystem -like '*Red Hat*'
        })
        $win10Clients = @($allComputers | Where-Object {
            $_.OperatingSystem -like '*Windows 10*' -or
            $_.OperatingSystem -like '*Windows 11*' -or
            ($_.OperatingSystem -notlike '*Server*' -and $_.OperatingSystem -notlike '*Linux*' -and
             $_.OperatingSystem -notlike '*Fedora*')
        })

        if ($linuxClients.Count -eq 0 -and $win10Clients.Count -eq 0) {
            $win10Clients = $allComputers
        }

        # Grupo activo segun hora actual
        $hora = (Get-Date).Hour
        if ($hora -ge 8 -and $hora -lt 15) {
            $grupoActivo = "GRP_Cuates (8AM-3PM)"
            $grupoColor  = 'Green'
        } elseif ($hora -ge 15 -or $hora -lt 2) {
            $grupoActivo = "GRP_NoCuates (3PM-2AM)"
            $grupoColor  = 'Cyan'
        } else {
            $grupoActivo = "Fuera de horario (2AM-8AM)"
            $grupoColor  = 'Yellow'
        }

        msg_info "Hora actual: $(Get-Date -Format 'HH:mm')   Grupo activo: " -NoNewline 2>$null
        Write-Host $grupoActivo -ForegroundColor $grupoColor
        Write-Host ""

        # Mostrar clientes con estado de conectividad DNS
        foreach ($c in $linuxClients) {
            $ok = $null -ne (Resolve-DnsName "$($c.Name).$domainDNS" -EA SilentlyContinue)
            Write-Host "  " -NoNewline
            Write-Host $(if ($ok) { "●" } else { "○" }) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' }) -NoNewline
            Write-Host "  Linux   $($c.Name)"
        }
        foreach ($c in $win10Clients) {
            $ok = $null -ne (Resolve-DnsName "$($c.Name).$domainDNS" -EA SilentlyContinue)
            $ou = if ($c.DistinguishedName) { ($c.DistinguishedName -split ',')[1] -replace 'OU=','' } else { '?' }
            Write-Host "  " -NoNewline
            Write-Host $(if ($ok) { "●" } else { "○" }) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' }) -NoNewline
            Write-Host "  Win10   $($c.Name)  (OU=$ou)"
        }

        $win10Name = if ($win10Clients.Count -gt 0) { $win10Clients[0].Name } else { $null }

        Write-Host ""
        Write-Host "    [1]  Registrar cliente Linux en DNS del DC"
        Write-Host "    [2]  Registrar cliente Windows 10 en DNS del DC"
        Write-Host "    [3]  Mover equipo Win10 a OU segun hora actual"
        Write-Host "    [4]  Quitar LogonHours temporalmente (para probar AppLocker)"
        Write-Host "    [5]  Restaurar LogonHours"
        Write-Host "    [6]  Ver estado del equipo Win10 en AD"
        Write-Host "    [0]  Volver"
        Write-Host ""

        msg_input "Opcion: "
        $op = Read-Host

        switch ($op.Trim()) {
            '1' {
                draw_header "Registrar Cliente Linux en DNS"
                $clientName = Read-InputLoop -Prompt "Nombre del cliente Linux (ej: LNX-CLIENT01)" `
                    -Validator { param($v) $v.Length -ge 3 } -ErrorMsg "Nombre invalido."
                if ($clientName -eq $false) { msg_pause; break }
                $clientIP = Read-InputLoop -Prompt "IP del cliente Linux" `
                    -Validator { param($v) $v -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' } `
                    -ErrorMsg "IP invalida."
                if ($clientIP -eq $false) { msg_pause; break }
                try {
                    $existing = Get-DnsServerResourceRecord -ZoneName $domainDNS `
                        -Name $clientName -RRType A -EA SilentlyContinue
                    if ($existing) {
                        Remove-DnsServerResourceRecord -ZoneName $domainDNS `
                            -Name $clientName -RRType A -Force -EA SilentlyContinue
                    }
                    Add-DnsServerResourceRecordA -ZoneName $domainDNS `
                        -Name $clientName -IPv4Address $clientIP `
                        -TimeToLive '01:00:00' -EA Stop
                    msg_success "DNS registrado: $clientName.$domainDNS -> $clientIP"
                    Write-Log SUCCESS "DNS Linux registrado: $clientName -> $clientIP"
                } catch {
                    msg_error "Error: $_"
                }
                msg_pause
            }
            '2' {
                draw_header "Registrar Cliente Windows 10 en DNS"
                $cName = Read-InputLoop -Prompt "Nombre del equipo Win10 (ej: WIN-CLIENT01)" `
                    -Validator { param($v) $v.Length -ge 3 } -ErrorMsg "Nombre invalido."
                if ($cName -eq $false) { msg_pause; break }
                $cIP = Read-InputLoop -Prompt "IP del cliente Windows 10" `
                    -Validator { param($v) $v -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$' } `
                    -ErrorMsg "IP invalida."
                if ($cIP -eq $false) { msg_pause; break }
                try {
                    $existing = Get-DnsServerResourceRecord -ZoneName $domainDNS `
                        -Name $cName -RRType A -EA SilentlyContinue
                    if ($existing) {
                        Remove-DnsServerResourceRecord -ZoneName $domainDNS `
                            -Name $cName -RRType A -Force -EA SilentlyContinue
                    }
                    Add-DnsServerResourceRecordA -ZoneName $domainDNS `
                        -Name $cName -IPv4Address $cIP -TimeToLive '01:00:00' -EA Stop
                    msg_success "DNS registrado: $cName.$domainDNS -> $cIP"
                    Write-Log SUCCESS "DNS Win10 registrado: $cName -> $cIP"
                } catch {
                    msg_error "Error: $_"
                }
                msg_pause
            }
            '3' {
                draw_header "Mover Win10 a OU segun Hora Actual"
                if ($null -eq $win10Name) {
                    msg_error "No hay equipos Win10 registrados en AD."
                    msg_pause; break
                }
                $horaAhora = (Get-Date).Hour
                $ouTarget  = if ($horaAhora -ge 8 -and $horaAhora -lt 15) {
                    "OU=Cuates,$script:AD_DOMAIN_DN"
                } else {
                    "OU=NoCuates,$script:AD_DOMAIN_DN"
                }
                $ouName = if ($horaAhora -ge 8 -and $horaAhora -lt 15) { "Cuates" } else { "NoCuates" }
                msg_info "Hora: $(Get-Date -Format 'HH:mm')  ->  Moviendo a OU=$ouName"
                try {
                    $comp = Get-ADComputer $win10Name -EA Stop
                    if ($comp.DistinguishedName -like "*$ouTarget*") {
                        msg_info "El equipo ya esta en OU=$ouName"
                    } else {
                        Move-ADObject -Identity $comp.DistinguishedName -TargetPath $ouTarget -EA Stop
                        msg_success "Equipo $win10Name movido a OU=$ouName"
                        msg_info "Ejecuta 'gpupdate /force' en el cliente Win10."
                    }
                } catch {
                    msg_error "Error: $_"
                }
                msg_pause
            }
            '4' {
                draw_header "Quitar LogonHours (Prueba AppLocker)"
                msg_alert "Esto elimina las restricciones horarias de TODOS los usuarios."
                msg_alert "Los usuarios podran iniciar sesion a cualquier hora."
                $confirm = Read-InputLoop -Prompt "Escribe 'SI' para confirmar" `
                    -Validator { param($v) $v -eq 'SI' } -ErrorMsg "Escribe exactamente SI."
                if ($confirm -eq $false) { msg_pause; break }
                try {
                    $users = Get-ADUser -Filter * -SearchBase $script:AD_DOMAIN_DN `
                             -Properties LogonHours -EA Stop |
                             Where-Object { $null -ne $_.LogonHours }
                    $ok = 0
                    foreach ($u in $users) {
                        $dn   = $u.DistinguishedName
                        $de   = New-Object DirectoryServices.DirectoryEntry("LDAP://$dn")
                        $de.Properties["logonHours"].Clear()
                        $de.CommitChanges()
                        $de.Dispose()
                        $ok++
                    }
                    msg_success "LogonHours eliminados de $ok usuarios."
                    msg_alert "Recuerda restaurarlos con la opcion 5."
                    Write-Log WARN "LogonHours temporalmente eliminados de $ok usuarios para pruebas."
                } catch {
                    msg_error "Error: $_"
                }
                msg_pause
            }
            '5' {
                draw_header "Restaurar LogonHours"
                msg_process "Restaurando horarios originales..."
                $ok1 = Clear-LogonHours -TargetType Group -TargetName 'GRP_Cuates'
                $ok1 = Set-LogonHoursGroup -GroupName 'GRP_Cuates'   -LogonBytes `
                       (ConvertTo-LogonHoursBytes -StartHourLocal 8  -EndHourLocal 15 `
                        -UTCOffset (Get-UTCOffset))
                $ok2 = Set-LogonHoursGroup -GroupName 'GRP_NoCuates' -LogonBytes `
                       (ConvertTo-LogonHoursBytes -StartHourLocal 15 -EndHourLocal 2 `
                        -UTCOffset (Get-UTCOffset))
                if ($ok1 -and $ok2) {
                    msg_success "Restaurados: Cuates 8AM-3PM | NoCuates 3PM-2AM"
                    Write-Log SUCCESS "LogonHours restaurados a valores originales."
                } else {
                    msg_alert "Algunos horarios no se pudieron restaurar. Revisa el log."
                }
                msg_pause
            }
            '6' {
                draw_header "Estado Win10 en AD"
                if ($null -eq $win10Name) {
                    msg_error "No hay equipos Win10 registrados en AD."
                } else {
                    try {
                        $comp = Get-ADComputer $win10Name -Properties * -EA Stop
                        msg_info "Nombre:    $($comp.Name)"
                        msg_info "OU:        $($comp.DistinguishedName)"
                        msg_info "Unido:     $($comp.WhenCreated)"
                        msg_info "OS:        $($comp.OperatingSystem)"
                        msg_info "DNS:       $($comp.DNSHostName)"
                    } catch {
                        msg_error "Equipo $win10Name no encontrado: $_"
                    }
                }
                msg_pause
            }
            '0' { return }
            default { msg_alert "Opcion no valida."; Start-Sleep -Milliseconds 600 }
        }
    }
}

# -----------------------------------------------------------------------------
# VERIFICACION GENERAL — estado completo de todos los componentes
# -----------------------------------------------------------------------------
function Invoke-VerificationMenu {
    Show-Banner
    draw_header "Verificacion General — AC Manager"

    msg_info "Servidor : $env:COMPUTERNAME"
    msg_info "Fecha    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ""

    function _vcheck {
        param([string]$Desc, [string]$Result, [string]$Detail = "")
        $icon = switch ($Result) {
            'ok'   { Write-Host "  [  OK  ] " -ForegroundColor Green   -NoNewline }
            'fail' { Write-Host "  [ FAIL ] " -ForegroundColor Red     -NoNewline }
            'warn' { Write-Host "  [ WARN ] " -ForegroundColor Yellow  -NoNewline }
            'skip' { Write-Host "  [ SKIP ] " -ForegroundColor DarkGray -NoNewline }
        }
        Write-Host "$($Desc.PadRight(40)) $Detail"
    }

    # AD
    Write-Host "── Active Directory ─────────────────────────────────" -ForegroundColor Cyan
    if (Test-StatusAD) {
        $dom  = Get-ADDomain -EA SilentlyContinue
        _vcheck "AD DS instalado y activo"  "ok"   $dom.DNSRoot
        _vcheck "OUs Cuates / NoCuates"    $(if (Test-StatusOUs) { "ok" } else { "fail" })
        $cC = @(Get-ADGroupMember 'GRP_Cuates'   -EA SilentlyContinue).Count
        $cN = @(Get-ADGroupMember 'GRP_NoCuates' -EA SilentlyContinue).Count
        _vcheck "Usuarios en grupos"       $(if (Test-StatusUsers) { "ok" } else { "fail" }) "Cuates: $cC | NoCuates: $cN"
    } else {
        _vcheck "AD DS" "fail" "(no instalado)"
    }

    # LogonHours
    Write-Host ""
    Write-Host "── LogonHours ───────────────────────────────────────" -ForegroundColor Cyan
    foreach ($sam in @('user01','user06')) {
        try {
            $lhBytes = @((Get-ADUser $sam -Properties LogonHours -EA Stop).LogonHours)
            $lhOk    = ($lhBytes.Count -eq 21)
            _vcheck "LogonHours $sam" $(if ($lhOk) { "ok" } else { "fail" }) $(if ($lhOk) { "21 bytes" } else { "sin configurar" })
        } catch {
            _vcheck "LogonHours $sam" "skip" "(usuario no encontrado)"
        }
    }
    $gpoLF = Get-GPO -Name 'Politica-ForzarLogoff-T08' -EA SilentlyContinue
    _vcheck "GPO forzar logoff" $(if ($gpoLF) { "ok" } else { "fail" })

    # FSRM
    Write-Host ""
    Write-Host "── FSRM ─────────────────────────────────────────────" -ForegroundColor Cyan
    _vcheck "Rol FSRM instalado" $(if (Test-StatusFSRM) { "ok" } else { "fail" })
    try {
        $q1 = Get-FsrmQuota "C:\Homes\user01" -EA Stop
        _vcheck "Cuota user01 (10 MB)" "ok" "$([Math]::Round($q1.Size/1MB,0)) MB Hard"
    } catch { _vcheck "Cuota user01" "fail" "(no encontrada)" }
    try {
        $q6 = Get-FsrmQuota "C:\Homes\user06" -EA Stop
        _vcheck "Cuota user06 (5 MB)" "ok" "$([Math]::Round($q6.Size/1MB,0)) MB Hard"
    } catch { _vcheck "Cuota user06" "fail" "(no encontrada)" }
    try {
        $fs = Get-FsrmFileScreen "C:\Homes\user01" -EA Stop
        _vcheck "File Screen activo" $(if ($fs.Active) { "ok" } else { "warn" }) $fs.Template
    } catch { _vcheck "File Screen" "fail" "(no encontrado)" }

    # AppLocker
    Write-Host ""
    Write-Host "── AppLocker ────────────────────────────────────────" -ForegroundColor Cyan
    foreach ($gpoName in @('AppLocker-Cuates-T08','AppLocker-NoCuates-T08')) {
        $g = Get-GPO -Name $gpoName -EA SilentlyContinue
        _vcheck $gpoName $(if ($g) { "ok" } else { "fail" })
    }
    $appSvc = Get-Service 'AppIdSvc' -EA SilentlyContinue
    _vcheck "AppIDSvc" $(if ($appSvc -and $appSvc.Status -eq 'Running') { "ok" } else { "fail" }) `
        $(if ($appSvc) { $appSvc.Status } else { "no encontrado" })

    # Servicios AD clave
    Write-Host ""
    Write-Host "── Servicios AD ─────────────────────────────────────" -ForegroundColor Cyan
    foreach ($svcName in @('ADWS','DNS','KDC','NETLOGON','W32Time')) {
        $s = Get-Service -Name $svcName -EA SilentlyContinue
        if ($null -eq $s) {
            _vcheck "Servicio $svcName" "skip" "(no encontrado)"
        } elseif ($s.Status -eq 'Running') {
            _vcheck "Servicio $svcName" "ok" "Running"
        } else {
            _vcheck "Servicio $svcName" "fail" $s.Status
        }
    }

    Write-Host ""
    Write-Separator
    msg_success "Verificacion completada."
    msg_pause
}


# -----------------------------------------------------------------------------
# INFORMACION DEL SISTEMA
# -----------------------------------------------------------------------------

function Show-SystemInfo {
    draw_header "Informacion del Sistema"

    msg_info "Servidor       : $env:COMPUTERNAME"
    msg_info "Usuario        : $env:USERNAME"
    msg_info "Fecha/Hora     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    msg_info "PowerShell     : $($PSVersionTable.PSVersion)"
    msg_info "OS             : $((Get-WmiObject Win32_OperatingSystem).Caption)"
    Write-Host ""

    if ($script:AD_DOMAIN) {
        msg_info "Dominio        : $script:AD_DOMAIN"
        msg_info "NetBIOS        : $script:AD_NETBIOS"
        msg_info "DN Base        : $script:AD_DOMAIN_DN"
        Write-Host ""

        # Estadisticas del dominio
        try {
            $users  = @(Get-ADUser   -Filter * -SearchBase $script:AD_DOMAIN_DN -ErrorAction Stop).Count
            $groups = @(Get-ADGroup  -Filter * -SearchBase $script:AD_DOMAIN_DN -ErrorAction Stop).Count
            $ous    = @(Get-ADOrganizationalUnit -Filter * -SearchBase $script:AD_DOMAIN_DN -ErrorAction Stop).Count
            $comps  = @(Get-ADComputer -Filter * -SearchBase $script:AD_DOMAIN_DN -ErrorAction Stop).Count

            msg_info "Usuarios AD    : $users"
            msg_info "Grupos AD      : $groups"
            msg_info "OUs            : $ous"
            msg_info "Equipos AD     : $comps"
        } catch {
            msg_alert "No se pudieron obtener estadisticas de AD."
        }
    } else {
        msg_alert "No hay conexion activa al dominio."
    }

    Write-Host ""

    # Recursos del servidor
    try {
        $cpu  = (Get-WmiObject Win32_Processor).LoadPercentage
        $ram  = Get-WmiObject Win32_OperatingSystem
        $ramUsed  = [Math]::Round(($ram.TotalVisibleMemorySize - $ram.FreePhysicalMemory) / 1MB, 1)
        $ramTotal = [Math]::Round($ram.TotalVisibleMemorySize / 1MB, 1)
        $disk = Get-PSDrive C
        $diskFree  = [Math]::Round($disk.Free / 1GB, 1)
        $diskUsed  = [Math]::Round($disk.Used / 1GB, 1)

        msg_info "CPU            : $cpu%"
        msg_info "RAM            : $ramUsed GB / $ramTotal GB"
        msg_info "Disco C:       : $diskUsed GB usados, $diskFree GB libres"
    } catch {}

    if ($script:LOG_PATH) {
        Write-Host ""
        msg_info "Log activo     : $script:LOG_PATH"
        try {
            $logSize = [Math]::Round((Get-Item $script:LOG_PATH).Length / 1KB, 1)
            msg_info "Tamano del log : $logSize KB"
        } catch {}
    }

    msg_pause
}

# -----------------------------------------------------------------------------
# MANEJADOR DE ERRORES NO CAPTURADOS
# -----------------------------------------------------------------------------

function Invoke-MenuOption {
    param(
        [Parameter(Mandatory)] [string]      $OptionName,
        [Parameter(Mandatory)] [scriptblock] $Action
    )

    try {
        & $Action
    } catch {
        Write-Host ""
        if (Get-Command 'Write-Log' -ErrorAction SilentlyContinue) {
            Write-Log ERROR "Error no capturado en '$OptionName': $_"
            Write-Log ERROR "StackTrace: $($_.ScriptStackTrace)"
        } else {
            Write-Host "[ ERROR ] Error en '$OptionName': $_" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "  El error ha sido registrado en el log." -ForegroundColor Yellow
        Write-Host "  Puedes continuar usando el menu." -ForegroundColor Yellow
        msg_pause
    }
}

# -----------------------------------------------------------------------------
# BUCLE PRINCIPAL
# -----------------------------------------------------------------------------

function Start-ACManager {

    # ── 1. Bienvenida ─────────────────────────────────────────────────────────
    Show-Banner

    # ── 2. Conectar al dominio ────────────────────────────────────────────────
    Write-Host ""
    $connOK = Initialize-ADConnection
    if (-not $connOK) {
        Write-Log WARN "No se establecio conexion al dominio. Algunas funciones no estaran disponibles."
    }

    # ── 7. Bucle del menu ─────────────────────────────────────────────────────
    $running = $true
    while ($running) {
        Show-Banner
        Show-MainMenu

        msg_input "Selecciona una opcion: "
        $choice = Read-Host

        switch ($choice.Trim().ToUpper()) {

            # ── Parte 1 ───────────────────────────────────────────────────────
            '1' {
                Invoke-MenuOption 'Gestion AD' {
                    # Si no hay OUs personalizadas, correr setup primero
                    $ous = @(Get-ADOrganizationalUnit -Filter * -ErrorAction SilentlyContinue |
                             Where-Object { $_.Name -ne 'Domain Controllers' })
                    if ($ous.Count -eq 0) {
                        msg_alert "No hay Unidades Organizativas en el dominio."
                        msg_info  "Primero debes crear las OUs y grupos de seguridad."
                        Write-Host ""
                        $doSetup = Read-Confirm -Prompt "Crear OUs y grupos ahora" -Default 'S'
                        if ($doSetup) {
                            Invoke-OUSetup
                            msg_pause
                        }
                    }
                    Invoke-CSVMenu
                }
            }

            '2' {
                Invoke-MenuOption 'Control de Acceso Temporal' {
                    if (-not $script:AD_DOMAIN_DN) {
                        Write-Log WARN "Conecta al dominio primero (opcion C)."
                        msg_pause; return
                    }
                    Invoke-LogonHoursMenu
                }
            }

            '3' {
                Invoke-MenuOption 'Gestion FSRM' {
                    if (-not $script:AD_DOMAIN_DN) {
                        Write-Log WARN "Conecta al dominio primero (opcion C)."
                        msg_pause; return
                    }
                    Invoke-FSRMMenu
                }
            }

            '4' {
                Invoke-MenuOption 'AppLocker' {
                    if (-not $script:AD_DOMAIN_DN) {
                        Write-Log WARN "Conecta al dominio primero (opcion C)."
                        msg_pause; return
                    }
                    Invoke-AppLockerMenu
                }
            }

            # ── Parte 2 ───────────────────────────────────────────────────────
            '5' {
                Invoke-MenuOption 'RBAC' {
                    if (Get-Command 'Invoke-RBACMenu' -ErrorAction SilentlyContinue) {
                        Invoke-RBACMenu
                    } else {
                        msg_alert "El modulo RBAC (Parte 2) no esta disponible."
                        msg_info  "Copia ac_lib/ac_rbac.ps1 y reinicia AC Manager."
                        msg_pause
                    }
                }
            }

            '6' {
                Invoke-MenuOption 'FGPP' {
                    if (Get-Command 'Invoke-FGPPMenu' -ErrorAction SilentlyContinue) {
                        Invoke-FGPPMenu
                    } else {
                        msg_alert "El modulo FGPP (Parte 2) no esta disponible."
                        msg_info  "Copia ac_lib/ac_fgpp.ps1 y reinicia AC Manager."
                        msg_pause
                    }
                }
            }

            '7' {
                Invoke-MenuOption 'Auditoria' {
                    if (Get-Command 'Invoke-AuditMenu' -ErrorAction SilentlyContinue) {
                        Invoke-AuditMenu
                    } else {
                        msg_alert "El modulo de Auditoria (Parte 2) no esta disponible."
                        msg_info  "Copia ac_lib/ac_audit.ps1 y reinicia AC Manager."
                        msg_pause
                    }
                }
            }

            '8' {
                Invoke-MenuOption 'MFA' {
                    if (Get-Command 'Invoke-MFAMenu' -ErrorAction SilentlyContinue) {
                        Invoke-MFAMenu
                    } else {
                        msg_alert "El modulo MFA (Parte 2) no esta disponible."
                        msg_info  "Copia ac_lib/ac_mfa.ps1 y reinicia AC Manager."
                        msg_pause
                    }
                }
            }

            # ── Utilidades ────────────────────────────────────────────────────
            'U' {
                Invoke-MenuOption 'Gestion de Usuarios' {
                    if (-not $script:AD_DOMAIN_DN) {
                        msg_alert "Conecta al dominio primero (opcion C)."; msg_pause; return
                    }
                    Invoke-UsersMenu
                }
            }

            'M' {
                Invoke-MenuOption 'Monitoreo' {
                    if (-not $script:AD_DOMAIN_DN) {
                        msg_alert "Conecta al dominio primero (opcion C)."; msg_pause; return
                    }
                    Invoke-MonitorMenu
                }
            }

            'K' {
                Invoke-MenuOption 'Clientes del Dominio' {
                    if (-not $script:AD_DOMAIN_DN) {
                        msg_alert "Conecta al dominio primero (opcion C)."; msg_pause; return
                    }
                    Invoke-ClientsMenu
                }
            }

            'V' {
                Invoke-MenuOption 'Verificacion General' {
                    if (-not $script:AD_DOMAIN_DN) {
                        msg_alert "Conecta al dominio primero (opcion C)."; msg_pause; return
                    }
                    Invoke-VerificationMenu
                }
            }

            '9' {
                Invoke-MenuOption 'Ver Log' {
                    Show-Log -Lines 80
                    msg_pause
                }
            }

            'C' {
                Invoke-MenuOption 'Conectar Dominio' {
                    $ok = Initialize-ADConnection
                    if ($ok) {
                        Write-Log SUCCESS "Dominio conectado: $script:AD_DOMAIN"
                    }
                    msg_pause
                }
            }

            'I' {
                Invoke-MenuOption 'Info Sistema' {
                    Show-SystemInfo
                }
            }

            '0' {
                Write-Host ""
                $confirmExit = Read-Confirm -Prompt "Confirmar salida de AC Manager" -Default 'S'
                if ($confirmExit) {
                    $running = $false
                }
            }

            default {
                Write-Host ""
                msg_alert "Opcion no reconocida: '$choice'. Usa los numeros o letras del menu."
                Start-Sleep -Milliseconds 800
            }
        }
    }

    # ── 7. Cierre limpio ──────────────────────────────────────────────────────
    Show-Banner
    Write-Host "  Cerrando AC Manager..." -ForegroundColor Cyan
    Write-Host ""

    if (Get-Command 'Close-Log' -ErrorAction SilentlyContinue) {
        Close-Log
    }

    Write-Host "  Hasta luego." -ForegroundColor Green
    Write-Host ""
    Start-Sleep -Seconds 1
}

# -----------------------------------------------------------------------------
# PUNTO DE ENTRADA
# Toda la carga de modulos ocurre aqui, en el scope raiz del script,
# para que las funciones queden disponibles globalmente.
# -----------------------------------------------------------------------------

# ── Fase 1: Modulos base (sin dependencias de AD) ────────────────────────────
Write-Host ""
Write-Host "  Cargando modulos base..." -ForegroundColor Cyan
Write-Host ""

$_baseMods = @(
    "$script:LIB_PATH\ui.ps1|UI|0"
    "$script:LIB_PATH\utils.ps1|Utils|0"
    "$script:LIB_PATH\input.ps1|Input|0"
    "$script:AC_LIB_PATH\ac_log.ps1|Logger|0"
    "$script:AC_LIB_PATH\ac_setup.ps1|Setup|0"
)

$_loadFailed = @()
foreach ($_entry in $_baseMods) {
    $_parts    = $_entry -split '\|'
    $_path     = $_parts[0]
    $_name     = $_parts[1]
    $_optional = $_parts[2] -eq '1'

    if (Test-Path $_path) {
        try {
            . $_path
            Write-Host "  [  OK  ] $_name"
        } catch {
            Write-Host "  [  ERR ] $_name : $_"
            if (-not $_optional) { $_loadFailed += $_name }
        }
    } else {
        Write-Host "  [  --- ] $_name : no encontrado en $_path"
        $_loadFailed += $_name
    }
}

if ($_loadFailed.Count -gt 0) {
    Write-Host ""
    Write-Host "  [ FALLO ] Modulos base no cargados: $($_loadFailed -join ', ')" -ForegroundColor Red
    Read-Host "  Presiona Enter para salir"
    exit 1
}

# ── Fase 2: Inicializar log y correr setup (instala AD si falta) ──────────────
$_logOK = Initialize-Log
if (-not $_logOK) {
    Write-Host "  [ WARN ] No se pudo inicializar el log." -ForegroundColor Yellow
}

Write-Host ""
$_setupOK = Invoke-Setup
if (-not $_setupOK) {
    Write-Host "  [ FALLO ] El setup del entorno fallo." -ForegroundColor Red
    Read-Host "  Presiona Enter para salir"
    exit 1
}

# ── Fase 3: Modulos que requieren AD (ya instalado por el setup) ──────────────
Write-Host ""
Write-Host "  Cargando modulos de AC Manager..." -ForegroundColor Cyan
Write-Host ""

$_adMods = @(
    "$script:AC_LIB_PATH\ac_ad.ps1|AD|0"
    "$script:AC_LIB_PATH\ac_csv.ps1|CSV|0"
    "$script:AC_LIB_PATH\ac_logon.ps1|Logon|0"
    "$script:AC_LIB_PATH\ac_fsrm.ps1|FSRM|0"
    "$script:AC_LIB_PATH\ac_applocker.ps1|AppLocker|0"
    "$script:AC_LIB_PATH\ac_rbac.ps1|RBAC|1"
    "$script:AC_LIB_PATH\ac_fgpp.ps1|FGPP|1"
    "$script:AC_LIB_PATH\ac_audit.ps1|Audit|1"
    "$script:AC_LIB_PATH\ac_mfa.ps1|MFA|1"
)

$_loadFailed = @()
foreach ($_entry in $_adMods) {
    $_parts    = $_entry -split '\|'
    $_path     = $_parts[0]
    $_name     = $_parts[1]
    $_optional = $_parts[2] -eq '1'

    if (Test-Path $_path) {
        try {
            . $_path
            Write-Host "  [  OK  ] $_name"
        } catch {
            Write-Host "  [  ERR ] $_name : $_"
            if (-not $_optional) { $_loadFailed += $_name }
        }
    } else {
        if ($_optional) {
            Write-Host "  [  N/D ] $_name (no disponible)"
        } else {
            Write-Host "  [  --- ] $_name : no encontrado en $_path"
            $_loadFailed += $_name
        }
    }
}

if ($_loadFailed.Count -gt 0) {
    Write-Host ""
    Write-Host "  [ FALLO ] Modulos criticos no cargados: $($_loadFailed -join ', ')" -ForegroundColor Red
    Read-Host "  Presiona Enter para salir"
    exit 1
}

Write-Host ""
Start-ACManager