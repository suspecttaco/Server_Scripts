# =============================================================================
# ftp_lib/ftp_users.ps1 - CRUD de usuarios FTP
#
# Cada usuario FTP tiene:
#   - Cuenta local Windows con password
#   - Miembro de su grupo FTP y de ftp_users
#   - Carpeta C:\FTP\LocalUser\<usuario>\ (User Isolation IIS FTP)
#   - Carpeta personal\ fisica con R/W completo
#   - Virtual Directory "general"  -> C:\FTP\LocalUser\Public   (via IIS)
#   - Virtual Directory "<grupo>"  -> C:\FTP\grupos\<grupo>     (via IIS)
#   - Sin acceso interactivo (SeDenyInteractiveLogonRight)
# =============================================================================

$script:_USUARIOS_RESERVADOS = @(
    'Administrator','Guest','DefaultAccount','WDAGUtilityAccount',
    'SYSTEM','LOCAL SERVICE','NETWORK SERVICE','ftp_users'
)

# -----------------------------------------------------------------------------
# Validadores
# -----------------------------------------------------------------------------
function Test-FtpUsername {
    param([string]$nombre)
    if ($nombre -notmatch '^[a-z_][a-z0-9_.\-]{0,31}$') {
        msg_error "Nombre invalido '${nombre}': minusculas/numeros/_.-; max 32; empieza con letra o _"
        return $false
    }
    if ($script:_USUARIOS_RESERVADOS -contains $nombre) {
        msg_error "Nombre reservado: '$nombre'"
        return $false
    }
    return $true
}

function ConvertTo-SecurePass {
    param([string]$plain)
    return ConvertTo-SecureString $plain -AsPlainText -Force
}

function Read-ConfirmedPassword {
    while ($true) {
        $p1 = Read-Host -Prompt "-> Contrasena" -AsSecureString
        $p2 = Read-Host -Prompt "-> Confirma contrasena" -AsSecureString

        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))

        if ([string]::IsNullOrEmpty($plain1)) { msg_error "La contrasena no puede estar vacia"; continue }
        if ($plain1 -ne $plain2) { msg_error "Las contrasenas no coinciden"; continue }

        $tmpUser = "_chk$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $secPass = ConvertTo-SecurePass $plain1
        try {
            New-LocalUser -Name $tmpUser -Password $secPass -ErrorAction Stop | Out-Null
            Remove-LocalUser -Name $tmpUser -ErrorAction SilentlyContinue
            return $plain1
        } catch {
            Remove-LocalUser -Name $tmpUser -ErrorAction SilentlyContinue
            msg_error "La contrasena no cumple la politica del sistema"
            msg_info  "Requisitos: minimo 7 caracteres, mayusculas, minusculas, numeros y/o simbolos"
            msg_info  "La contrasena NO puede contener el nombre de usuario"
        }
    }
}

# -----------------------------------------------------------------------------
# Metadatos
# -----------------------------------------------------------------------------
function Init-FtpMeta {
    if (-not (Test-Path $script:FTP_ROOT)) {
        New-Item -ItemType Directory -Path $script:FTP_ROOT -Force | Out-Null
    }
    if (-not (Test-Path $script:FTP_META)) {
        New-Item -ItemType File -Path $script:FTP_META -Force | Out-Null
    }
    msg_success "Archivo de metadatos inicializado"
}

function Meta-GetGroup {
    param([string]$usuario)
    if (-not (Test-Path $script:FTP_META)) { return $null }
    $linea = Get-Content $script:FTP_META | Where-Object { $_ -match "^${usuario}:" } | Select-Object -First 1
    if ($linea) { return ($linea -split ':')[1] }
    return $null
}

function Meta-Set {
    param([string]$usuario, [string]$grupo)
    $newLine = "${usuario}:${grupo}"
    if (Test-Path $script:FTP_META) {
        $lines = @(Get-Content $script:FTP_META | Where-Object { $_ -notmatch "^${usuario}:" })
        $lines += $newLine
        [System.IO.File]::WriteAllLines($script:FTP_META, $lines, [System.Text.Encoding]::UTF8)
    } else {
        [System.IO.File]::WriteAllLines($script:FTP_META, @($newLine), [System.Text.Encoding]::UTF8)
    }
}

function Meta-Delete {
    param([string]$usuario)
    if (Test-Path $script:FTP_META) {
        $lines = @(Get-Content $script:FTP_META | Where-Object { $_ -notmatch "^${usuario}:" })
        [System.IO.File]::WriteAllLines($script:FTP_META, $lines, [System.Text.Encoding]::UTF8)
    }
}

function Meta-Exists {
    param([string]$usuario)
    if (-not (Test-Path $script:FTP_META)) { return $false }
    return [bool](Get-Content $script:FTP_META | Where-Object { $_ -match "^${usuario}:" })
}

# -----------------------------------------------------------------------------
# Gestion de cuentas Windows
# -----------------------------------------------------------------------------
function New-FtpWindowsUser {
    param([string]$usuario, [string]$password, [string]$grupo)
    try {
        $secPass = ConvertTo-SecurePass $password
        New-LocalUser -Name $usuario `
            -Password $secPass `
            -FullName "FTP: $usuario" `
            -Description "Usuario FTP" `
            -PasswordNeverExpires `
            -ErrorAction Stop | Out-Null

        Add-LocalGroupMember -Group $grupo                  -Member $usuario -ErrorAction SilentlyContinue
        Add-LocalGroupMember -Group $script:FTP_GROUP_ALL   -Member $usuario -ErrorAction SilentlyContinue

        Deny-LocalLogon $usuario

        msg_success "Usuario Windows '$usuario' creado (grupo: $grupo)"
        return $true
    } catch {
        msg_error "No se pudo crear el usuario Windows: $_"
        return $false
    }
}

function Deny-LocalLogon {
    param([string]$usuario)
    try {
        $tmpCfg = "$env:TEMP\ftp_secedit_deny.inf"
        $tmpDb  = "$env:TEMP\ftp_secedit.sdb"

        secedit /export /cfg $tmpCfg /quiet 2>$null

        $content = Get-Content $tmpCfg -Raw
        $sid = (New-Object System.Security.Principal.NTAccount($usuario)).Translate([System.Security.Principal.SecurityIdentifier]).Value

        if ($content -match 'SeDenyInteractiveLogonRight\s*=\s*(.*)') {
            $actual = $Matches[1].Trim()
            if ($actual -notlike "*$sid*") {
                $content = $content -replace 'SeDenyInteractiveLogonRight\s*=\s*.*', "SeDenyInteractiveLogonRight = $actual,*$sid"
            }
        } else {
            $content += "`nSeDenyInteractiveLogonRight = *$sid"
        }

        $content | Set-Content $tmpCfg -Encoding Unicode
        secedit /configure /cfg $tmpCfg /db $tmpDb /quiet 2>$null
        Remove-Item $tmpCfg,$tmpDb -ErrorAction SilentlyContinue
        msg_success "Inicio de sesion local denegado para '$usuario'"
    } catch {
        msg_alert "No se pudo denegar inicio de sesion local para '$usuario': $_"
    }
}

# -----------------------------------------------------------------------------
# CRUD publico
# -----------------------------------------------------------------------------
function New-FtpUsersLote {
    Write-Separator
    $n = Read-Input "Numero de usuarios a crear: "
    if ($n -notmatch '^\d+$' -or [int]$n -lt 1) { msg_error "Numero invalido"; return }

    $total = [int]$n; $creados = 0
    while ($creados -lt $total) {
        Write-Separator
        msg_info "Usuario $($creados+1) de $total"

        $usuario = ""
        while ($true) {
            $usuario = Read-Input "Nombre de usuario FTP: "
            if (-not (Test-FtpUsername $usuario)) { continue }
            if (Meta-Exists $usuario) { msg_error "Ya existe '$usuario'"; continue }
            if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) { msg_error "Usuario Windows '$usuario' ya existe"; continue }
            break
        }

        $pass  = Read-ConfirmedPassword
        $grupo = Select-FtpGroup

        if (New-FtpWindowsUser $usuario $pass $grupo) {
            New-FtpUserDirectories $usuario $grupo
            Meta-Set $usuario $grupo
            msg_success "Usuario '$usuario' creado en grupo '$grupo'"
        }

        $creados++
    }

    Restart-FtpService
    msg_success "$total usuario(s) procesados."
}

function Update-FtpUser {
    Write-Separator
    $usuario = Read-Input "Nombre del usuario FTP a actualizar: "
    if (-not (Meta-Exists $usuario)) { msg_error "El usuario '$usuario' no existe"; return }

    $grupoActual = Meta-GetGroup $usuario
    msg_info "Usuario FTP : $usuario"
    msg_info "Grupo       : $grupoActual"
    msg_info "(Enter = sin cambios)"
    Write-Separator

    # Cambiar nombre
    $nuevoNombre = Read-Input "Nuevo nombre FTP [$usuario]: "
    if (-not [string]::IsNullOrWhiteSpace($nuevoNombre) -and $nuevoNombre -ne $usuario) {
        if (-not (Test-FtpUsername $nuevoNombre)) {
            msg_error "Nombre invalido — sin cambios"
        } elseif (Meta-Exists $nuevoNombre) {
            msg_error "'$nuevoNombre' ya en uso"
        } else {
            try {
                Rename-LocalUser -Name $usuario -NewName $nuevoNombre -ErrorAction Stop

                $oldDir = "$script:FTP_ROOT\LocalUser\$usuario"
                $newDir = "$script:FTP_ROOT\LocalUser\$nuevoNombre"
                if (Test-Path $oldDir) { Rename-Item $oldDir $newDir }

                $lines = Get-Content $script:FTP_META | ForEach-Object { $_ -replace "^${usuario}:", "${nuevoNombre}:" }
                $lines | Set-Content $script:FTP_META

                # Recrear junctions con el nuevo nombre
                Remove-FtpUserVirtualDirectories $nuevoNombre
                Add-FtpJunction "$newDir\general"      $script:FTP_GENERAL
                Add-FtpJunction "$newDir\$grupoActual" "$script:FTP_ROOT\grupos\$grupoActual"

                msg_success "Usuario renombrado: '$usuario' -> '$nuevoNombre'"
                $usuario = $nuevoNombre
            } catch {
                msg_error "No se pudo renombrar: $_"
            }
        }
    }

    # Cambiar contrasena
    if (Confirm-Action "Cambiar contrasena?") {
        $newPass = Read-ConfirmedPassword
        try {
            Set-LocalUser -Name $usuario -Password (ConvertTo-SecurePass $newPass) -ErrorAction Stop
            msg_success "Contrasena actualizada"
        } catch {
            msg_error "No se pudo cambiar la contrasena: $_"
        }
    }

    # Cambiar grupo
    msg_info "Grupo actual: $grupoActual"
    if (Confirm-Action "Cambiar grupo?") {
        $nuevoGrupo = Select-FtpGroup
        if ($nuevoGrupo -ne $grupoActual) {
            try {
                Remove-LocalGroupMember -Group $grupoActual -Member $usuario -ErrorAction SilentlyContinue
                Add-LocalGroupMember    -Group $nuevoGrupo  -Member $usuario -ErrorAction Stop
                Meta-Set $usuario $nuevoGrupo
                Update-FtpUserVirtualDirectories $usuario $nuevoGrupo
                msg_success "Grupo: '$grupoActual' -> '$nuevoGrupo'"
            } catch {
                msg_error "No se pudo cambiar el grupo: $_"
            }
        } else {
            msg_info "Mismo grupo — sin cambios"
        }
    }

    Restart-FtpService
    msg_success "Actualizacion de '$usuario' completada"
}

function Remove-FtpUser {
    Write-Separator
    $usuario = Read-Input "Nombre del usuario FTP a eliminar: "
    if (-not (Meta-Exists $usuario)) { msg_error "El usuario '$usuario' no existe"; return }

    $grupo   = Meta-GetGroup $usuario
    $userDir = "$script:FTP_ROOT\LocalUser\$usuario"
    msg_info "Usuario: $usuario  |  Grupo: $grupo  |  Dir: $userDir"

    if (-not (Confirm-Action "Confirma eliminar '$usuario'")) { msg_info "Cancelado"; return }

    $delDir = Confirm-Action "Eliminar directorio del usuario?"

    # Eliminar junctions sin tocar el contenido del destino
    Remove-FtpUserVirtualDirectories $usuario

    # Eliminar usuario Windows
    try {
        Remove-LocalUser -Name $usuario -ErrorAction Stop
        msg_success "Usuario Windows '$usuario' eliminado"
    } catch {
        msg_alert "No se pudo eliminar el usuario Windows: $_"
    }

    Meta-Delete $usuario

    if ($delDir -and (Test-Path $userDir)) {
        Remove-Item $userDir -Recurse -Force
        msg_success "Directorio eliminado"
    }

    Restart-FtpService
    msg_success "Usuario '$usuario' eliminado"
}

function Show-FtpUsers {
    Write-Separator
    msg_info "Usuarios FTP:"
    if (-not (Test-Path $script:FTP_META) -or -not (Get-Content $script:FTP_META | Where-Object { $_ -match ':' })) {
        msg_alert "No hay usuarios registrados"; return
    }

    "{0,-20} {1,-15} {2,-30}" -f "USUARIO FTP", "GRUPO", "DIRECTORIO" | Write-Host
    "{0,-20} {1,-15} {2,-30}" -f "-----------", "-----", "-----------" | Write-Host

    Get-Content $script:FTP_META | ForEach-Object {
        if ($_ -match '^(.+):(.+)$') {
            $u = $Matches[1]; $g = $Matches[2]
            $userDir = "$script:FTP_ROOT\LocalUser\$u"
            "{0,-20} {1,-15} {2,-30}" -f $u, $g, $userDir | Write-Host
        }
    }
}