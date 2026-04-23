# =============================================================================
# ac_lib/ac_roaming.ps1 - Perfiles Moviles (Roaming Profiles) via GPO
# Uso: . .\ac_lib\ac_roaming.ps1
# Requiere: lib/ui.ps1, lib/input.ps1, ac_lib/ac_log.ps1, ac_lib/ac_ad.ps1
#
# Que hace:
#   1. Crea (o reutiliza) la carpeta y share SMB para almacenar perfiles
#   2. Aplica ACLs NTFS correctas (SID universales, sin strings localizados)
#   3. Configura el atributo ProfilePath en AD para cada usuario del scope
#   4. Crea / actualiza una GPO "PerfilesMoviles-T08" con las politicas
#      de carpetas redirigidas (Documents, Desktop) y configura el tiempo
#      de espera de descarga del perfil
#   5. Vincula la GPO a las OUs seleccionadas
#
# Convenciones del proyecto:
#   - Todas las funciones devuelven $true/$false o el valor/$false
#   - Write-Log en lugar de Write-Host para operaciones importantes
#   - Invoke-Logged para cmdlets con salida ruidosa
#   - Idempotente: verificar antes de crear
#   - SIDs universales en lugar de strings localizados para ACLs
# =============================================================================

#Requires -Module ActiveDirectory
#Requires -Module GroupPolicy

# ─────────────────────────────────────────────────────────────────────────────
# VARIABLES DE MODULO
# ─────────────────────────────────────────────────────────────────────────────
$script:ROAMING_SHARE_NAME = $null   # Nombre del share SMB (ej: "Perfiles$")
$script:ROAMING_SHARE_PATH = $null   # Ruta local del share (ej: "C:\Perfiles")
$script:ROAMING_GPO_NAME = 'PerfilesMoviles-T08'

# SIDs universales (no dependen del idioma del SO)
$script:SID_SYSTEM = 'S-1-5-18'     # SYSTEM
$script:SID_ADMINS = 'S-1-5-32-544' # Administradores (builtin)
$script:SID_CREATOR_OWNER = 'S-1-3-0'      # CREATOR OWNER
$script:SID_AUTHENTICATED = 'S-1-5-11'     # Usuarios autenticados

# ─────────────────────────────────────────────────────────────────────────────
# Test-RoamingShareExists
# Verifica que el share y la carpeta base existen y estan configurados.
# Devuelve: $true | $false
# ─────────────────────────────────────────────────────────────────────────────
function Test-RoamingShareExists {
    if (-not $script:ROAMING_SHARE_NAME) { return $false }
    $share = Get-SmbShare -Name $script:ROAMING_SHARE_NAME -ErrorAction SilentlyContinue
    if ($null -eq $share) { return $false }
    return (Test-Path $share.Path)
}

# ─────────────────────────────────────────────────────────────────────────────
# Initialize-RoamingPaths
# Solicita al usuario la ruta local y el nombre del share.
# Popula $script:ROAMING_SHARE_PATH y $script:ROAMING_SHARE_NAME.
# Devuelve: $true | $false
# ─────────────────────────────────────────────────────────────────────────────
function Initialize-RoamingPaths {
    Write-LogSection "Configuracion de Rutas - Perfiles Moviles"

    # Ruta local
    $defaultPath = "$env:SystemDrive\Perfiles"

    $localPath = Read-InputLoop `
        -Prompt "Ruta LOCAL donde se almacenaran los perfiles (Enter para '$defaultPath')" `
        -Validator { param($v) $v -match '^[A-Za-z]:\\[^"<>|?*]+$' -or $v -eq '' } `
        -ErrorMsg  "Ruta invalida. Ejemplo: C:\Perfiles" `
        -AllowEmpty $true

    if ($localPath -eq $false) { return $false }
    if ([string]::IsNullOrWhiteSpace($localPath)) { $localPath = $defaultPath }

    # Nombre del share
    # Reutilizar Perfiles$ si ya existe desde Invoke-OUSetup
    $existingShare = Get-SmbShare -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $localPath } |
    Select-Object -First 1

    $defaultShare = if ($existingShare) { $existingShare.Name } else { 'Perfiles$' }

    $shareName = Read-InputLoop `
        -Prompt "Nombre del share SMB (Enter para '$defaultShare')" `
        -Validator { param($v) $v -match '^[a-zA-Z0-9_\-\$]{1,80}$' -or $v -eq '' } `
        -ErrorMsg  "Nombre de share invalido. Solo letras, numeros, guiones y `$." `
        -AllowEmpty $true

    if ($shareName -eq $false) { return $false }
    if ([string]::IsNullOrWhiteSpace($shareName)) { $shareName = $defaultShare }

    $script:ROAMING_SHARE_PATH = $localPath
    $script:ROAMING_SHARE_NAME = $shareName

    Write-Log INFO "Ruta local  : $script:ROAMING_SHARE_PATH"
    Write-Log INFO "Nombre share: $script:ROAMING_SHARE_NAME"
    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# New-RoamingShare
# Crea la carpeta local y el share SMB con los permisos correctos para
# Perfiles Moviles segun las recomendaciones de Microsoft:
#   - Share: Todos / Control Total (las ACLs NTFS son las que restringen)
#   - NTFS carpeta raiz: Admins + SYSTEM control total; Usuarios autenticados:
#     List + CreateDirectories (no leer carpetas de otros usuarios)
#   - NTFS subcarpetas (CREATOR OWNER): control total sobre la propia carpeta
#
# Devuelve: $true | $false
# ─────────────────────────────────────────────────────────────────────────────
function New-RoamingShare {
    if (-not $script:ROAMING_SHARE_PATH -or -not $script:ROAMING_SHARE_NAME) {
        Write-Log ERROR "Ejecuta Initialize-RoamingPaths primero."
        return $false
    }

    $path = $script:ROAMING_SHARE_PATH
    $shareName = $script:ROAMING_SHARE_NAME

    # 1. Crear carpeta si no existe
    if (-not (Test-Path $path)) {
        try {
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
            Write-Log SUCCESS "Carpeta creada: $path"
        }
        catch {
            Write-Log ERROR "No se pudo crear la carpeta '$path': $_"
            return $false
        }
    }
    else {
        Write-Log INFO "Carpeta ya existe: $path"
    }

    # 2. Configurar ACLs NTFS
    try {
        $acl = Get-Acl -Path $path

        # Deshabilitar herencia y limpiar entradas heredadas
        $acl.SetAccessRuleProtection($true, $false)

        # Resolver SIDs a objetos de identidad
        $sidSystem = New-Object System.Security.Principal.SecurityIdentifier($script:SID_SYSTEM)
        $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier($script:SID_ADMINS)
        $sidAuth = New-Object System.Security.Principal.SecurityIdentifier($script:SID_AUTHENTICATED)
        $sidCreator = New-Object System.Security.Principal.SecurityIdentifier($script:SID_CREATOR_OWNER)

        $rights = [System.Security.AccessControl.FileSystemRights]
        $inheritance = [System.Security.AccessControl.InheritanceFlags]
        $propagation = [System.Security.AccessControl.PropagationFlags]
        $type = [System.Security.AccessControl.AccessControlType]::Allow

        # SYSTEM: control total, esta carpeta + subcarpetas + archivos
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sidSystem,
                    $rights::FullControl,
                    ($inheritance::ContainerInherit -bor $inheritance::ObjectInherit),
                    $propagation::None,
                    $type
                )))

        # Administradores: FullControl en la carpeta raiz (sin herencia a subcarpetas).
        # Windows necesita que el proceso de Winlogon/userinit pueda gestionar la
        # carpeta raiz durante la sincronizacion del perfil al logon/logoff.
        # Sync-RoamingProfileQuotas sobreescribe los permisos de cada .V6 individualmente.
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sidAdmins,
                    $rights::FullControl,
                    $inheritance::None,
                    $propagation::None,
                    $type
                )))

        # Usuarios Autenticados — ACE 1: en la carpeta RAIZ.
        # CreateDirectories permite crear la subcarpeta propia (mano\, mano.V6\).
        # Traversal (ReadAndExecute) es obligatorio para entrar a la ruta UNC.
        # None: no hereda hacia abajo — cada subcarpeta tiene sus propias ACEs.
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sidAuth,
                    ($rights::ReadAndExecute -bor $rights::ListDirectory -bor
                     $rights::ReadAttributes -bor $rights::CreateDirectories),
                    $inheritance::None,
                    $propagation::None,
                    $type
                )))

        # Usuarios Autenticados — ACE 2: en subcarpetas de primer nivel (mano\, mano.V6\).
        # Folder Redirection crea mano\Documents\, mano\Desktop\, etc. dentro de mano\.
        # Para eso necesita Traversal + CreateDirectories en esa subcarpeta.
        # ContainerInherit+InheritOnly: aplica solo a subcarpetas directas, no a la raiz
        # ni a archivos. CREATOR OWNER toma el control total una vez creadas.
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sidAuth,
                    ($rights::ReadAndExecute -bor $rights::CreateDirectories),
                    $inheritance::ContainerInherit,
                    $propagation::InheritOnly,
                    $type
                )))

        # CREATOR OWNER: control total en subcarpetas y archivos (la carpeta del
        # perfil la crea Windows al primer logon, el propietario es el usuario)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sidCreator,
                    $rights::FullControl,
                    ($inheritance::ContainerInherit -bor $inheritance::ObjectInherit),
                    $propagation::InheritOnly,
                    $type
                )))

        Set-Acl -Path $path -AclObject $acl -ErrorAction Stop
        Write-Log SUCCESS "ACLs NTFS configuradas en '$path' (SIDs universales)."
    }
    catch {
        Write-Log ERROR "Error al configurar ACLs NTFS: $_"
        return $false
    }

    # 3. Crear share SMB
    $existingShare = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if ($null -ne $existingShare) {
        Write-Log INFO "Share '$shareName' ya existe. Se verifican permisos."
    }
    else {
        try {
            # Share con acceso Everyone/Control Total - las ACLs NTFS son la
            # verdadera barrera de seguridad (practica estandar MS para perfiles)
            New-SmbShare -Name $shareName -Path $path `
                -FullAccess 'Everyone' `
                -FolderEnumerationMode 'AccessBased' `
                -ErrorAction Stop | Out-Null
            Write-Log SUCCESS "Share SMB creado: \\$env:COMPUTERNAME\$shareName -> $path"
            msg_success "Share '\\$env:COMPUTERNAME\$shareName' disponible."
        }
        catch {
            Write-Log WARN "No se pudo crear share con 'Everyone'. Intentando fallback..."
            try {
                New-SmbShare -Name $shareName -Path $path -ErrorAction Stop | Out-Null
                Grant-SmbShareAccess -Name $shareName -AccountName 'Everyone' `
                    -AccessRight Full -Force -ErrorAction SilentlyContinue | Out-Null
                Write-Log SUCCESS "Share SMB creado (fallback - sin FolderEnumeration)."
            }
            catch {
                Write-Log ERROR "No se pudo crear el share '$shareName': $_"
                return $false
            }
        }
    }

    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# Set-UserProfilePath
# Establece el atributo ProfilePath en AD para un usuario.
# La ruta UNC debe ser: \\servidor\share\%username%
# Windows agrega ".V6" automaticamente al primer logon (Win10/11).
#
# Parametros:
#   -SamAccountName  Login del usuario
#   -ProfileUNCPath  Ruta UNC base sin el SAM (ej: \\SRV-DC01\Perfiles$)
#
# Devuelve: $true | $false
# ─────────────────────────────────────────────────────────────────────────────
function Set-UserProfilePath {
    param(
        [Parameter(Mandatory)] [string] $SamAccountName,
        [Parameter(Mandatory)] [string] $ProfileUNCPath
    )

    # Construir ruta completa para este usuario
    $fullPath = "$ProfileUNCPath\$SamAccountName"

    # --- Atributo AD ---
    try {
        $user = Get-ADUser -Identity $SamAccountName -Properties ProfilePath -ErrorAction Stop

        if ($user.ProfilePath -ne $fullPath) {
            Set-ADUser -Identity $SamAccountName -ProfilePath $fullPath -ErrorAction Stop
            Write-Log SUCCESS "ProfilePath  '$SamAccountName' -> $fullPath"
        }
        else {
            Write-Log INFO "ProfilePath ya configurado para '$SamAccountName'. Sin cambios."
        }
    }
    catch {
        Write-Log ERROR "No se pudo establecer ProfilePath de '$SamAccountName': $_"
        return $false
    }

    # --- Pre-crear carpeta local .V6 con permisos explícitos ---
    # Evita la condicion de carrera del primer logoff donde Windows crea la
    # carpeta vaciä y falla al copiar NTUSER.DAT (bloqueado).
    if ([string]::IsNullOrWhiteSpace($script:ROAMING_SHARE_PATH)) { return $true }

    $domainNetBIOS = $env:USERDOMAIN
    $folderPath    = "$script:ROAMING_SHARE_PATH\$SamAccountName.V6"

    if (-not (Test-Path $folderPath)) {
        try {
            New-Item -ItemType Directory -Path $folderPath -Force -ErrorAction Stop | Out-Null
            Write-Log INFO "  Carpeta pre-creada: $folderPath"
        }
        catch {
            Write-Log WARN "  No se pudo pre-crear '$folderPath': $_"
            return $true  # No es fatal; seguimos
        }
    }

    # Permisos explicitos: usuario=Full, SYSTEM=Full, Admins=RX
    # /C continua ante errores (ej: NTUSER.DAT bloqueado por sesion activa)
    # /T recursivo — archivos bloqueados se omiten con warning, no son fatales.
    try {
        $icaclsOut = & icacls $folderPath /inheritance:r `
            /grant:r "${domainNetBIOS}\${SamAccountName}:(OI)(CI)F" `
            /grant:r "NT AUTHORITY\SYSTEM:(OI)(CI)F" `
            /grant:r "*S-1-5-32-544:(OI)(CI)RX" `
            /T /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log WARN "  icacls advirtio en '$folderPath' (puede ser NTUSER.DAT bloqueado): $icaclsOut"
        }
        else {
            Write-Log SUCCESS "  Permisos aplicados en '$folderPath'."
        }
    }
    catch {
        Write-Log WARN "  icacls no pudo completar en '$folderPath': $_"
    }
    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# Set-RoamingProfilesForGroup
# Aplica ProfilePath a todos los miembros de un grupo AD.
#
# Devuelve: numero de usuarios actualizados correctamente
# ─────────────────────────────────────────────────────────────────────────────
function Set-RoamingProfilesForGroup {
    param(
        [Parameter(Mandatory)] [string] $GroupName,
        [Parameter(Mandatory)] [string] $ProfileUNCPath
    )

    Write-Log INFO "Configurando perfiles moviles para grupo: $GroupName"

    try {
        $members = @(Get-ADGroupMember -Identity $GroupName -ErrorAction Stop |
            Where-Object { $_.objectClass -eq 'user' })
    }
    catch {
        Write-Log ERROR "No se pudo leer el grupo '$GroupName': $_"
        return 0
    }

    if ($members.Count -eq 0) {
        Write-Log WARN "El grupo '$GroupName' no tiene miembros."
        return 0
    }

    $ok = 0
    foreach ($m in $members) {
        if (Set-UserProfilePath -SamAccountName $m.SamAccountName -ProfileUNCPath $ProfileUNCPath) {
            $ok++
        }
    }

    Write-Log INFO "Perfiles moviles configurados: $ok / $($members.Count) usuarios"
    return $ok
}

# ─────────────────────────────────────────────────────────────────────────────
# New-RoamingProfilesGPO
# Crea / actualiza la GPO "PerfilesMoviles-T08" con los ajustes de:
#   - Redirección de carpetas (Documents, Desktop)
#   - Tiempo de espera para descarga del perfil (timeout)
#   - Sincronización de perfiles bajo WAN
#
# Devuelve: $true | $false
# ─────────────────────────────────────────────────────────────────────────────
function New-RoamingProfilesGPO {
    param(
        [Parameter(Mandatory)] [string] $GPOName
    )

    Write-LogSection "Creando GPO de Perfiles Moviles: $GPOName"

    if (-not (Get-GPO -Name $GPOName -ErrorAction SilentlyContinue)) {
        try {
            New-GPO -Name $GPOName -ErrorAction Stop | Out-Null
            Write-Log SUCCESS "GPO creada: $GPOName"
        }
        catch {
            Write-Log ERROR "No se pudo crear la GPO: $_"
            return $false
        }
    }
    else {
        Write-Log INFO "GPO ya existe: $GPOName"
    }

    # Configurar politicas via Set-GPRegistryValue (Computer Configuration)
    # Ruta: Computer Configuration > Policies > Admin Templates > System > User Profiles
    $gpoKey = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System'
    $policies = @(
        @{ Name = 'WaitForRemoteProfile';  Value = 30; Desc = 'Timeout descarga perfil = 30 s' },
        @{ Name = 'AddAdminGroupToRUP';    Value = 1;  Desc = 'Agregar Administradores al perfil movil' },
        @{ Name = 'CompatibleRUPSecurity'; Value = 1;  Desc = 'No verificar propiedad de carpeta de perfil' }
    )

    $errors = 0
    foreach ($pol in $policies) {
        try {
            Set-GPRegistryValue -Name $GPOName -Key $gpoKey `
                -ValueName $pol.Name -Value $pol.Value -Type DWord `
                -ErrorAction Stop | Out-Null
            Write-Log INFO "GPO: $($pol.Desc)"
        }
        catch {
            Write-Log WARN "No se pudo aplicar '$($pol.Name)': $_"
            $errors++
        }
    }

    if ($errors -ge $policies.Count) {
        Write-Log ERROR "No se pudo configurar ninguna politica en la GPO '$GPOName'."
        return $false
    }

    Write-Log SUCCESS "GPO '$GPOName' configurada correctamente."

    # Registrar logon script que redirige Shell Folders al share en tiempo real
    Register-FolderRedirectionScript -GPOName $GPOName -DomainName $script:AD_DOMAIN | Out-Null

    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# Register-FolderRedirectionScript
# Copia Set-FolderRedirection.ps1 a NETLOGON y lo registra como logon script
# en la GPO via scripts.ini. Al login, el script redirige Shell Folders
# (Documents, Desktop, Downloads, Music, Pictures, Videos) al share de perfiles
# escribiendo directamente en HKCU\...\Shell Folders — sin depender del CSE
# de Folder Redirection. Con esto FSRM intercepta cada escritura en tiempo real.
#
# Parametros:
#   -GPOName    Nombre de la GPO de perfiles moviles
#   -DomainName FQDN del dominio (ej: practica.local)
#
# Devuelve: $true | $false
# ─────────────────────────────────────────────────────────────────────────────
function Register-FolderRedirectionScript {
    param(
        [Parameter(Mandatory)] [string] $GPOName,
        [Parameter(Mandatory)] [string] $DomainName
    )

    try {
        $scriptName = 'Set-FolderRedirection.ps1'

        # ── 1. Generar el script en NETLOGON ─────────────────────────────────
        $netlogon = "\\$DomainName\NETLOGON"
        if (-not (Test-Path $netlogon)) {
            Write-Log WARN "No se puede acceder a NETLOGON: $netlogon"
            return $false
        }

        $scriptDest = Join-Path $netlogon $scriptName
        $shareName  = $script:ROAMING_SHARE_NAME

        if ([string]::IsNullOrWhiteSpace($shareName)) {
            Write-Log WARN "ROAMING_SHARE_NAME no esta definido. Folder Redirection omitida."
            return $false
        }

        # El script se genera con el nombre del share fijo para que funcione
        # aunque LOGONSERVER difiera del servidor donde se configuró el share.
        $scriptContent = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$server = (`$env:LOGONSERVER -replace '\\\\\\\\','').Trim()
if (-not `$server) { exit 0 }
`$base = "\\\\`$server\\$shareName\\`$env:USERNAME"
foreach (`$sub in 'Desktop','Documents','Downloads','Music','Pictures','Videos') {
    `$p = "`$base\\`$sub"
    if (-not (Test-Path `$p)) { New-Item -Path `$p -ItemType Directory -Force | Out-Null }
}
`$mappings = @{
    'Desktop'                                = "`$base\\Desktop"
    'Personal'                               = "`$base\\Documents"
    '{FDD39AD0-238F-46AF-ADB4-6C85480369C7}' = "`$base\\Documents"
    '{374DE290-123F-4565-9164-39C4925E467B}' = "`$base\\Downloads"
    'My Music'                               = "`$base\\Music"
    'My Pictures'                            = "`$base\\Pictures"
    'My Video'                               = "`$base\\Videos"
}
`$keys = @(
    'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders',
    'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders'
)
foreach (`$k in `$keys) {
    foreach (`$name in `$mappings.Keys) {
        try { Set-ItemProperty -Path `$k -Name `$name -Value `$mappings[`$name] -Force } catch {}
    }
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Shell32 {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
'@ -ErrorAction SilentlyContinue
try { [Shell32]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero) } catch {}
"@
        $scriptContent | Out-File -FilePath $scriptDest -Encoding UTF8 -Force
        Write-Log SUCCESS "Logon script escrito: $scriptDest"

        # ── 2. Registrar en scripts.ini de la GPO ────────────────────────────
        $gpo   = Get-GPO -Name $GPOName -ErrorAction Stop
        $gpoId = $gpo.Id.ToString().ToUpper()

        $scriptsDir  = "\\$DomainName\SYSVOL\$DomainName\Policies\{$gpoId}\User\Scripts"
        $logonDir    = Join-Path $scriptsDir 'Logon'
        $iniPath     = Join-Path $scriptsDir 'scripts.ini'

        if (-not (Test-Path $logonDir)) {
            New-Item -Path $logonDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $iniContent = ''
        if (Test-Path $iniPath) {
            $iniContent = Get-Content $iniPath -Raw -ErrorAction SilentlyContinue
        }

        if ($iniContent -notmatch [regex]::Escape($scriptName)) {
            $idx = ([regex]::Matches($iniContent, 'CmdLine=')).Count
            if ($iniContent -match '\[Logon\]') {
                $iniContent = $iniContent.TrimEnd() + "`r`n${idx}CmdLine=powershell.exe`r`n${idx}Parameters=-NoProfile -ExecutionPolicy Bypass -File `"\\$DomainName\NETLOGON\$scriptName`"`r`n"
            }
            else {
                $iniContent = $iniContent.TrimEnd() + "`r`n[Logon]`r`n${idx}CmdLine=powershell.exe`r`n${idx}Parameters=-NoProfile -ExecutionPolicy Bypass -File `"\\$DomainName\NETLOGON\$scriptName`"`r`n"
            }
            $iniContent | Out-File $iniPath -Encoding Unicode -Force
            Write-Log SUCCESS "Logon script registrado en scripts.ini"
        }
        else {
            Write-Log INFO "Logon script ya registrado en scripts.ini"
        }

        # ── 3. Incrementar GPT.INI ────────────────────────────────────────────
        $gptPath = "\\$DomainName\SYSVOL\$DomainName\Policies\{$gpoId}\GPT.INI"
        if (Test-Path $gptPath) {
            $gptContent = Get-Content $gptPath -Raw
            if ($gptContent -match 'Version=(\d+)') {
                $currentVer  = [int]$Matches[1]
                $userVer     = (($currentVer -shr 16) -band 0xFFFF) + 1
                $computerVer = ($currentVer -band 0xFFFF) + 1
                $newVer      = ($userVer -shl 16) -bor $computerVer
                $gptContent  = $gptContent -replace 'Version=\d+', "Version=$newVer"
                $gptContent | Out-File $gptPath -Encoding ASCII -Force
                Write-Log INFO "GPT.INI version: $currentVer -> $newVer"
            }
        }

        # ── 4. ExcludeProfileDirs: evitar doble sync con perfil movil ────────
        $excludeKey  = 'HKCU\Software\Policies\Microsoft\Windows\System'
        $excludeDirs = 'AppData\Roaming\Microsoft\Windows\Start Menu;Desktop;Documents;Downloads;Favorites;Music;Pictures;Videos'
        try {
            Set-GPRegistryValue -Name $GPOName -Key $excludeKey `
                -ValueName 'ExcludeProfileDirs' -Value $excludeDirs -Type String `
                -ErrorAction Stop | Out-Null
            Write-Log INFO "GPO: Carpetas redirigidas excluidas del perfil movil"
        }
        catch {
            Write-Log WARN "No se pudo configurar ExcludeProfileDirs: $_"
        }

        Write-Log SUCCESS "Folder Redirection via logon script configurada."
        return $true
    }
    catch {
        Write-Log WARN "No se pudo registrar el logon script de Folder Redirection: $_"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Add-RoamingProfilesGPLink
# Vincula la GPO a una OU específica
#
# Parametros:
#   -GPOName      Nombre de la GPO
#   -OUPath       DN de la OU (ej: OU=Cuates,DC=practica,DC=local)
#
# Devuelve: $true | $false
# ─────────────────────────────────────────────────────────────────────────────
function Add-RoamingProfilesGPLink {
    param(
        [Parameter(Mandatory)] [string] $GPOName,
        [Parameter(Mandatory)] [string] $OUPath
    )

    Write-Log INFO "Vinculando GPO '$GPOName' a OU: $OUPath"

    try {
        # Verificar si la GPO ya esta vinculada usando Get-GPInheritance
        $inheritance = Get-GPInheritance -Target $OUPath -ErrorAction Stop
        $alreadyLinked = $inheritance.GpoLinks | Where-Object { $_.DisplayName -eq $GPOName }

        if ($alreadyLinked) {
            Write-Log INFO "GPO ya vinculada a esta OU. Sin cambios."
            return $true
        }

        New-GPLink -Name $GPOName -Target $OUPath -LinkEnabled Yes `
            -ErrorAction Stop | Out-Null
        Write-Log SUCCESS "GPO vinculada: $GPOName -> $OUPath"
        return $true
    }
    catch {
        Write-Log ERROR "No se pudo vincular la GPO: $_"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Invoke-RoamingMenu
# Orquestador principal: solicita input, crea share, configura usuarios y GPO.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-RoamingMenu {
    Write-LogSection "PERFILES MOVILES - Configuracion Interactiva"

    if (-not $script:AD_DOMAIN_DN) {
        Write-Log ERROR "No hay conexion al dominio. Usa la opcion C primero."
        return $false
    }

    # 1. Solicitar rutas
    if (-not (Initialize-RoamingPaths)) {
        Write-Log WARN "Configuracion de rutas cancelada."
        return $false
    }

    # 2. Crear share
    if (-not (New-RoamingShare)) {
        Write-Log ERROR "No se pudo crear el share. Abortando."
        return $false
    }

    # 3. Construir ruta UNC
    $profileUNC = "\\$env:COMPUTERNAME\$script:ROAMING_SHARE_NAME"

    # 3b. Preparar FSRM: file group, template de screen y cuotas si el modulo esta disponible
    if (Get-Command 'Sync-RoamingProfileQuotas' -ErrorAction SilentlyContinue) {
        Write-LogSection "Preparando FSRM para directorio de perfiles"

        # Apuntar FSRM_HOMES_ROOT al directorio de perfiles moviles y persistirlo
        $script:FSRM_HOMES_ROOT = $script:ROAMING_SHARE_PATH
        if (Get-Command 'Save-FSRMConfig' -ErrorAction SilentlyContinue) {
            Save-FSRMConfig
        }

        # Garantizar que el file group y el template de screen existan antes de que
        # el watcher los necesite. Sync-RoamingProfileQuotas los busca por nombre fijo.
        $screenTemplateName = 'Pantalla-Prohibidos-T08'
        $fileGroupName      = 'Archivos-Prohibidos-T08'

        $blockedExts = @('.mp3','.mp4','.avi','.mkv','.mov','.wmv',
                         '.flv','.wav','.aac','.ogg','.wma',
                         '.exe','.msi','.bat','.cmd','.vbs',
                         '.dll','.scr','.com','.pif')

        # Crear / actualizar el file group
        if (Get-Command 'New-ACFileGroup' -ErrorAction SilentlyContinue) {
            New-ACFileGroup -GroupName $fileGroupName -Extensions $blockedExts | Out-Null
        }

        # Crear / actualizar el template de file screen si el cmdlet esta disponible
        if (Get-Command 'New-FsrmFileScreenTemplate' -ErrorAction SilentlyContinue) {
            $existingTmpl = Get-FsrmFileScreenTemplate -Name $screenTemplateName -ErrorAction SilentlyContinue
            if (-not $existingTmpl) {
                try {
                    $evtAction = New-FsrmAction -Type Event -EventType Warning `
                        -Body "Archivo bloqueado en [File Screen Path]: [Source File Path] ([Source Io Owner])" `
                        -ErrorAction Stop
                    New-FsrmFileScreenTemplate -Name $screenTemplateName `
                        -IncludeGroup @($fileGroupName) `
                        -Active `
                        -Notification @($evtAction) `
                        -ErrorAction Stop | Out-Null
                    Write-Log SUCCESS "Template file screen creado: $screenTemplateName"
                }
                catch {
                    Write-Log WARN "No se pudo crear el template '$screenTemplateName': $_"
                }
            }
            else {
                Write-Log INFO "Template file screen ya existe: $screenTemplateName"
            }
        }

        # Sincronizar carpetas .V6 que ya existan (primer pase)
        Sync-RoamingProfileQuotas | Out-Null

        # Registrar watcher para detectar nuevas carpetas .V6 en tiempo real
        if (Get-Command 'Register-RoamingProfileWatcher' -ErrorAction SilentlyContinue) {
            Register-RoamingProfileWatcher | Out-Null
        }
    }
    else {
        Write-Log WARN "Modulo FSRM no cargado: cuotas y reglas de archivo no seran aplicadas."
    }

    # 4. Permitir seleccionar grupos para aplicar perfiles
    Write-LogSection "Seleccionar Grupos para Perfiles Moviles"
    $groupSel = Read-MultiSelect `
        -Options @("GRP_Cuates", "GRP_NoCuates") `
        -Prompt "Selecciona grupos para aplicar perfiles moviles" `
        -AllowAll $true

    if ($groupSel -and $groupSel.Count -gt 0) {
        foreach ($grp in $groupSel) {
            Set-RoamingProfilesForGroup -GroupName $grp.Value -ProfileUNCPath $profileUNC
        }
    }

    # 5. Crear y vincular GPO
    if (-not (New-RoamingProfilesGPO -GPOName $script:ROAMING_GPO_NAME)) {
        Write-Log WARN "GPO no configurada, pero share esta listo."
    }
    else {
        Write-LogSection "Vinculando GPO a OUs"
        $ouSel = Read-MultiSelect `
            -Options @("OU=Cuates,$script:AD_DOMAIN_DN", "OU=NoCuates,$script:AD_DOMAIN_DN") `
            -Prompt "Selecciona OUs para vincular la GPO" `
            -AllowAll $true
        if ($ouSel -and $ouSel.Count -gt 0) {
            foreach ($ou in $ouSel) {
                Add-RoamingProfilesGPLink -GPOName $script:ROAMING_GPO_NAME -OUPath $ou.Value
            }
        }
    }

    Write-LogSection "Configuracion de Perfiles Moviles - COMPLETADA"
    Write-Log INFO "Share disponible en: $profileUNC"
    return $true
}
