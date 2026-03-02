# =============================================================================
# ftp_lib/ftp_dirs.ps1 — Estructura de directorios y permisos NTFS
#
#
# El usuario tiene Modify en personal\ y ReadAndExecute en la raiz.
# Los junctions quedan protegidos porque el usuario no tiene Delete en la raiz.
# =============================================================================

# Resuelve nombres de identidad conocidos a SID para evitar problemas con idioma del SO.
function Resolve-Identity {
    param([string]$identity)
    $wellKnown = @{
        "BUILTIN\Administrators"        = [System.Security.Principal.SecurityIdentifier]"S-1-5-32-544"
        "NT AUTHORITY\SYSTEM"           = [System.Security.Principal.SecurityIdentifier]"S-1-5-18"
        "NT AUTHORITY\NETWORK SERVICE"  = [System.Security.Principal.SecurityIdentifier]"S-1-5-20"
        "Everyone"                      = [System.Security.Principal.SecurityIdentifier]"S-1-1-0"
    }
    if ($wellKnown.ContainsKey($identity)) {
        return $wellKnown[$identity].Translate([System.Security.Principal.NTAccount]).Value
    }
    return $identity
}

# Aplica un permiso NTFS a un directorio.
function Set-NtfsPermission {
    param(
        [string]$path,
        [string]$identity,
        [string]$rights,
        [string]$type        = "Allow",
        [string]$inheritance = "ContainerInherit,ObjectInherit",
        [string]$propagation = "None"
    )
    try {
        $resolvedIdentity = Resolve-Identity $identity
        $acl  = Get-Acl $path
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $resolvedIdentity, $rights, $inheritance, $propagation, $type
        )
        $acl.SetAccessRule($rule)
        Set-Acl -Path $path -AclObject $acl
        return $true
    } catch {
        msg_error "Error aplicando permisos en ${path}: $_"
        return $false
    }
}

# Elimina todos los permisos heredados y deja solo los explicitos.
function Disable-NtfsInheritance {
    param([string]$path)
    $acl = Get-Acl $path
    $acl.SetAccessRuleProtection($true, $true)
    Set-Acl -Path $path -AclObject $acl
}

# Elimina permisos de una identidad en un directorio.
function Remove-NtfsPermission {
    param([string]$path, [string]$identity)
    try {
        $resolved = Resolve-Identity $identity
        $acl   = Get-Acl $path
        $rules = $acl.Access | Where-Object {
            $_.IdentityReference.Value -like "*$resolved*" -or
            $_.IdentityReference.Value -like "*$identity*"
        }
        foreach ($rule in $rules) { $acl.RemoveAccessRule($rule) | Out-Null }
        Set-Acl -Path $path -AclObject $acl
    } catch {
        msg_alert "No se pudo eliminar permiso de ${identity} en ${path}: $_"
    }
}

# Crea la estructura base: LocalUser\, Public\ y carpetas de grupo.
function New-FtpDirectoryStructure {
    msg_process "Creando estructura base en $script:FTP_ROOT..."

    @(
        $script:FTP_ROOT,
        "$script:FTP_ROOT\LocalUser",
        $script:FTP_GENERAL,
        "$script:FTP_ROOT\grupos"
    ) | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }

    foreach ($grupo in $script:FTP_GROUPS) {
        $dir = "$script:FTP_ROOT\grupos\$grupo"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    # Raiz FTP
    Disable-NtfsInheritance $script:FTP_ROOT
    Set-NtfsPermission $script:FTP_ROOT "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $script:FTP_ROOT "NT AUTHORITY\SYSTEM"    "FullControl"

    # LocalUser
    Disable-NtfsInheritance "$script:FTP_ROOT\LocalUser"
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "NT AUTHORITY\SYSTEM"    "FullControl"

    # Public (general) — todos los usuarios FTP pueden leer/escribir
    # IUSR necesita acceso para que el anonimo pueda listar y leer
    Disable-NtfsInheritance $script:FTP_GENERAL
    Set-NtfsPermission $script:FTP_GENERAL "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $script:FTP_GENERAL "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $script:FTP_GENERAL $script:FTP_GROUP_ALL    "Modify"
    Set-NtfsPermission $script:FTP_GENERAL "IUSR"                   "ReadAndExecute"
    # FIX: Deny explícito para IUSR — gana sobre cualquier Allow heredado de grupo
    Set-NtfsPermission $script:FTP_GENERAL "IUSR" "Write,Delete,DeleteSubdirectoriesAndFiles,CreateFiles,CreateDirectories" "Deny"

    # LocalUser necesita acceso de listado para IUSR (para que anonymous pueda entrar a Public)
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "IUSR" "ReadAndExecute" "Allow" "None" "None"

    # Carpetas de grupo
    foreach ($grupo in $script:FTP_GROUPS) {
        $dir = "$script:FTP_ROOT\grupos\$grupo"
        Disable-NtfsInheritance $dir
        Set-NtfsPermission $dir "BUILTIN\Administrators" "FullControl"
        Set-NtfsPermission $dir "NT AUTHORITY\SYSTEM"    "FullControl"
        Set-NtfsPermission $dir $grupo                   "Modify"
    }

    msg_success "Estructura base creada"
}

# Crea junction point de linkPath -> targetPath.
function Add-FtpJunction {
    param([string]$linkPath, [string]$targetPath)
    if (Test-Path $linkPath) { return }
    if (-not (Test-Path $targetPath)) {
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    }
    $result = cmd /c "mklink /J `"$linkPath`" `"$targetPath`"" 2>&1
    if ($LASTEXITCODE -eq 0) {
        msg_success "Junction: $linkPath -> $targetPath"
    } else {
        msg_error "Error creando junction $linkPath : $result"
    }
}

# Elimina junction points de un usuario sin borrar el contenido.
function Remove-FtpUserJunctions {
    param([string]$usuario)
    $userDir = "$script:FTP_ROOT\LocalUser\$usuario"
    $targets = @("general") + $script:FTP_GROUPS
    foreach ($t in $targets) {
        $link = "$userDir\$t"
        if (Test-Path $link) {
            $item = Get-Item $link -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                cmd /c "rmdir `"$link`"" | Out-Null
                msg_success "Junction eliminado: $link"
            }
        }
    }
}

# Crea la estructura del usuario:
#   C:\FTP\LocalUser\<usuario>\
#   ├── personal\    carpeta privada fisica
#   ├── general\     junction -> C:\FTP\LocalUser\Public
#   └── <grupo>\     junction -> C:\FTP\grupos\<grupo>
#
# Permisos:
#   raiz\      -> ReadAndExecute (puede listar, no puede borrar ni crear en raiz)
#   personal\  -> Modify (control total dentro de su carpeta)
#   junctions  -> heredan permisos del destino (general y grupo)
function New-FtpUserDirectories {
    param([string]$usuario, [string]$grupo)

    $userDir  = "$script:FTP_ROOT\LocalUser\$usuario"
    $personal = "$userDir\personal"

    # Crear directorios fisicos
    New-Item -ItemType Directory -Path $userDir  -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Path $personal -Force -ErrorAction SilentlyContinue | Out-Null

    # Raiz: el usuario puede listar pero NO modificar ni borrar en la raiz
    # Esto protege los junctions — no puede borrarlos porque no tiene Delete aqui
    Disable-NtfsInheritance $userDir
    Set-NtfsPermission $userDir "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $userDir "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $userDir $usuario "ReadAndExecute" "Allow" "None" "None"

    # Personal: control total dentro de la carpeta
    Disable-NtfsInheritance $personal
    Set-NtfsPermission $personal "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $personal "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $personal $usuario                 "Modify"

    # Junctions
    Add-FtpJunction "$userDir\general" $script:FTP_GENERAL
    Add-FtpJunction "$userDir\$grupo"  "$script:FTP_ROOT\grupos\$grupo"

    msg_success "Directorios de '$usuario' creados"
}

# Elimina la carpeta del usuario y sus junctions.
function Remove-FtpUserDirectories {
    param([string]$usuario)
    $userDir = "$script:FTP_ROOT\LocalUser\$usuario"
    if (Test-Path $userDir) {
        Remove-FtpUserJunctions $usuario
        Remove-Item $userDir -Recurse -Force -ErrorAction SilentlyContinue
        msg_success "Directorio '$userDir' eliminado"
    }
}

# Actualiza junctions cuando cambia el grupo del usuario.
function Update-FtpUserVirtualDirectories {
    param([string]$usuario, [string]$nuevoGrupo)
    Remove-FtpUserJunctions $usuario
    $userDir = "$script:FTP_ROOT\LocalUser\$usuario"
    Add-FtpJunction "$userDir\general"     $script:FTP_GENERAL
    Add-FtpJunction "$userDir\$nuevoGrupo" "$script:FTP_ROOT\grupos\$nuevoGrupo"
}

# Alias de compatibilidad
function Remove-FtpUserVirtualDirectories {
    param([string]$usuario)
    Remove-FtpUserJunctions $usuario
}

# Repara permisos NTFS de toda la estructura.
function Repair-FtpPermissions {
    Write-Separator
    msg_process "Reparando permisos NTFS..."

    Set-NtfsPermission $script:FTP_ROOT "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $script:FTP_ROOT "NT AUTHORITY\SYSTEM"    "FullControl"

    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "NT AUTHORITY\SYSTEM"    "FullControl"

    if (Test-Path $script:FTP_GENERAL) {
        Set-NtfsPermission $script:FTP_GENERAL "BUILTIN\Administrators" "FullControl"
        Set-NtfsPermission $script:FTP_GENERAL "NT AUTHORITY\SYSTEM"    "FullControl"
        Set-NtfsPermission $script:FTP_GENERAL $script:FTP_GROUP_ALL    "Modify"
        Set-NtfsPermission $script:FTP_GENERAL "IUSR"                   "ReadAndExecute"
        # FIX: Deny explícito para IUSR — gana sobre cualquier Allow heredado de grupo
        Set-NtfsPermission $script:FTP_GENERAL "IUSR" "Write,Delete,DeleteSubdirectoriesAndFiles,CreateFiles,CreateDirectories" "Deny"
        msg_success "$script:FTP_GENERAL reparado"
    }

    foreach ($grupo in $script:FTP_GROUPS) {
        $dir = "$script:FTP_ROOT\grupos\$grupo"
        if (Test-Path $dir) {
            Set-NtfsPermission $dir "BUILTIN\Administrators" "FullControl"
            Set-NtfsPermission $dir "NT AUTHORITY\SYSTEM"    "FullControl"
            Set-NtfsPermission $dir $grupo                   "Modify"
            msg_success "$dir reparado"
        }
    }

    if (Test-Path $script:FTP_META) {
        Get-Content $script:FTP_META | ForEach-Object {
            if ($_ -match '^(.+):(.+)$') {
                $u = $Matches[1]
                $userDir  = "$script:FTP_ROOT\LocalUser\$u"
                $personal = "$userDir\personal"
                if (Test-Path $userDir) {
                    Set-NtfsPermission $userDir  "BUILTIN\Administrators" "FullControl"
                    Set-NtfsPermission $userDir  "NT AUTHORITY\SYSTEM"    "FullControl"
                    Set-NtfsPermission $userDir  $u "ReadAndExecute" "Allow" "None" "None"
                    msg_success "$userDir reparado"
                }
                if (Test-Path $personal) {
                    Set-NtfsPermission $personal "BUILTIN\Administrators" "FullControl"
                    Set-NtfsPermission $personal "NT AUTHORITY\SYSTEM"    "FullControl"
                    Set-NtfsPermission $personal $u                       "Modify"
                    msg_success "$personal reparado"
                }
            }
        }
    }

    msg_success "Reparacion completada"
}