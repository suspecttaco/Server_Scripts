# =============================================================================
# ftp_lib/ftp_dirs.ps1 — Estructura de directorios y permisos NTFS
#
# Modelo de permisos por usuario:
#
#   C:\FTP\LocalUser\<usuario>\          ReadAndExecute (ThisFolderOnly)
#                                        DENY Write+Delete+Create (ThisFolderOnly)
#
#   +-- personal\                        Modify (herencia completa)
#                                        DENY Delete (ThisFolderOnly)
#
#   +-- general\  --junction-->          C:\FTP\LocalUser\Public\
#                                        ftp_users: Modify (herencia completa)
#                                        IUSR: ReadAndExecute
#                                        IUSR: DENY Write+Delete+Create
#
#   +-- <grupo>\  --junction-->          C:\FTP\grupos\<grupo>\
#                                        <grupo>: Modify (herencia completa)
#
# NOTA: El borrado recursivo de general y <grupo> via FileZilla es una
# limitacion del protocolo FTP (RFC 959) — el servidor no puede distinguir
# un DELE intencional de uno ejecutado como paso previo a un RMD.
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

# ---------------------------------------------------------------------------
# Permisos de raiz de usuario
#   Allow ReadAndExecute ThisFolderOnly  -> puede listar las carpetas
#   Deny  Write+Delete+Create ThisFolderOnly -> no puede tocar la raiz
# ---------------------------------------------------------------------------
function Set-FtpUserRootPermissions {
    param([string]$userDir, [string]$usuario)

    Disable-NtfsInheritance $userDir
    Set-NtfsPermission $userDir "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $userDir "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $userDir $usuario `
        "ReadAndExecute,ListDirectory" "Allow" "None" "None"
    Set-NtfsPermission $userDir $usuario `
        "Write,Delete,DeleteSubdirectoriesAndFiles,CreateFiles,CreateDirectories" `
        "Deny" "None" "None"
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
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "IUSR" "ReadAndExecute" "Allow" "None" "None"

    # Public (general)
    Disable-NtfsInheritance $script:FTP_GENERAL
    Set-NtfsPermission $script:FTP_GENERAL "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $script:FTP_GENERAL "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $script:FTP_GENERAL $script:FTP_GROUP_ALL    "Modify"
    Set-NtfsPermission $script:FTP_GENERAL "IUSR"                   "ReadAndExecute"
    Set-NtfsPermission $script:FTP_GENERAL "IUSR" `
        "Write,Delete,DeleteSubdirectoriesAndFiles,CreateFiles,CreateDirectories" "Deny"

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

# Elimina junction points de un usuario sin borrar el contenido del destino.
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
#   +-- personal\    carpeta privada fisica
#   +-- general\     junction -> C:\FTP\LocalUser\Public
#   +-- <grupo>\     junction -> C:\FTP\grupos\<grupo>
function New-FtpUserDirectories {
    param([string]$usuario, [string]$grupo)

    $userDir  = "$script:FTP_ROOT\LocalUser\$usuario"
    $personal = "$userDir\personal"

    New-Item -ItemType Directory -Path $userDir  -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Path $personal -Force -ErrorAction SilentlyContinue | Out-Null

    # Raiz: solo listar, no modificar
    Set-FtpUserRootPermissions $userDir $usuario

    # Personal: Modify completo con herencia + DENY Delete en raiz
    Disable-NtfsInheritance $personal
    Set-NtfsPermission $personal "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $personal "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $personal $usuario "Modify" "Allow" "ContainerInherit,ObjectInherit" "None"
    Set-NtfsPermission $personal $usuario "Delete" "Deny"  "None" "None"

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
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "IUSR" "ReadAndExecute" "Allow" "None" "None"

    if (Test-Path $script:FTP_GENERAL) {
        Set-NtfsPermission $script:FTP_GENERAL "BUILTIN\Administrators" "FullControl"
        Set-NtfsPermission $script:FTP_GENERAL "NT AUTHORITY\SYSTEM"    "FullControl"
        Set-NtfsPermission $script:FTP_GENERAL $script:FTP_GROUP_ALL    "Modify"
        Set-NtfsPermission $script:FTP_GENERAL "IUSR"                   "ReadAndExecute"
        Set-NtfsPermission $script:FTP_GENERAL "IUSR" `
            "Write,Delete,DeleteSubdirectoriesAndFiles,CreateFiles,CreateDirectories" "Deny"
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
                    Set-FtpUserRootPermissions $userDir $u
                    msg_success "$userDir reparado"
                }
                if (Test-Path $personal) {
                    Set-NtfsPermission $personal "BUILTIN\Administrators" "FullControl"
                    Set-NtfsPermission $personal "NT AUTHORITY\SYSTEM"    "FullControl"
                    Set-NtfsPermission $personal $u "Modify" "Allow" "ContainerInherit,ObjectInherit" "None"
                    Set-NtfsPermission $personal $u "Delete" "Deny"  "None" "None"
                    msg_success "$personal reparado"
                }

                # Reparar junctions
                Remove-FtpUserJunctions $u
                Add-FtpJunction "$userDir\general" $script:FTP_GENERAL
                $g = $Matches[2]
                Add-FtpJunction "$userDir\$g" "$script:FTP_ROOT\grupos\$g"
                msg_success "Junctions de '$u' reparados"
            }
        }
    }

    msg_success "Reparacion completada"
}