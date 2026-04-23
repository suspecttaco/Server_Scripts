# =============================================================================
# ac_lib/ac_ad.ps1 - Gestion de Active Directory: OUs, grupos, usuarios
# Uso: . .\ac_lib\ac_ad.ps1
# Requiere: lib/ui.ps1, lib/utils.ps1, lib/input.ps1, ac_lib/ac_log.ps1
# =============================================================================

#Requires -Module ActiveDirectory

# -----------------------------------------------------------------------------
# VARIABLES DE MODULO
# -----------------------------------------------------------------------------
$script:AD_DOMAIN        = $null   # FQDN detectado o ingresado
$script:AD_DOMAIN_DN     = $null   # DistinguishedName base (DC=practica,DC=local)
$script:AD_NETBIOS       = $null   # Nombre NetBIOS
$script:AD_OUS           = @()     # OUs creadas en esta sesion [{Name, DN, Group}]

# -----------------------------------------------------------------------------
# Test-ADModuleAvailable
# Verifica que el modulo ActiveDirectory este disponible.
# -----------------------------------------------------------------------------
function Test-ADModuleAvailable {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Log ERROR "El modulo ActiveDirectory no esta disponible."
        Write-Log ERROR "Instala las herramientas RSAT o ejecuta desde el Domain Controller."
        return $false
    }
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    } catch {
        Write-Log ERROR "No se pudo importar el modulo ActiveDirectory: $_"
        return $false
    }
    return $true
}

# -----------------------------------------------------------------------------
# Initialize-ADConnection
# Detecta o solicita el dominio y valida la conexion con el DC.
# Carga: $script:AD_DOMAIN, $script:AD_DOMAIN_DN, $script:AD_NETBIOS
# -----------------------------------------------------------------------------
function Initialize-ADConnection {
    Write-LogSection "Conexion al Dominio de Active Directory"

    if (-not (Test-ADModuleAvailable)) { return $false }

    # Intentar deteccion automatica
    $detected = $null
    try {
        $detected = Get-ADDomain -ErrorAction Stop
        Write-Log INFO "Dominio detectado automaticamente: $($detected.DNSRoot)"
    } catch {
        Write-Log WARN "No se pudo detectar el dominio automaticamente: $_"
    }

    if ($null -ne $detected) {
        $confirm = Read-Confirm "Usar dominio detectado '$($detected.DNSRoot)'"  -Default 'S'
        if ($confirm) {
            $script:AD_DOMAIN    = $detected.DNSRoot
            $script:AD_DOMAIN_DN = $detected.DistinguishedName
            $script:AD_NETBIOS   = $detected.NetBIOSName
            Write-Log SUCCESS "Conectado al dominio: $script:AD_DOMAIN"
            return $true
        }
    }

    # Solicitar manualmente
    $fqdn = Read-InputLoop `
        -Prompt "FQDN del dominio (ej: practica.local)" `
        -Validator { param($v) $v -match '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$' } `
        -ErrorMsg "Formato invalido. Ejemplo: practica.local"
    if ($fqdn -eq $false) { return $false }

    try {
        $dom = Get-ADDomain -Identity $fqdn -ErrorAction Stop
        $script:AD_DOMAIN    = $dom.DNSRoot
        $script:AD_DOMAIN_DN = $dom.DistinguishedName
        $script:AD_NETBIOS   = $dom.NetBIOSName
        Write-Log SUCCESS "Conectado al dominio: $script:AD_DOMAIN"
        return $true
    } catch {
        Write-Log ERROR "No se pudo conectar al dominio '$fqdn': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Get-ADDN
# Construye el DistinguishedName de una OU relativo al dominio.
# Ejemplo: Get-ADDN "Cuates" -> "OU=Cuates,DC=practica,DC=local"
# -----------------------------------------------------------------------------
function Get-ADDN {
    param(
        [string] $OUName,
        [string] $ParentDN = $null
    )
    $base = if ($ParentDN) { $ParentDN } else { $script:AD_DOMAIN_DN }
    return "OU=$OUName,$base"
}

# -----------------------------------------------------------------------------
# Get-ExistingOUs
# Devuelve todas las OUs existentes en el dominio como array de strings DN.
# -----------------------------------------------------------------------------
function Get-ExistingOUs {
    try {
        $ous = Get-ADOrganizationalUnit -Filter * -SearchBase $script:AD_DOMAIN_DN `
               -ErrorAction Stop | Select-Object -ExpandProperty DistinguishedName
        return @($ous)
    } catch {
        Write-Log WARN "No se pudieron obtener las OUs existentes: $_"
        return @()
    }
}

# -----------------------------------------------------------------------------
# New-ADOU
# Crea una Unidad Organizativa. Si ya existe, lo indica y continua.
#
# Parametros:
#   -Name       Nombre de la OU
#   -ParentDN   DN del contenedor padre (default: raiz del dominio)
#   -Description Descripcion opcional
#   -Protected  Si $true, protege contra eliminacion accidental
#
# Devuelve: DN de la OU creada o existente | $false si fallo
# -----------------------------------------------------------------------------
function New-ADOU {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $ParentDN    = $null,
        [string] $Description = "",
        [bool]   $Protected   = $true
    )

    $parent = if ($ParentDN) { $ParentDN } else { $script:AD_DOMAIN_DN }
    $dn     = "OU=$Name,$parent"

    # Verificar si ya existe
    try {
        $existing = Get-ADOrganizationalUnit -Identity $dn -ErrorAction Stop
        Write-Log WARN "La OU '$Name' ya existe: $dn"
        return $dn
    } catch {}

    # Crear la OU
    try {
        $params = @{
            Name                            = $Name
            Path                            = $parent
            ProtectedFromAccidentalDeletion = $Protected
            ErrorAction                     = 'Stop'
        }
        if ($Description -ne "") { $params['Description'] = $Description }

        Invoke-Logged "Crear OU: $Name en $parent" {
            New-ADOrganizationalUnit @params
        } | Out-Null

        Write-Log SUCCESS "OU creada: $dn"
        return $dn
    } catch {
        Write-Log ERROR "No se pudo crear la OU '$Name': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# New-ADSecurityGroup
# Crea un grupo de seguridad global. Si ya existe, continua sin error.
#
# Parametros:
#   -Name        Nombre del grupo
#   -OuDN        DN de la OU donde se crea el grupo
#   -Description Descripcion opcional
#   -Scope       DomainLocal | Global | Universal (default: Global)
#
# Devuelve: nombre del grupo | $false si fallo
# -----------------------------------------------------------------------------
function New-ADSecurityGroup {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $OuDN,
        [string] $Description = "",
        [string] $Scope       = 'Global'
    )

    # Verificar si ya existe
    try {
        Get-ADGroup -Identity $Name -ErrorAction Stop | Out-Null
        Write-Log WARN "El grupo '$Name' ya existe."
        return $Name
    } catch {}

    try {
        $params = @{
            Name          = $Name
            Path          = $OuDN
            GroupScope    = $Scope
            GroupCategory = 'Security'
            ErrorAction   = 'Stop'
        }
        if ($Description -ne "") { $params['Description'] = $Description }

        Invoke-Logged "Crear grupo: $Name en $OuDN" {
            New-ADGroup @params
        } | Out-Null

        Write-Log SUCCESS "Grupo creado: $Name"
        return $Name
    } catch {
        Write-Log ERROR "No se pudo crear el grupo '$Name': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Invoke-OUSetup
# Flujo interactivo completo para crear OUs y sus grupos de seguridad.
# El usuario define cuantas OUs crear, sus nombres, descripciones y
# si cada OU tendra un grupo de seguridad asociado.
#
# Popula $script:AD_OUS con los resultados.
# Devuelve: $true si al menos una OU fue creada | $false si fallo total
# -----------------------------------------------------------------------------
function Invoke-OUSetup {
    Write-LogSection "Configuracion de Unidades Organizativas"

    if (-not $script:AD_DOMAIN_DN) {
        Write-Log ERROR "No hay conexion al dominio. Ejecuta Initialize-ADConnection primero."
        return $false
    }

    msg_info "Las OUs se crearan en la raiz del dominio: $script:AD_DOMAIN_DN"
    msg_info "Puedes crear tantas OUs como necesites para tu estructura organizativa."
    Write-Host ""

    $count = Read-IntInRange `
        -Prompt "Cuantas Unidades Organizativas deseas crear" `
        -Min 1 -Max 50
    if ($count -eq $false) { return $false }

    $created = [System.Collections.Generic.List[hashtable]]::new()

    for ($i = 1; $i -le $count; $i++) {
        Write-Host ""
        msg_info "─── Unidad Organizativa $i de $count ───"

        # Nombre
        $ouName = Read-InputLoop `
            -Prompt "Nombre de la OU $i" `
            -Validator {
                param($v)
                $v -match '^[a-zA-Z0-9][a-zA-Z0-9 _\-]{0,63}$'
            } `
            -ErrorMsg "Nombre invalido. Usa letras, numeros, espacios, guiones o guion bajo. Max 64 chars."
        if ($ouName -eq $false) {
            Write-Log WARN "OU $i omitida por demasiados intentos fallidos."
            continue
        }

        # Descripcion
        $ouDesc = Read-InputLoop `
            -Prompt "Descripcion de la OU '$ouName'" `
            -Validator { $true } `
            -AllowEmpty $true
        if ($ouDesc -eq $false) { $ouDesc = "" }

        # Proteccion contra eliminacion
        $protected = Read-Confirm `
            -Prompt "Proteger '$ouName' contra eliminacion accidental" `
            -Default 'S'

        # Crear la OU
        $ouDN = New-ADOU -Name $ouName -Description $ouDesc -Protected $protected
        if ($ouDN -eq $false) {
            Write-Log WARN "OU '$ouName' no pudo crearse. Continuando con la siguiente."
            continue
        }

        # Grupo de seguridad asociado
        $createGroup = Read-Confirm `
            -Prompt "Crear grupo de seguridad asociado a '$ouName'" `
            -Default 'S'

        $groupName = $null
        if ($createGroup) {
            $suggestedGroup = "GRP_$($ouName -replace '\s+','_')"

            $groupName = Read-InputLoop `
                -Prompt "Nombre del grupo (Enter para usar '$suggestedGroup')" `
                -Validator { param($v) $v -match '^[a-zA-Z0-9][a-zA-Z0-9 _\-]{0,63}$' } `
                -ErrorMsg "Nombre de grupo invalido." `
                -AllowEmpty $true
            if ($null -eq $groupName) { $groupName = $suggestedGroup }
            if ($groupName -eq $false) { $groupName = $suggestedGroup }

            $groupDesc = Read-InputLoop `
                -Prompt "Descripcion del grupo '$groupName'" `
                -Validator { $true } `
                -AllowEmpty $true
            if ($groupDesc -eq $false -or $null -eq $groupDesc) { $groupDesc = "Grupo de seguridad para OU $ouName" }

            $groupScope = Read-Selection `
                -Prompt "Ambito del grupo '$groupName'" `
                -Options @('Global', 'DomainLocal', 'Universal')
            if ($groupScope -eq $false) { $groupScope = [PSCustomObject]@{ Value = 'Global' } }

            $result = New-ADSecurityGroup `
                -Name  $groupName `
                -OuDN  $ouDN `
                -Description $groupDesc `
                -Scope $groupScope.Value
            if ($result -eq $false) { $groupName = $null }
        }

        $entry = @{
            Name      = $ouName
            DN        = $ouDN
            Group     = $groupName
            Protected = $protected
        }
        $created.Add($entry)
        $script:AD_OUS += $entry

        Write-Host ""
        msg_success "OU '$ouName' configurada."
        if ($groupName) { msg_success "Grupo '$groupName' asociado." }
    }

    if ($created.Count -eq 0) {
        Write-Log ERROR "No se creo ninguna OU."
        return $false
    }

    # Resumen
    Write-Host ""
    Write-LogSection "Resumen de OUs creadas"
    $created | ForEach-Object {
        $grp = if ($_.Group) { "Grupo: $($_.Group)" } else { "Sin grupo" }
        msg_info "  $($_.Name)  |  $grp  |  $($_.DN)"
    }

    Write-Log SUCCESS "OUs configuradas: $($created.Count) de $count"

    # ── OU Equipos (siempre creada, separada de usuarios) ─────────────────────
    # CRITICO: los equipos cliente deben ir en una OU separada de las OUs de
    # usuarios. Si un equipo esta en OU=NoCuates recibe la GPO de AppLocker
    # como configuracion de equipo y bloquea dwm.exe → pantalla negra.
    $equiposOU = New-ADOU `
        -Name        "Equipos" `
        -Description "Equipos cliente del dominio (Win10, Fedora)" `
        -Protected   $false
    if ($equiposOU -ne $false) {
        Write-Log SUCCESS "OU Equipos disponible: $equiposOU"
        msg_success "OU 'Equipos' lista para los clientes del dominio."
    }

    # ── Share de red Perfiles$ ────────────────────────────────────────────────
    # Permite que los clientes accedan a sus carpetas home via \\SVR\Perfiles$\usuario
    # Necesario para probar cuotas FSRM desde el cliente Windows.
    $profilesBase = "$env:SystemDrive\Perfiles"
    if (-not (Test-Path $profilesBase)) {
        New-Item -ItemType Directory -Path $profilesBase -Force | Out-Null
    }
    $existingShare = Get-SmbShare -Name "Perfiles`$" -ErrorAction SilentlyContinue
    if ($null -eq $existingShare) {
        try {
            New-SmbShare -Name "Perfiles`$" -Path $profilesBase `
                -FullAccess  "Administradores" `
                -ChangeAccess "Usuarios del dominio" `
                -ErrorAction Stop | Out-Null
            Write-Log SUCCESS "Share Perfiles`$ creado en $profilesBase"
            msg_success "Share de red '\\$env:COMPUTERNAME\Perfiles`$' creado."
        } catch {
            # Fallback: crear sin permisos especificos y asignar Everyone
            try {
                New-SmbShare -Name "Perfiles`$" -Path $profilesBase -ErrorAction Stop | Out-Null
                Grant-SmbShareAccess -Name "Perfiles`$" -AccountName "Everyone" `
                    -AccessRight Change -Force -ErrorAction SilentlyContinue | Out-Null
                Write-Log SUCCESS "Share Perfiles`$ creado (acceso Everyone - fallback)"
            } catch {
                Write-Log WARN "No se pudo crear share Perfiles`$: $_"
            }
        }
    }

    # ── WinRM TrustedHosts para PSRemoting desde clientes ────────────────────
    # Necesario para que el cliente Windows pueda llamar Invoke-Command al
    # servidor y mover automaticamente su cuenta a OU=Equipos.
    try {
        Enable-PSRemoting -Force -ErrorAction SilentlyContinue | Out-Null
        $serverIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                     Where-Object { $_.IPAddress -notlike '127.*' -and
                                    $_.IPAddress -notlike '169.254.*' } |
                     Select-Object -First 1).IPAddress
        $subnet = if ($serverIP) {
            (($serverIP -split '\.')[0..2] -join '.') + '.*'
        } else { '192.168.*.*' }
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $subnet -Force -ErrorAction Stop
        Write-Log SUCCESS "WinRM TrustedHosts configurado: $subnet"
    } catch {
        Write-Log WARN "No se pudo configurar WinRM TrustedHosts: $_"
    }

    # ── Registro DNS para clientes Linux ────────────────────────────────────
    # Sin registro DNS del cliente Linux, sssd queda en Offline con error
    # "Server not found in Kerberos database". Se informa al administrador
    # para que lo complete cuando conozca la IP del cliente Linux.
    Write-Host ""
    msg_info "RECORDATORIO: registra el cliente Linux en el DNS del DC."
    msg_info "Cuando conozcas la IP del cliente Linux ejecuta:"
    msg_info "  Add-DnsServerResourceRecordA -ZoneName '$script:AD_DOMAIN' \\"
    msg_info "    -Name 'LNX-CLIENT01' -IPv4Address '<IP_CLIENTE>' -TimeToLive '01:00:00'"

    # ── Estructura RBAC para Practica 9 ──────────────────────────────────────
    # Crea OU=Admins y grupos de rol si no existen. Es idempotente.
    Write-Host ""
    msg_info "Creando estructura de administracion delegada (RBAC - Practica 9)..."
    Initialize-RBACStructure | Out-Null

    return $true
}


# -----------------------------------------------------------------------------
# Initialize-RBACStructure
# Crea la OU=Admins y los 5 grupos necesarios para el modulo RBAC (Practica 9).
# Se llama al final de Invoke-OUSetup para que el modulo ac_rbac.ps1 encuentre
# su estructura ya lista sin pasos manuales adicionales.
# Idempotente: si la OU o los grupos ya existen los omite sin error.
#
# Devuelve: $true si todo quedo creado | $false si algo critico fallo
# -----------------------------------------------------------------------------
function Initialize-RBACStructure {
    if (-not $script:AD_DOMAIN_DN) {
        Write-Log ERROR "Initialize-RBACStructure: no hay conexion al dominio."
        return $false
    }

    Write-Log INFO "Verificando estructura RBAC (OU=Admins + grupos de rol)..."

    # ── OU=Admins ─────────────────────────────────────────────────────────────
    $adminOUDN = "OU=Admins,$script:AD_DOMAIN_DN"
    $ouResult = New-ADOU -Name "Admins" -Description "Administradores delegados del dominio" -Protected $true
    if ($ouResult -eq $false) {
        Write-Log ERROR "No se pudo crear OU=Admins."
        return $false
    }
    Write-Log SUCCESS "OU=Admins disponible: $adminOUDN"

    # ── GRP_AdminDelegados ────────────────────────────────────────────────────
    $grpDel = New-ADSecurityGroup `
        -Name        "GRP_AdminDelegados" `
        -OuDN        $adminOUDN `
        -Description "Grupo padre de todos los administradores delegados" `
        -Scope       "Global"
    if ($grpDel -eq $false) {
        Write-Log WARN "No se pudo crear GRP_AdminDelegados (puede ya existir)."
    }

    # ── Grupos de rol ─────────────────────────────────────────────────────────
    $roleGroups = @(
        @{ Name = "GRP_Role_IAMOperator";     Desc = "Rol: gestion de identidad y acceso (Cuates/NoCuates)" }
        @{ Name = "GRP_Role_StorageOperator"; Desc = "Rol: gestion de cuotas y file screening FSRM"        }
        @{ Name = "GRP_Role_GPOCompliance";   Desc = "Rol: cumplimiento GPO y FGPP"                        }
        @{ Name = "GRP_Role_SecurityAuditor"; Desc = "Rol: auditor de seguridad solo lectura"               }
    )

    $allOK = $true
    foreach ($rg in $roleGroups) {
        $result = New-ADSecurityGroup `
            -Name        $rg.Name `
            -OuDN        $adminOUDN `
            -Description $rg.Desc `
            -Scope       "Global"
        if ($result -eq $false) {
            Write-Log WARN "No se pudo crear $($rg.Name) (puede ya existir)."
        } else {
            Write-Log SUCCESS "Grupo creado: $($rg.Name)"
        }
    }

    msg_success "Estructura RBAC lista: OU=Admins + GRP_AdminDelegados + 4 grupos de rol."
    return $true
}

# -----------------------------------------------------------------------------
# Get-OUSelection
# Muestra las OUs disponibles (del dominio o las creadas en sesion)
# y devuelve la seleccion del usuario.
#
# Parametros:
#   -Prompt     Texto de la pregunta
#   -MultiSelect Si $true permite seleccion multiple
#
# Devuelve: PSCustomObject {Index, Value=DN} | array | $false
# -----------------------------------------------------------------------------
function Get-OUSelection {
    param(
        [string] $Prompt      = "Selecciona la OU destino",
        [bool]   $MultiSelect = $false
    )

    # Obtener OUs del dominio
    $allOUs = @()
    try {
        $allOUs = Get-ADOrganizationalUnit -Filter * -SearchBase $script:AD_DOMAIN_DN `
                  -Properties Name, DistinguishedName -ErrorAction Stop |
                  Select-Object Name, DistinguishedName |
                  Sort-Object Name
    } catch {
        Write-Log WARN "No se pudieron listar las OUs: $_"
        # Fallback a las creadas en sesion
        $allOUs = $script:AD_OUS | ForEach-Object {
            [PSCustomObject]@{ Name = $_.Name; DistinguishedName = $_.DN }
        }
    }

    if ($allOUs.Count -eq 0) {
        Write-Log ERROR "No hay OUs disponibles. Crea al menos una OU primero."
        return $false
    }

    $options = $allOUs | ForEach-Object { "$($_.Name)  [$($_.DistinguishedName)]" }

    if ($MultiSelect) {
        $sel = Read-MultiSelect -Prompt $Prompt -Options $options
        if ($sel -eq $false) { return $false }
        return $sel | ForEach-Object {
            [PSCustomObject]@{ Index = $_.Index; Value = $allOUs[$_.Index].DistinguishedName; Name = $allOUs[$_.Index].Name }
        }
    } else {
        $sel = Read-Selection -Prompt $Prompt -Options $options -AllowBack $true
        if ($null -eq $sel -or $sel -eq $false) { return $sel }
        return [PSCustomObject]@{
            Index = $sel.Index
            Value = $allOUs[$sel.Index].DistinguishedName
            Name  = $allOUs[$sel.Index].Name
        }
    }
}

# -----------------------------------------------------------------------------
# New-ADDomainUser
# Crea un usuario en AD con todos los atributos configurables.
# Funcion base compartida por alta por CSV y alta manual.
#
# Parametros: hashtable $UserData con las siguientes claves:
#   FirstName       string  (requerido)
#   LastName        string  (requerido)
#   SamAccountName  string  (requerido) - login name
#   Password        SecureString (requerido)
#   OuDN            string  (requerido) - DN de la OU destino
#   Group           string  (opcional) - nombre del grupo al que se agrega
#   Email           string  (opcional)
#   Description     string  (opcional)
#   Office          string  (opcional)
#   Phone           string  (opcional)
#   Enabled         bool    (default: $true)
#   MustChangePass  bool    (default: $true)
#
# Devuelve: SamAccountName si se creo correctamente | $false si fallo
# -----------------------------------------------------------------------------
function New-ADDomainUser {
    param(
        [Parameter(Mandatory)] [hashtable] $UserData
    )

    # Validar claves requeridas
    foreach ($key in @('FirstName','LastName','SamAccountName','Password','OuDN')) {
        if (-not $UserData.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($UserData[$key] -as [string])) {
            Write-Log ERROR "Campo requerido faltante en UserData: $key"
            return $false
        }
    }

    $sam    = $UserData['SamAccountName']
    $ouDN   = $UserData['OuDN']

    # Verificar si el usuario ya existe
    try {
        Get-ADUser -Identity $sam -ErrorAction Stop | Out-Null
        Write-Log WARN "El usuario '$sam' ya existe en AD. Se omite la creacion."
        return $sam
    } catch {}

    # Construir parametros del cmdlet
    $upn     = "$sam@$script:AD_DOMAIN"
    $display = "$($UserData['FirstName']) $($UserData['LastName'])"

    $params = @{
        SamAccountName        = $sam
        UserPrincipalName     = $upn
        GivenName             = $UserData['FirstName']
        Surname               = $UserData['LastName']
        DisplayName           = $display
        Name                  = $display
        Path                  = $ouDN
        AccountPassword       = $UserData['Password']
        Enabled               = if ($UserData.ContainsKey('Enabled')) { $UserData['Enabled'] } else { $true }
        ChangePasswordAtLogon = if ($UserData.ContainsKey('MustChangePass')) { $UserData['MustChangePass'] } else { $true }
        ErrorAction           = 'Stop'
    }

    # Atributos opcionales
    if ($UserData['Email'])       { $params['EmailAddress']  = $UserData['Email']       }
    if ($UserData['Description']) { $params['Description']   = $UserData['Description'] }
    if ($UserData['Office'])      { $params['Office']        = $UserData['Office']       }
    if ($UserData['Phone'])       { $params['OfficePhone']   = $UserData['Phone']        }

    # Crear usuario
    try {
        Invoke-Logged "Crear usuario AD: $sam ($display)" {
            New-ADUser @params
        } | Out-Null
    } catch {
        Write-Log ERROR "No se pudo crear el usuario '$sam': $_"
        return $false
    }

    Write-Log SUCCESS "Usuario creado: $sam  |  OU: $ouDN"

    # Agregar al grupo si se especifico
    if ($UserData['Group']) {
        $added = Add-UserToGroup -SamAccountName $sam -GroupName $UserData['Group']
        if (-not $added) {
            Write-Log WARN "Usuario '$sam' creado pero no agregado al grupo '$($UserData['Group'])'."
        }
    }

    return $sam
}

# -----------------------------------------------------------------------------
# Add-UserToGroup
# Agrega un usuario a un grupo AD.
#
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Add-UserToGroup {
    param(
        [Parameter(Mandatory)] [string] $SamAccountName,
        [Parameter(Mandatory)] [string] $GroupName
    )

    try {
        Add-ADGroupMember -Identity $GroupName -Members $SamAccountName -ErrorAction Stop
        Write-Log INFO "Usuario '$SamAccountName' agregado al grupo '$GroupName'."
        return $true
    } catch {
        Write-Log ERROR "No se pudo agregar '$SamAccountName' al grupo '$GroupName': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Invoke-ManualUserCreation  (flujo ABC)
# Solicita los datos de un usuario de forma interactiva campo por campo.
# Reutiliza New-ADDomainUser como pipeline de creacion.
#
# Devuelve: SamAccountName creado | $false
# -----------------------------------------------------------------------------
function Invoke-ManualUserCreation {
    Write-LogSection "Alta Manual de Usuario (ABC)"

    if (-not $script:AD_DOMAIN_DN) {
        Write-Log ERROR "No hay conexion al dominio."
        return $false
    }

    # ── Nombre y apellido ──
    $firstName = Read-InputLoop `
        -Prompt "Nombre(s)" `
        -Validator { param($v) $v -match '^[a-zA-ZáéíóúÁÉÍÓÚñÑüÜ ]{2,50}$' } `
        -ErrorMsg "Solo letras y espacios, 2-50 caracteres."
    if ($firstName -eq $false) { return $false }

    $lastName = Read-InputLoop `
        -Prompt "Apellido(s)" `
        -Validator { param($v) $v -match '^[a-zA-ZáéíóúÁÉÍÓÚñÑüÜ ]{2,50}$' } `
        -ErrorMsg "Solo letras y espacios, 2-50 caracteres."
    if ($lastName -eq $false) { return $false }

    # ── SamAccountName ──
    $suggestedSam = ($firstName.Split(' ')[0] + '.' + $lastName.Split(' ')[0]).ToLower() `
                    -replace '[^a-z0-9\.]', ''
    $suggestedSam = $suggestedSam.Substring(0, [Math]::Min(20, $suggestedSam.Length))

    $sam = Read-InputLoop `
        -Prompt "Nombre de inicio de sesion (Enter para '$suggestedSam')" `
        -Validator { param($v) $v -match '^[a-zA-Z0-9._\-]{1,20}$' } `
        -ErrorMsg "Solo letras, numeros, puntos, guiones. Max 20 chars." `
        -AllowEmpty $true
    if ($null -eq $sam) { $sam = $suggestedSam }
    if ($sam -eq $false) { return $false }

    # ── OU destino ──
    $ouSel = Get-OUSelection -Prompt "OU destino para el usuario '$sam'"
    if ($ouSel -eq $false -or $null -eq $ouSel) {
        Write-Log ERROR "No se selecciono una OU. Alta cancelada."
        return $false
    }

    # ── Grupo ──
    $addToGroup = Read-Confirm -Prompt "Agregar '$sam' a un grupo de seguridad" -Default 'S'
    $groupName  = $null
    if ($addToGroup) {
        try {
            $groups  = Get-ADGroup -Filter * -SearchBase $script:AD_DOMAIN_DN `
                       -ErrorAction Stop | Sort-Object Name |
                       Select-Object -ExpandProperty Name
            if ($groups.Count -gt 0) {
                $grpSel = Read-Selection -Prompt "Selecciona el grupo" -Options $groups -AllowBack $true
                if ($grpSel -and $grpSel -ne $false) { $groupName = $grpSel.Value }
            } else {
                Write-Log WARN "No hay grupos disponibles en el dominio."
            }
        } catch {
            Write-Log WARN "No se pudieron listar los grupos: $_"
        }
    }

    # ── Contrasena ──
    $password = Read-SecureInput `
        -Prompt "Contrasena inicial" `
        -Confirm $true `
        -MinLength 8
    if ($password -eq $false) { return $false }

    # ── Opciones de cuenta ──
    $enabled       = Read-Confirm -Prompt "Crear cuenta habilitada"                    -Default 'S'
    $mustChange    = Read-Confirm -Prompt "Forzar cambio de contrasena en primer logon" -Default 'S'

    # ── Atributos opcionales ──
    msg_info "Atributos adicionales (opcionales - Enter para omitir)"

    $email = Read-InputLoop `
        -Prompt "Correo electronico" `
        -Validator { param($v) $v -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' } `
        -ErrorMsg "Formato de email invalido." `
        -AllowEmpty $true
    if ($email -eq $false) { $email = $null }

    $phone = Read-InputLoop `
        -Prompt "Telefono de oficina" `
        -Validator { param($v) $v -match '^[\d\+\-\(\) ]{4,20}$' } `
        -ErrorMsg "Formato invalido. Ejemplo: +52 667 123 4567" `
        -AllowEmpty $true
    if ($phone -eq $false) { $phone = $null }

    $office = Read-InputLoop `
        -Prompt "Oficina" `
        -Validator { $true } `
        -AllowEmpty $true
    if ($office -eq $false) { $office = $null }

    $desc = Read-InputLoop `
        -Prompt "Descripcion" `
        -Validator { $true } `
        -AllowEmpty $true
    if ($desc -eq $false) { $desc = $null }

    # ── Crear usuario ──
    $userData = @{
        FirstName      = $firstName
        LastName       = $lastName
        SamAccountName = $sam
        Password       = $password
        OuDN           = $ouSel.Value
        Group          = $groupName
        Email          = $email
        Phone          = $phone
        Office         = $office
        Description    = $desc
        Enabled        = $enabled
        MustChangePass = $mustChange
    }

    return New-ADDomainUser -UserData $userData
}

# -----------------------------------------------------------------------------
# Get-ADDomainSummary
# Muestra un resumen del estado actual del dominio: OUs, grupos y usuarios.
# -----------------------------------------------------------------------------
function Get-ADDomainSummary {
    Write-LogSection "Resumen del Dominio: $script:AD_DOMAIN"

    if (-not $script:AD_DOMAIN_DN) {
        Write-Log WARN "No hay conexion activa al dominio."
        return
    }

    try {
        $ouCount   = @(Get-ADOrganizationalUnit -Filter * -SearchBase $script:AD_DOMAIN_DN -ErrorAction Stop).Count
        $grpCount  = @(Get-ADGroup  -Filter * -SearchBase $script:AD_DOMAIN_DN -ErrorAction Stop).Count
        $userCount = @(Get-ADUser   -Filter * -SearchBase $script:AD_DOMAIN_DN -ErrorAction Stop).Count

        msg_info "Dominio      : $script:AD_DOMAIN  ($script:AD_NETBIOS)"
        msg_info "DN Base      : $script:AD_DOMAIN_DN"
        msg_info "OUs totales  : $ouCount"
        msg_info "Grupos       : $grpCount"
        msg_info "Usuarios     : $userCount"
    } catch {
        Write-Log WARN "No se pudo obtener el resumen del dominio: $_"
    }

    # Listar OUs con conteo de usuarios
    Write-Host ""
    msg_info "Usuarios por OU:"
    try {
        Get-ADOrganizationalUnit -Filter * -SearchBase $script:AD_DOMAIN_DN -ErrorAction Stop |
        Sort-Object Name | ForEach-Object {
            $ou = $_
            try {
                $count = @(Get-ADUser -Filter * -SearchBase $ou.DistinguishedName `
                          -SearchScope OneLevel -ErrorAction Stop).Count
                msg_info "  $($ou.Name.PadRight(30)) $count usuario(s)"
            } catch {
                msg_info "  $($ou.Name.PadRight(30)) (error al contar)"
            }
        }
    } catch {
        Write-Log WARN "No se pudo listar OUs: $_"
    }
}