# =============================================================================
# ftp_lib/ftp_dirs.ps1 - Estructura de directorios y permisos NTFS
#
# Arquitectura: IIS FTP Virtual Directories (NO junction points)
#
#   C:\FTP\LocalUser\<usuario>\          chroot del usuario (User Isolation)
#       <usuario>: ReadAndExecute ThisFolderOnly
#       <usuario>: DENY Write+Delete+Create ThisFolderOnly
#
#   C:\FTP\LocalUser\<usuario>\personal\ carpeta fisica privada
#       <usuario>: Modify (herencia completa)
#       <usuario>: DENY Delete ThisFolderOnly
#
#   Virtual Directory "general"  -> C:\FTP\LocalUser\Public\
#   Virtual Directory "<grupo>"  -> C:\FTP\grupos\<grupo>\
#       (configurados en IIS, no son carpetas fisicas en el chroot)
#
# Por que Virtual Directories resuelven el problema:
#   Con junctions, FileZilla puede vaciar el contenido antes de RMD porque
#   el directorio es fisicamente accesible. Con Virtual Directories de IIS,
#   "general" y "<grupo>" son entradas de configuracion de IIS — el servidor
#   FTP devuelve 550 a cualquier RMD sobre un Virtual Directory sin tocar
#   el sistema de archivos.
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
# Permisos de raiz del usuario
#   Allow ReadAndExecute ThisFolderOnly  -> puede listar carpetas
#   Deny  Write+Delete+Create ThisFolderOnly -> no puede modificar la raiz
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

# ---------------------------------------------------------------------------
# Permisos de carpeta personal
#   Allow Modify herencia completa -> R/W total sobre el contenido
#   Deny  Delete ThisFolderOnly    -> no puede borrar la carpeta en si misma
# ---------------------------------------------------------------------------
function Set-FtpPersonalDirPermissions {
    param([string]$path, [string]$usuario)

    Disable-NtfsInheritance $path
    Set-NtfsPermission $path "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $path "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $path $usuario "Modify" "Allow" "ContainerInherit,ObjectInherit" "None"
    Set-NtfsPermission $path $usuario "Delete" "Deny"  "None" "None"
}

# ---------------------------------------------------------------------------
# IIS FTP Virtual Directory
#
# Crea un Virtual Directory bajo el sitio FTP para el usuario dado.
# virtualPath : ruta FTP vista por el cliente  (ej: /usuario/general)
# physicalPath: ruta real en disco             (ej: C:\FTP\LocalUser\Public)
#
# IIS no permite RMD sobre Virtual Directories — devuelve 550 sin tocar
# el sistema de archivos, resolviendo el problema de borrado de contenido.
# ---------------------------------------------------------------------------
function Add-FtpVirtualDirectory {
    param(
        [string]$usuario,
        [string]$vdirName,
        [string]$physicalPath
    )
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $locationPath = "$script:FTP_SITE_NAME/$usuario"
    $vdirPath     = "IIS:\Sites\$script:FTP_SITE_NAME\$usuario\$vdirName"

    try {
        if (-not (Test-Path $vdirPath)) {
            New-WebVirtualDirectory `
                -Site    $script:FTP_SITE_NAME `
                -Application "/" `
                -Name    "$usuario/$vdirName" `
                -PhysicalPath $physicalPath `
                -ErrorAction Stop | Out-Null
            msg_success "VDir: /$usuario/$vdirName -> $physicalPath"
        }
    } catch {
        msg_error "No se pudo crear Virtual Directory '$vdirName' para '$usuario': $_"
    }
}

# Elimina un Virtual Directory de IIS para el usuario dado.
function Remove-FtpVirtualDirectory {
    param([string]$usuario, [string]$vdirName)
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $vdirPath = "IIS:\Sites\$script:FTP_SITE_NAME\$usuario\$vdirName"
    if (Test-Path $vdirPath) {
        try {
            Remove-WebVirtualDirectory `
                -Site        $script:FTP_SITE_NAME `
                -Application "/" `
                -Name        "$usuario/$vdirName" `
                -ErrorAction Stop
            msg_success "VDir eliminado: /$usuario/$vdirName"
        } catch {
            msg_error "No se pudo eliminar Virtual Directory '$vdirName' de '$usuario': $_"
        }
    }
}

# Elimina todos los Virtual Directories de un usuario.
function Remove-FtpUserVirtualDirectories {
    param([string]$usuario)
    Remove-FtpVirtualDirectory $usuario "general"
    foreach ($g in $script:FTP_GROUPS) {
        Remove-FtpVirtualDirectory $usuario $g
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
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "IUSR" "ReadAndExecute" "Allow" "None" "None"

    # Public (general):
    #   ftp_users: Modify con herencia
    #   IUSR: solo lectura + DENY escritura/borrado total
    Disable-NtfsInheritance $script:FTP_GENERAL
    Set-NtfsPermission $script:FTP_GENERAL "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $script:FTP_GENERAL "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $script:FTP_GENERAL $script:FTP_GROUP_ALL "Modify" "Allow" `
        "ContainerInherit,ObjectInherit" "None"
    Set-NtfsPermission $script:FTP_GENERAL "IUSR" "ReadAndExecute" "Allow" `
        "ContainerInherit,ObjectInherit" "None"
    Set-NtfsPermission $script:FTP_GENERAL "IUSR" `
        "Write,Delete,DeleteSubdirectoriesAndFiles,CreateFiles,CreateDirectories" `
        "Deny" "ContainerInherit,ObjectInherit" "None"

    # Carpetas de grupo: <grupo> Modify con herencia
    foreach ($grupo in $script:FTP_GROUPS) {
        $dir = "$script:FTP_ROOT\grupos\$grupo"
        Disable-NtfsInheritance $dir
        Set-NtfsPermission $dir "BUILTIN\Administrators" "FullControl"
        Set-NtfsPermission $dir "NT AUTHORITY\SYSTEM"    "FullControl"
        Set-NtfsPermission $dir $grupo "Modify" "Allow" "ContainerInherit,ObjectInherit" "None"
    }

    msg_success "Estructura base creada"
}

# Crea la estructura del usuario:
#   C:\FTP\LocalUser\<usuario>\
#   +-- personal\    carpeta fisica privada
#   IIS VDir "general" -> C:\FTP\LocalUser\Public
#   IIS VDir "<grupo>" -> C:\FTP\grupos\<grupo>
function New-FtpUserDirectories {
    param([string]$usuario, [string]$grupo)

    $userDir  = "$script:FTP_ROOT\LocalUser\$usuario"
    $personal = "$userDir\personal"

    New-Item -ItemType Directory -Path $userDir  -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Path $personal -Force -ErrorAction SilentlyContinue | Out-Null

    # Raiz: solo listar
    Set-FtpUserRootPermissions $userDir $usuario

    # Personal: R/W completo, no puede borrar la carpeta en si misma
    Set-FtpPersonalDirPermissions $personal $usuario

    # Virtual Directories en IIS (reemplazan los junctions)
    Add-FtpVirtualDirectory $usuario "general" $script:FTP_GENERAL
    Add-FtpVirtualDirectory $usuario $grupo    "$script:FTP_ROOT\grupos\$grupo"

    msg_success "Directorios de '$usuario' creados"
}

# Elimina la carpeta fisica del usuario y sus Virtual Directories de IIS.
function Remove-FtpUserDirectories {
    param([string]$usuario)

    # Primero eliminar VDirs de IIS
    Remove-FtpUserVirtualDirectories $usuario

    # Luego eliminar carpeta fisica
    $userDir = "$script:FTP_ROOT\LocalUser\$usuario"
    if (Test-Path $userDir) {
        Remove-Item $userDir -Recurse -Force -ErrorAction SilentlyContinue
        msg_success "Directorio '$userDir' eliminado"
    }
}

# Actualiza Virtual Directories cuando cambia el grupo del usuario.
function Update-FtpUserVirtualDirectories {
    param([string]$usuario, [string]$nuevoGrupo)

    # Eliminar todos los VDirs actuales del usuario
    Remove-FtpUserVirtualDirectories $usuario

    # Recrear con el nuevo grupo
    Add-FtpVirtualDirectory $usuario "general"    $script:FTP_GENERAL
    Add-FtpVirtualDirectory $usuario $nuevoGrupo  "$script:FTP_ROOT\grupos\$nuevoGrupo"
}

# Repara permisos NTFS y Virtual Directories de toda la estructura.
function Repair-FtpPermissions {
    Write-Separator
    msg_process "Reparando permisos NTFS y Virtual Directories..."

    # Raiz FTP
    Set-NtfsPermission $script:FTP_ROOT "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $script:FTP_ROOT "NT AUTHORITY\SYSTEM"    "FullControl"

    # LocalUser
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "IUSR" "ReadAndExecute" "Allow" "None" "None"

    # Public
    if (Test-Path $script:FTP_GENERAL) {
        Set-NtfsPermission $script:FTP_GENERAL "BUILTIN\Administrators" "FullControl"
        Set-NtfsPermission $script:FTP_GENERAL "NT AUTHORITY\SYSTEM"    "FullControl"
        Set-NtfsPermission $script:FTP_GENERAL $script:FTP_GROUP_ALL "Modify" "Allow" `
            "ContainerInherit,ObjectInherit" "None"
        Set-NtfsPermission $script:FTP_GENERAL "IUSR" "ReadAndExecute" "Allow" `
            "ContainerInherit,ObjectInherit" "None"
        Set-NtfsPermission $script:FTP_GENERAL "IUSR" `
            "Write,Delete,DeleteSubdirectoriesAndFiles,CreateFiles,CreateDirectories" `
            "Deny" "ContainerInherit,ObjectInherit" "None"
        msg_success "$script:FTP_GENERAL reparado"
    }

    # Carpetas de grupo
    foreach ($grupo in $script:FTP_GROUPS) {
        $dir = "$script:FTP_ROOT\grupos\$grupo"
        if (Test-Path $dir) {
            Set-NtfsPermission $dir "BUILTIN\Administrators" "FullControl"
            Set-NtfsPermission $dir "NT AUTHORITY\SYSTEM"    "FullControl"
            Set-NtfsPermission $dir $grupo "Modify" "Allow" "ContainerInherit,ObjectInherit" "None"
            msg_success "$dir reparado"
        }
    }

    # Directorios y VDirs de usuarios
    if (Test-Path $script:FTP_META) {
        Get-Content $script:FTP_META | ForEach-Object {
            if ($_ -match '^(.+):(.+)$') {
                $u = $Matches[1]; $g = $Matches[2]
                $userDir  = "$script:FTP_ROOT\LocalUser\$u"
                $personal = "$userDir\personal"

                if (Test-Path $userDir) {
                    Set-FtpUserRootPermissions $userDir $u
                    msg_success "$userDir reparado"
                }
                if (Test-Path $personal) {
                    Set-FtpPersonalDirPermissions $personal $u
                    msg_success "$personal reparado"
                }

                # Reparar Virtual Directories: eliminar y recrear
                Remove-FtpUserVirtualDirectories $u
                Add-FtpVirtualDirectory $u "general" $script:FTP_GENERAL
                Add-FtpVirtualDirectory $u $g        "$script:FTP_ROOT\grupos\$g"
                msg_success "VDirs de '$u' reparados"
            }
        }
    }

    msg_success "Reparacion completada"
}