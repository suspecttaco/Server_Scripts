# =============================================================================
# ac_lib/ac_applocker.ps1 — Gestion de reglas AppLocker por grupo
# Uso: . .\ac_lib\ac_applocker.ps1
# Requiere: lib/ui.ps1, lib/input.ps1, ac_lib/ac_log.ps1, ac_lib/ac_ad.ps1
# =============================================================================

#Requires -Module ActiveDirectory
#Requires -Module GroupPolicy

# -----------------------------------------------------------------------------
# NOTAS TECNICAS — AppLocker
# -----------------------------------------------------------------------------
# AppLocker opera sobre 5 colecciones de reglas:
#   Exe      — Archivos ejecutables (.exe, .com)
#   Script   — Scripts (.ps1, .bat, .cmd, .vbs, .js)
#   Msi      — Instaladores (.msi, .msp, .mst)
#   Dll      — Librerias (.dll, .ocx) — IMPACTO EN RENDIMIENTO
#   Appx     — Aplicaciones empaquetadas (Windows Store)
#
# Tipos de regla:
#   Publisher — Basada en firma digital del ejecutable
#   Path      — Basada en ruta del archivo o directorio
#   Hash      — Basada en SHA256 del binario (resistente a renombrado/movimiento)
#
# El servicio Application Identity (AppIdSvc) DEBE estar corriendo.
# Sin el, AppLocker no aplica ninguna regla.
#
# La politica se almacena en GPO bajo:
#   Computer Configuration\Windows Settings\Security Settings\Application Control Policies
# -----------------------------------------------------------------------------

# Colecciones de reglas AppLocker
$script:AL_COLLECTIONS = @('Exe','Script','Msi','Dll','Appx')

# Modo de enforcement por coleccion
$script:AL_ENFORCE_MODES = @{
    'AuditOnly' = 'AuditOnly'   # Solo registra, no bloquea
    'Enabled'   = 'Enabled'     # Aplica y bloquea
    'NotConfigured' = 'NotConfigured'
}

# -----------------------------------------------------------------------------
# Test-AppLockerService
# Verifica que el servicio Application Identity este corriendo.
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Test-AppLockerService {
    $svc = Get-Service -Name 'AppIdSvc' -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Log ERROR "El servicio Application Identity (AppIdSvc) no existe en este sistema."
        return $false
    }
    return ($svc.Status -eq 'Running')
}

# -----------------------------------------------------------------------------
# Enable-AppLockerService
# Habilita e inicia el servicio Application Identity (AppIdSvc).
#
# NOTA: En un Domain Controller, Set-Service falla con "Acceso denegado"
# por restricciones del DC sobre servicios del sistema. Se usa sc.exe que
# accede directamente al SCM sin pasar por la capa de PowerShell.
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Enable-AppLockerService {
    Write-LogSection "Servicio Application Identity (AppIdSvc)"

    $svc = Get-Service -Name 'AppIdSvc' -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Log ERROR "El servicio AppIdSvc no existe. Verifica que AppLocker este disponible."
        return $false
    }

    if ($svc.Status -eq 'Running') {
        Write-Log INFO "El servicio AppIdSvc ya esta corriendo."
        return $true
    }

    $enable = Read-Confirm `
        -Prompt "El servicio Application Identity no esta activo. Habilitarlo ahora" `
        -Default 'S'
    if (-not $enable) {
        Write-Log WARN "AppIdSvc no habilitado. AppLocker no aplicara las reglas."
        return $false
    }

    try {
        # sc.exe en lugar de Set-Service — evita "Acceso denegado" en DC
        $cfgResult = sc.exe config AppIDSvc start= auto 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log WARN "sc.exe config retorno: $cfgResult"
        } else {
            Write-Log SUCCESS "AppIdSvc configurado para arranque automatico (sc.exe)."
        }

        $startResult = sc.exe start AppIDSvc 2>&1
        Start-Sleep -Seconds 3

        $svc = Get-Service -Name 'AppIdSvc' -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            Write-Log SUCCESS "Servicio AppIdSvc iniciado correctamente."
        } else {
            Write-Log WARN "AppIdSvc estado tras inicio: $($svc.Status)"
        }
        return $true
    } catch {
        Write-Log ERROR "No se pudo iniciar AppIdSvc: $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Get-NotepadPath
# Localiza notepad.exe verificando que no sea un stub (< 10 KB).
# En versiones modernas de Windows puede existir como stub que redirige
# a la version de la Store. El amigo descubrio que el stub tiene < 10 KB.
# Si no encuentra el ejecutable real, intenta instalarlo como caracteristica.
# Devuelve: ruta string | $null
# -----------------------------------------------------------------------------
function Get-NotepadPath {
    $candidates = @(
        "$env:SystemRoot\System32\notepad.exe",
        "$env:SystemRoot\SysWOW64\notepad.exe",
        "$env:SystemRoot\notepad.exe"
    )

    foreach ($path in $candidates) {
        if (Test-Path $path -PathType Leaf) {
            $size = (Get-Item $path).Length
            if ($size -gt 10240) {
                Write-Log INFO "notepad.exe encontrado: $path ($([Math]::Round($size/1KB,1)) KB)"
                return $path
            }
            Write-Log WARN "notepad.exe en $path parece stub ($size bytes). Buscando alternativa..."
        }
    }

    # Intentar instalar Notepad como caracteristica opcional
    Write-Log WARN "notepad.exe real no encontrado. Intentando instalar como caracteristica..."
    try {
        Add-WindowsCapability -Online -Name "Microsoft.Windows.Notepad~~~~0.0.1.0" `
            -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 5
        foreach ($path in $candidates) {
            if (Test-Path $path -PathType Leaf) {
                $size = (Get-Item $path).Length
                if ($size -gt 10240) {
                    Write-Log SUCCESS "notepad.exe instalado y encontrado: $path"
                    return $path
                }
            }
        }
    } catch {
        Write-Log WARN "No se pudo instalar Notepad como caracteristica: $_"
    }

    Write-Log ERROR "No se pudo localizar notepad.exe valido."
    return $null
}

# -----------------------------------------------------------------------------
# Write-AppLockerXmlToSysvol
# Escribe el XML de AppLocker directamente en SYSVOL e incrementa GPT.INI.
#
# CRITICO: Set-AppLockerPolicy -Ldap en Server 2022 NO escribe en SYSVOL.
# Sin el XML en SYSVOL y sin incrementar la version en GPT.INI, el cliente
# nunca descarga las reglas aunque se ejecute gpupdate /force.
#
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Write-AppLockerXmlToSysvol {
    param(
        [Parameter(Mandatory)] [string] $GpoId,
        [Parameter(Mandatory)] [string] $XmlContent,
        [Parameter(Mandatory)] [string] $DomainName
    )

    $sysvolBase = "\\$DomainName\SYSVOL\$DomainName\Policies\{$GpoId}\Machine\Microsoft\Windows NT\AppLocker"

    try {
        if (-not (Test-Path $sysvolBase)) {
            New-Item -Path $sysvolBase -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Log INFO "Directorio AppLocker creado en SYSVOL."
        }

        $xmlPath = Join-Path $sysvolBase "Exe.xml"
        $XmlContent | Out-File -FilePath $xmlPath -Encoding UTF8 -Force -ErrorAction Stop
        Write-Log SUCCESS "XML AppLocker escrito en SYSVOL (Machine): $xmlPath"

        # Escribir tambien en la ruta User — AppLocker con ComputerSettingsDisabled
        # busca el XML en ambas ubicaciones segun el build del cliente.
        $sysvolUser = "\\$DomainName\SYSVOL\$DomainName\Policies\{$GpoId}\User\Microsoft\Windows NT\AppLocker"
        if (-not (Test-Path $sysvolUser)) {
            New-Item -Path $sysvolUser -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $xmlUserPath = Join-Path $sysvolUser "Exe.xml"
        $XmlContent | Out-File -FilePath $xmlUserPath -Encoding UTF8 -Force -ErrorAction SilentlyContinue
        Write-Log INFO "XML AppLocker escrito en SYSVOL (User): $xmlUserPath"

        # Incrementar version en GPT.INI
        # CRITICO: GPT.INI Version es un DWORD de 32 bits:
        #   Bits 16-31 (parte alta) = version de configuracion de USUARIO
        #   Bits  0-15 (parte baja) = version de configuracion de EQUIPO
        # Como la GPO es ComputerSettingsDisabled (solo usuario), incrementamos
        # los bits altos (0x00010000 = 65536) Y los bajos para que el cliente
        # detecte cambio en ambos canales y descargue la politica.
        $gptPath = "\\$DomainName\SYSVOL\$DomainName\Policies\{$GpoId}\GPT.INI"
        if (Test-Path $gptPath) {
            $gptContent = Get-Content $gptPath -Raw
            if ($gptContent -match 'Version=(\d+)') {
                $currentVer = [int]$Matches[1]

                # Extraer partes alta (usuario) y baja (equipo)
                $userVer    = ($currentVer -shr 16) -band 0xFFFF
                $computerVer = $currentVer -band 0xFFFF

                # Incrementar ambas partes
                $userVer++
                $computerVer++

                $newVer     = ($userVer -shl 16) -bor $computerVer
                $gptContent = $gptContent -replace 'Version=\d+', "Version=$newVer"
                $gptContent | Out-File $gptPath -Encoding ASCII -Force
                Write-Log INFO "GPT.INI version: $currentVer -> $newVer (user=$userVer computer=$computerVer)"
            }
        } else {
            # GPT.INI no existe — crearlo
            $newVer = 65537  # 0x00010001: user=1, computer=1
            "[General]`r`nVersion=$newVer`r`ndisplayName=New Group Policy Object`r`n" |
                Out-File $gptPath -Encoding ASCII -Force
            Write-Log INFO "GPT.INI creado con Version=$newVer"
        }

        return $true
    } catch {
        Write-Log ERROR "No se pudo escribir XML en SYSVOL: $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# New-AppIDSvcGPO
# Crea una GPO vinculada al dominio que configura AppIDSvc como automatico
# en todos los clientes. Sin esto, los clientes Windows 10 arrancan con
# AppIDSvc detenido y las reglas de AppLocker no se aplican.
# -----------------------------------------------------------------------------
function New-AppIDSvcGPO {
    param([Parameter(Mandatory)] [string] $DomainName)

    $gpoName = "AppLocker-AppIDSvc"
    $existing = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log INFO "GPO '$gpoName' ya existe."
        return $true
    }

    try {
        New-GPO -Name $gpoName `
            -Comment "AC Manager: habilita AppIDSvc automatico en clientes" `
            -ErrorAction Stop | Out-Null

        Set-GPRegistryValue -Name $gpoName `
            -Key       "HKLM\SYSTEM\CurrentControlSet\Services\AppIDSvc" `
            -ValueName "Start" `
            -Type      DWord `
            -Value     2 `
            -ErrorAction Stop

        $domainDN = "DC=$($DomainName.Replace('.', ',DC='))"
        New-GPLink -Name $gpoName -Target $domainDN -LinkEnabled Yes -ErrorAction Stop | Out-Null

        Write-Log SUCCESS "GPO '$gpoName' creada y vinculada al dominio — AppIDSvc automatico en clientes."
        return $true
    } catch {
        Write-Log WARN "No se pudo crear GPO AppIDSvc: $_"
        return $false
    }
}

#
# Parametros:
#   -FilePath   Ruta completa al ejecutable
#
# Devuelve: PSCustomObject con .Hash .HashAlgorithm .SourceFileName .SourceFileLength
#           $false si fallo
# -----------------------------------------------------------------------------
function Get-AppLockerFileHash {
    param([Parameter(Mandatory)] [string] $FilePath)

    if (-not (Test-Path $FilePath -PathType Leaf)) {
        Write-Log ERROR "El archivo no existe: $FilePath"
        return $false
    }

    try {
        $fileInfo = Get-AppLockerFileInformation -Path $FilePath -ErrorAction Stop
        if ($null -eq $fileInfo -or $null -eq $fileInfo.Hash) {
            Write-Log ERROR "No se pudo obtener informacion AppLocker del archivo: $FilePath"
            return $false
        }
        Write-Log INFO "Hash obtenido para: $(Split-Path $FilePath -Leaf)"
        Write-Log INFO "  SHA256: $($fileInfo.Hash.HashDataString)"
        return $fileInfo.Hash
    } catch {
        Write-Log ERROR "Error al obtener hash de '$FilePath': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Get-AppLockerPublisherInfo
# Obtiene la informacion del publicador de un ejecutable firmado digitalmente.
#
# Devuelve: PSCustomObject con info del publisher | $false si no esta firmado
# -----------------------------------------------------------------------------
function Get-AppLockerPublisherInfo {
    param([Parameter(Mandatory)] [string] $FilePath)

    if (-not (Test-Path $FilePath -PathType Leaf)) {
        Write-Log ERROR "El archivo no existe: $FilePath"
        return $false
    }

    try {
        $fileInfo = Get-AppLockerFileInformation -Path $FilePath -ErrorAction Stop
        if ($null -eq $fileInfo -or $null -eq $fileInfo.Publisher) {
            Write-Log WARN "El archivo no tiene informacion de publicador (no firmado digitalmente)."
            return $false
        }
        Write-Log INFO "Publisher: $($fileInfo.Publisher.PublisherName)"
        Write-Log INFO "Producto : $($fileInfo.Publisher.ProductName)"
        Write-Log INFO "Archivo  : $($fileInfo.Publisher.BinaryName)"
        Write-Log INFO "Version  : $($fileInfo.Publisher.BinaryVersion)"
        return $fileInfo.Publisher
    } catch {
        Write-Log ERROR "Error al obtener publisher de '$FilePath': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# New-AppLockerHashRule
# Crea una regla AppLocker basada en Hash (SHA256).
# Resistente a renombrado y movimiento del archivo.
#
# Parametros:
#   -RuleName    Nombre descriptivo de la regla
#   -FilePath    Ruta al ejecutable (para calcular el hash)
#   -Action      'Allow' | 'Deny'
#   -UserOrGroup SID, nombre de grupo o 'Everyone'
#   -Description Descripcion opcional
#
# Devuelve: objeto de regla AppLocker | $false
# -----------------------------------------------------------------------------
function New-AppLockerHashRule {
    param(
        [Parameter(Mandatory)] [string] $RuleName,
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [ValidateSet('Allow','Deny')] [string] $Action,
        [string] $UserOrGroup = 'Everyone',
        [string] $Description = ''
    )

    $hashInfo = Get-AppLockerFileHash -FilePath $FilePath
    if ($hashInfo -eq $false) { return $false }

    try {
        $conditions = [Microsoft.Security.ApplicationId.PolicyManagement.PolicyModel.FileHashCondition]::new()
        $hashEntry  = [Microsoft.Security.ApplicationId.PolicyManagement.PolicyModel.FileHash]::new()
        $hashEntry.SourceFileName       = $hashInfo.SourceFileName
        $hashEntry.SourceFileLength     = $hashInfo.SourceFileLength
        $hashEntry.Data                 = $hashInfo.HashData
        $hashEntry.HashDataString       = $hashInfo.HashDataString
        $hashEntry.HashType             = [Microsoft.Security.ApplicationId.PolicyManagement.PolicyModel.AppLockerHashAlgorithm]::SHA256
        $conditions.FileHashes.Add($hashEntry)

        $rule             = [Microsoft.Security.ApplicationId.PolicyManagement.PolicyModel.FileHashRule]::new()
        $rule.Name        = $RuleName
        $rule.Description = $Description
        $rule.Action      = [Microsoft.Security.ApplicationId.PolicyManagement.PolicyModel.RuleAction]::$Action
        $rule.UserOrGroupSid = Resolve-AppLockerSID $UserOrGroup
        $rule.Conditions.Add($conditions)

        Write-Log SUCCESS "Regla Hash creada: '$RuleName' [$Action] para $UserOrGroup"
        return $rule
    } catch {
        # Fallback: usar New-AppLockerPolicy con XML
        Write-Log WARN "Metodo objeto fallido, usando metodo XML: $_"
        return New-AppLockerHashRuleXML `
            -RuleName    $RuleName `
            -FilePath    $FilePath `
            -Action      $Action `
            -UserOrGroup $UserOrGroup `
            -Description $Description
    }
}

# -----------------------------------------------------------------------------
# New-AppLockerHashRuleXML
# Metodo alternativo: genera regla Hash via XML directo.
# Se usa como fallback si el metodo de objetos no esta disponible.
# -----------------------------------------------------------------------------
function New-AppLockerHashRuleXML {
    param(
        [Parameter(Mandatory)] [string] $RuleName,
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string] $Action,
        [string] $UserOrGroup = 'Everyone',
        [string] $Description = ''
    )

    # Obtener hash via Get-FileHash
    try {
        $hashResult = Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop
        $hashValue  = $hashResult.Hash
        $fileItem   = Get-Item $FilePath -ErrorAction Stop
        $fileSize   = $fileItem.Length
        $fileName   = $fileItem.Name
    } catch {
        Write-Log ERROR "No se pudo calcular el hash de '$FilePath': $_"
        return $false
    }

    $sid = Resolve-AppLockerSID $UserOrGroup
    $id  = [guid]::NewGuid().ToString()

    $xml = @"
<FileHashRule Id="$id" Name="$RuleName" Description="$Description" UserOrGroupSid="$sid" Action="$Action">
  <Conditions>
    <FileHashCondition>
      <FileHash Type="SHA256" Data="0x$hashValue" SourceFileName="$fileName" SourceFileLength="$fileSize" />
    </FileHashCondition>
  </Conditions>
</FileHashRule>
"@

    Write-Log SUCCESS "Regla Hash (XML) creada: '$RuleName' [$Action] SHA256:$($hashValue.Substring(0,16))..."
    return [PSCustomObject]@{
        Type        = 'HashRule'
        Name        = $RuleName
        Action      = $Action
        UserOrGroup = $UserOrGroup
        XML         = $xml
        FilePath    = $FilePath
        Hash        = $hashValue
    }
}

# -----------------------------------------------------------------------------
# New-AppLockerPathRule
# Crea una regla AppLocker basada en ruta de archivo o directorio.
#
# Parametros:
#   -RuleName    Nombre de la regla
#   -Path        Ruta del archivo o directorio (acepta wildcards: *, ?)
#   -Action      'Allow' | 'Deny'
#   -UserOrGroup SID o nombre
#   -Description Descripcion opcional
#
# Devuelve: PSCustomObject con la definicion de la regla | $false
# -----------------------------------------------------------------------------
function New-AppLockerPathRule {
    param(
        [Parameter(Mandatory)] [string] $RuleName,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('Allow','Deny')] [string] $Action,
        [string] $UserOrGroup = 'Everyone',
        [string] $Description = ''
    )

    $sid = Resolve-AppLockerSID $UserOrGroup
    $id  = [guid]::NewGuid().ToString()

    $xml = @"
<FilePathRule Id="$id" Name="$RuleName" Description="$Description" UserOrGroupSid="$sid" Action="$Action">
  <Conditions>
    <FilePathCondition Path="$Path" />
  </Conditions>
</FilePathRule>
"@

    Write-Log SUCCESS "Regla Path creada: '$RuleName' [$Action] -> $Path para $UserOrGroup"
    return [PSCustomObject]@{
        Type        = 'PathRule'
        Name        = $RuleName
        Action      = $Action
        UserOrGroup = $UserOrGroup
        XML         = $xml
        Path        = $Path
    }
}

# -----------------------------------------------------------------------------
# New-AppLockerPublisherRule
# Crea una regla AppLocker basada en firma digital del publicador.
#
# Parametros:
#   -RuleName    Nombre de la regla
#   -FilePath    Ruta al ejecutable firmado
#   -Action      'Allow' | 'Deny'
#   -UserOrGroup SID o nombre
#   -Level       'Publisher'|'ProductName'|'BinaryName'|'BinaryVersion'
#                Cuanto especificar del publisher (mas especifico = mas restrictivo)
#   -Description Descripcion opcional
#
# Devuelve: PSCustomObject | $false
# -----------------------------------------------------------------------------
function New-AppLockerPublisherRule {
    param(
        [Parameter(Mandatory)] [string] $RuleName,
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [ValidateSet('Allow','Deny')] [string] $Action,
        [string] $UserOrGroup = 'Everyone',
        [ValidateSet('Publisher','ProductName','BinaryName','BinaryVersion')] [string] $Level = 'BinaryName',
        [string] $Description = ''
    )

    $pubInfo = Get-AppLockerPublisherInfo -FilePath $FilePath
    if ($pubInfo -eq $false) {
        Write-Log WARN "El archivo no esta firmado. No se puede crear regla Publisher."
        return $false
    }

    $sid = Resolve-AppLockerSID $UserOrGroup
    $id  = [guid]::NewGuid().ToString()

    # Determinar wildcards segun nivel de especificidad
    $productName  = if ($Level -eq 'Publisher') { '*' } else { $pubInfo.ProductName }
    $binaryName   = if ($Level -in 'Publisher','ProductName') { '*' } else { $pubInfo.BinaryName }
    $binaryVersion= if ($Level -eq 'BinaryVersion') { $pubInfo.BinaryVersion.ToString() } else { '*' }

    $xml = @"
<FilePublisherRule Id="$id" Name="$RuleName" Description="$Description" UserOrGroupSid="$sid" Action="$Action">
  <Conditions>
    <FilePublisherCondition PublisherName="$($pubInfo.PublisherName)" ProductName="$productName" BinaryName="$binaryName">
      <BinaryVersionRange LowSection="$binaryVersion" HighSection="*" />
    </FilePublisherCondition>
  </Conditions>
</FilePublisherRule>
"@

    Write-Log SUCCESS "Regla Publisher creada: '$RuleName' [$Action] $($pubInfo.PublisherName) para $UserOrGroup"
    return [PSCustomObject]@{
        Type        = 'PublisherRule'
        Name        = $RuleName
        Action      = $Action
        UserOrGroup = $UserOrGroup
        XML         = $xml
        Publisher   = $pubInfo.PublisherName
        Level       = $Level
    }
}

# -----------------------------------------------------------------------------
# Resolve-AppLockerSID
# Resuelve el SID de un grupo/usuario o devuelve el SID conocido de 'Everyone'.
# -----------------------------------------------------------------------------
function Resolve-AppLockerSID {
    param([string] $UserOrGroup)

    if ($UserOrGroup -eq 'Everyone' -or $UserOrGroup -eq 'Todos') {
        return 'S-1-1-0'
    }

    # Intentar como grupo AD
    try {
        $grp = Get-ADGroup -Identity $UserOrGroup -ErrorAction Stop
        return $grp.SID.Value
    } catch {}

    # Intentar como usuario AD
    try {
        $usr = Get-ADUser -Identity $UserOrGroup -ErrorAction Stop
        return $usr.SID.Value
    } catch {}

    # Intentar como cuenta local o builtin
    try {
        $account = New-Object System.Security.Principal.NTAccount($UserOrGroup)
        $sid = $account.Translate([System.Security.Principal.SecurityIdentifier])
        return $sid.Value
    } catch {}

    Write-Log WARN "No se pudo resolver el SID de '$UserOrGroup'. Usando S-1-1-0 (Everyone)."
    return 'S-1-1-0'
}

# -----------------------------------------------------------------------------
# Build-AppLockerPolicyXML
# Construye el XML completo de una politica AppLocker a partir de
# un array de reglas (objetos devueltos por New-AppLocker*Rule).
#
# Parametros:
#   -Rules         Array de PSCustomObject con campo .XML y .Type
#   -Collections   Colecciones a incluir con su modo de enforcement
#                  Hashtable: @{ 'Exe' = 'Enabled'; 'Script' = 'AuditOnly'; ... }
#
# Devuelve: string XML de la politica completa
# -----------------------------------------------------------------------------
function Build-AppLockerPolicyXML {
    param(
        [Parameter(Mandatory)] [object[]]  $Rules,
        [Parameter(Mandatory)] [hashtable] $Collections
    )

    $xmlParts = [System.Collections.Generic.List[string]]::new()
    $xmlParts.Add('<?xml version="1.0" encoding="utf-8"?>')
    $xmlParts.Add('<AppLockerPolicy Version="1">')

    foreach ($collection in $Collections.Keys) {
        $mode        = $Collections[$collection]
        $ruleType    = switch ($collection) {
            'Exe'   { 'FilePathRule|FileHashRule|FilePublisherRule' }
            'Script'{ 'FilePathRule|FileHashRule|FilePublisherRule' }
            'Msi'   { 'FilePathRule|FileHashRule|FilePublisherRule' }
            'Dll'   { 'FilePathRule|FileHashRule|FilePublisherRule' }
            'Appx'  { 'FilePublisherRule' }
            default { 'FilePathRule|FileHashRule|FilePublisherRule' }
        }

        # Filtrar reglas para esta coleccion
        # Por convencion, las reglas tienen campo Collection si se especifico
        $collRules = $Rules | Where-Object {
            (-not $_.PSObject.Properties['Collection']) -or
            ($_.Collection -eq $collection)
        }

        $xmlParts.Add("  <RuleCollection Type=`"$collection`" EnforcementMode=`"$mode`">")

        # Regla por defecto: permitir a Administrators ejecutar todo
        # (necesaria para que AppLocker no bloquee a los admins)
        $adminSid = 'S-1-5-32-544'  # Builtin\Administrators
        $defId    = [guid]::NewGuid().ToString()
        $xmlParts.Add(@"
    <FilePathRule Id="$defId" Name="(Default) Allow Administrators" Description="Allow administrators to run all applications" UserOrGroupSid="$adminSid" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
"@)

        foreach ($rule in $collRules) {
            if ($rule.XML) {
                # Indentar el XML de la regla
                $rule.XML -split "`n" | ForEach-Object {
                    $xmlParts.Add("    $_")
                }
            }
        }

        $xmlParts.Add("  </RuleCollection>")
    }

    $xmlParts.Add('</AppLockerPolicy>')
    return $xmlParts -join "`n"
}

# -----------------------------------------------------------------------------
# Apply-AppLockerPolicyGPO
# Aplica una politica AppLocker a una GPO, la escribe en SYSVOL,
# deshabilita la configuracion de equipo (ComputerSettingsDisabled) y
# vincula la GPO a la OU destino.
#
# CRITICO — tres pasos obligatorios:
# 1. ComputerSettingsDisabled: evita que la GPO aplique a equipos y bloquee
#    procesos del sistema (dwm.exe) causando pantalla negra.
# 2. Write-AppLockerXmlToSysvol: Set-AppLockerPolicy -Ldap no escribe en
#    SYSVOL en Server 2022. Sin esto el cliente nunca descarga las reglas.
# 3. Get-GPInheritance antes de New-GPLink: evita error "already linked".
#
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Apply-AppLockerPolicyGPO {
    param(
        [Parameter(Mandatory)] [string] $PolicyXML,
        [Parameter(Mandatory)] [string] $GPOName,
        [Parameter(Mandatory)] [string] $OuDN,
        [string] $SaveXMLPath = $null,
        [string] $DomainName  = $script:AD_DOMAIN
    )

    # Guardar XML en el perfil del usuario (permisos garantizados, sin riesgo de path TMP)
    $tempXML = "$env:USERPROFILE\AppLocker_Temp_$([System.IO.Path]::GetRandomFileName()).xml"
    try {
        Set-Content -Path $tempXML -Value $PolicyXML -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log ERROR "No se pudo guardar el XML temporal: $_"
        return $false
    }

    # Guardar copia de backup si se solicito
    if (-not [string]::IsNullOrWhiteSpace($SaveXMLPath)) {
        try {
            Copy-Item -Path $tempXML -Destination $SaveXMLPath -Force -ErrorAction Stop
            Write-Log SUCCESS "Copia de politica guardada: $SaveXMLPath"
        } catch {
            Write-Log WARN "No se pudo guardar la copia de backup: $_"
        }
    }

    # Crear o recuperar la GPO
    $gpo = $null
    try {
        $gpo = Get-GPO -Name $GPOName -ErrorAction Stop
        Write-Log INFO "GPO existente encontrada: $GPOName"
    } catch {
        try {
            $gpo = New-GPO -Name $GPOName -ErrorAction Stop
            Write-Log SUCCESS "GPO creada: $GPOName"
        } catch {
            Write-Log ERROR "No se pudo crear la GPO '$GPOName': $_"
            Remove-Item $tempXML -ErrorAction SilentlyContinue
            return $false
        }
    }

    # CRITICO: AllSettingsEnabled — AppLocker SOLO funciona via Computer Configuration.
    # ComputerSettingsDisabled hace que Get-AppLockerPolicy -Effective devuelva vacio
    # aunque la GPO llegue al cliente. La proteccion de dwm.exe se logra con
    # reglas Allow explicitas en el XML, no deshabilitando Computer Settings.
    try {
        $gpo.GpoStatus = "AllSettingsEnabled"
        Write-Log INFO "GPO '$GPOName' configurada como AllSettingsEnabled."
    } catch {
        Write-Log WARN "No se pudo configurar GpoStatus: $_"
    }

    $gpoId = $gpo.Id.ToString()

    # CRITICO (paso 1): escribir XML directamente en SYSVOL PRIMERO.
    # Set-AppLockerPolicy -Ldap en Server 2022 NO escribe en SYSVOL.
    # Sin el XML en SYSVOL Y sin incrementar GPT.INI el cliente nunca
    # descarga las reglas aunque gpupdate /force se ejecute.
    if (-not [string]::IsNullOrWhiteSpace($DomainName)) {
        $sysvolOk = Write-AppLockerXmlToSysvol `
            -GpoId      $gpoId `
            -XmlContent $PolicyXML `
            -DomainName $DomainName
        if (-not $sysvolOk) {
            Write-Log WARN "No se pudo escribir en SYSVOL. Las reglas pueden no propagarse a los clientes."
        }
    }

    # Aplicar via LDAP (complementario al SYSVOL — puede fallar silenciosamente en Server 2022)
    try {
        $ldapPath = "LDAP://$((Get-ADDomain -ErrorAction Stop).PDCEmulator)/$($gpo.Path)"
        Set-AppLockerPolicy `
            -XmlPolicy   $tempXML `
            -Ldap        $ldapPath `
            -ErrorAction SilentlyContinue
        Write-Log INFO "Politica aplicada via LDAP a GPO: $GPOName"
    } catch {
        Write-Log WARN "Set-AppLockerPolicy LDAP: $_ (SYSVOL directo es el metodo principal)"
    }

    # Forzar sincronizacion del numero de version en AD para que los clientes
    # detecten el cambio. Set-GPRegistryValue con un valor dummy actualiza el
    # atributo versionNumber en CN=<GUID>,CN=Policies,CN=System del dominio,
    # que es lo que el cliente compara con GPT.INI al decidir si descarga la GPO.
    try {
        Set-GPRegistryValue -Name $GPOName `
            -Key       "HKCU\Software\Policies\AppLocker" `
            -ValueName "_ACManagerTimestamp" `
            -Type      String `
            -Value     (Get-Date -Format 'yyyyMMddHHmmss') `
            -ErrorAction SilentlyContinue | Out-Null
        Write-Log INFO "Version AD sincronizada para GPO: $GPOName"
    } catch {
        Write-Log WARN "No se pudo sincronizar version AD: $_"
    }

    # Vincular GPO — verificar primero con Get-GPInheritance
    $alreadyLinked = $false
    try {
        $links = Get-GPInheritance -Target $OuDN -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty GpoLinks |
                 Where-Object { $_.DisplayName -eq $GPOName }
        $alreadyLinked = ($null -ne $links)
    } catch {}

    if ($alreadyLinked) {
        Write-Log INFO "La GPO '$GPOName' ya estaba vinculada a '$OuDN'. Re-habilitando vinculo..."
        try {
            Set-GPLink -Name $GPOName -Target $OuDN -LinkEnabled Yes -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    } else {
        try {
            New-GPLink -Name $GPOName -Target $OuDN -LinkEnabled Yes -ErrorAction Stop | Out-Null
            Write-Log SUCCESS "GPO '$GPOName' vinculada a: $OuDN"
        } catch {
            if ($_ -match 'already') {
                Write-Log WARN "La GPO '$GPOName' ya estaba vinculada (detectado en creacion)."
                try {
                    Set-GPLink -Name $GPOName -Target $OuDN -LinkEnabled Yes -ErrorAction SilentlyContinue | Out-Null
                } catch {}
            } else {
                Write-Log ERROR "No se pudo vincular la GPO '$GPOName' a '$OuDN': $_"
            }
        }
    }

    # Verificacion final: confirmar que el vinculo quedo activo
    try {
        $verifyLinks = Get-GPInheritance -Target $OuDN -ErrorAction SilentlyContinue |
                       Select-Object -ExpandProperty GpoLinks |
                       Where-Object { $_.DisplayName -eq $GPOName }
        if ($null -ne $verifyLinks) {
            Write-Log SUCCESS "Verificado: GPO '$GPOName' vinculada y activa en '$OuDN'."
        } else {
            Write-Log ERROR "ALERTA: GPO '$GPOName' NO aparece vinculada a '$OuDN' tras el proceso."
        }
    } catch {}

    Remove-Item $tempXML -ErrorAction SilentlyContinue
    return $true
}

# -----------------------------------------------------------------------------
# Invoke-AppLockerRuleWizard
# Flujo interactivo para crear UNA regla AppLocker.
# El usuario elige tipo (Hash/Path/Publisher), accion (Allow/Deny),
# ejecutable y grupo destino.
#
# Devuelve: PSCustomObject con la regla | $false
# -----------------------------------------------------------------------------
function Invoke-AppLockerRuleWizard {
    param(
        [string] $DefaultAction     = $null,   # Preseleccionar Allow o Deny
        [string] $DefaultRuleType   = $null,   # Preseleccionar Hash, Path o Publisher
        [string] $DefaultUserGroup  = $null,   # Preseleccionar grupo
        [string] $DefaultCollection = 'Exe'    # Coleccion por defecto
    )

    Write-Host ""
    msg_info "─── Asistente de Regla AppLocker ───"

    # ── Nombre de la regla ────────────────────────────────────────────────────
    $ruleName = Read-InputLoop `
        -Prompt    "Nombre descriptivo de la regla" `
        -Validator { param($v) $v.Length -ge 3 -and $v.Length -le 128 } `
        -ErrorMsg  "Entre 3 y 128 caracteres."
    if ($ruleName -eq $false) { return $false }

    # ── Accion ────────────────────────────────────────────────────────────────
    $actionOpts = @('Allow — Permitir ejecucion', 'Deny  — Bloquear ejecucion')
    $actionSel  = if ($DefaultAction -eq 'Allow') {
        [PSCustomObject]@{ Index = 0; Value = $actionOpts[0] }
    } elseif ($DefaultAction -eq 'Deny') {
        [PSCustomObject]@{ Index = 1; Value = $actionOpts[1] }
    } else {
        Read-Selection -Prompt "Accion de la regla" -Options $actionOpts
    }
    if ($actionSel -eq $false) { return $false }
    $action = if ($actionSel.Index -eq 0) { 'Allow' } else { 'Deny' }

    # ── Tipo de regla ─────────────────────────────────────────────────────────
    $typeOpts = @(
        "Hash      — SHA256 del binario (resistente a renombrado)",
        "Path      — Ruta del archivo o directorio",
        "Publisher — Firma digital del ejecutable"
    )

    if ($action -eq 'Deny') {
        msg_alert "NOTA: Para bloqueos se recomienda Hash — impide evasion por renombrado."
    }

    $typeIdx = switch ($DefaultRuleType) {
        'Hash'      { 0 }
        'Path'      { 1 }
        'Publisher' { 2 }
        default     { -1 }
    }

    $typeSel = if ($typeIdx -ge 0) {
        $confirm = Read-Confirm -Prompt "Usar tipo '$DefaultRuleType' para esta regla" -Default 'S'
        if ($confirm) {
            [PSCustomObject]@{ Index = $typeIdx; Value = $typeOpts[$typeIdx] }
        } else {
            Read-Selection -Prompt "Tipo de regla" -Options $typeOpts
        }
    } else {
        Read-Selection -Prompt "Tipo de regla" -Options $typeOpts
    }
    if ($typeSel -eq $false) { return $false }

    $ruleType = switch ($typeSel.Index) {
        0 { 'Hash'      }
        1 { 'Path'      }
        2 { 'Publisher' }
    }

    # ── Ejecutable o ruta ─────────────────────────────────────────────────────
    $targetPath = $null
    if ($ruleType -in 'Hash','Publisher') {
        $targetPath = Read-FilePath `
            -Prompt    "Ruta completa al ejecutable" `
            -MustExist $true `
            -Type      'File'
        if ($targetPath -eq $false) { return $false }
    } else {
        # Path rule: acepta rutas con wildcards
        $targetPath = Read-InputLoop `
            -Prompt    "Ruta o patron (ej: C:\Windows\notepad.exe o %WINDIR%\*)" `
            -Validator { param($v) $v.Length -ge 3 } `
            -ErrorMsg  "Ingresa una ruta valida."
        if ($targetPath -eq $false) { return $false }
    }

    # ── Grupo o usuario destino ───────────────────────────────────────────────
    $userGroup = $null
    if (-not [string]::IsNullOrWhiteSpace($DefaultUserGroup)) {
        $useDefault = Read-Confirm `
            -Prompt "Aplicar regla al grupo '$DefaultUserGroup'" `
            -Default 'S'
        $userGroup = if ($useDefault) { $DefaultUserGroup } else { $null }
    }

    if ([string]::IsNullOrWhiteSpace($userGroup)) {
        $groupOpts = @('Everyone (Todos los usuarios)')
        try {
            $adGroups = Get-ADGroup -Filter * -SearchBase $script:AD_DOMAIN_DN `
                        -ErrorAction Stop | Sort-Object Name |
                        Select-Object -ExpandProperty Name
            $groupOpts += $adGroups
        } catch {
            Write-Log WARN "No se pudieron listar grupos AD: $_"
        }

        $grpSel = Read-Selection `
            -Prompt  "Aplicar regla a" `
            -Options $groupOpts
        if ($grpSel -eq $false) { return $false }

        $userGroup = if ($grpSel.Index -eq 0) { 'Everyone' } else { $grpSel.Value }
    }

    # ── Coleccion ─────────────────────────────────────────────────────────────
    $collSel = Read-Selection `
        -Prompt  "Coleccion de reglas AppLocker" `
        -Options @(
            "Exe   — Ejecutables (.exe, .com)  [RECOMENDADO]",
            "Script — Scripts (.ps1, .bat, .cmd, .vbs)",
            "Msi   — Instaladores (.msi, .msp)",
            "Dll   — Librerias (.dll)  [IMPACTO EN RENDIMIENTO]",
            "Appx  — Apps de Windows Store"
        )
    if ($collSel -eq $false) { return $false }
    $collection = $script:AL_COLLECTIONS[$collSel.Index]

    if ($collection -eq 'Dll') {
        msg_alert "ADVERTENCIA: Las reglas DLL tienen un impacto significativo en el rendimiento."
        msg_alert "Se recomienda usar solo si es estrictamente necesario."
        $confirmDll = Read-Confirm -Prompt "Confirmar uso de coleccion DLL" -Default 'N'
        if (-not $confirmDll) { return $false }
    }

    # ── Descripcion ───────────────────────────────────────────────────────────
    $desc = Read-InputLoop `
        -Prompt    "Descripcion de la regla (opcional)" `
        -Validator { $true } `
        -AllowEmpty $true
    if ($null -eq $desc -or $desc -eq $false) { $desc = '' }

    # ── Crear la regla ────────────────────────────────────────────────────────
    $rule = switch ($ruleType) {
        'Hash' {
            New-AppLockerHashRuleXML `
                -RuleName    $ruleName `
                -FilePath    $targetPath `
                -Action      $action `
                -UserOrGroup $userGroup `
                -Description $desc
        }
        'Path' {
            New-AppLockerPathRule `
                -RuleName    $ruleName `
                -Path        $targetPath `
                -Action      $action `
                -UserOrGroup $userGroup `
                -Description $desc
        }
        'Publisher' {
            $levelSel = Read-Selection `
                -Prompt  "Nivel de especificidad del publisher" `
                -Options @(
                    "Publisher    — Solo el editor (mas permisivo)",
                    "ProductName  — Editor + producto",
                    "BinaryName   — Editor + producto + nombre del archivo",
                    "BinaryVersion — Hasta la version exacta (mas restrictivo)"
                )
            $level = switch ($levelSel.Index) {
                0 { 'Publisher'     }
                1 { 'ProductName'   }
                2 { 'BinaryName'    }
                3 { 'BinaryVersion' }
                default { 'BinaryName' }
            }
            New-AppLockerPublisherRule `
                -RuleName    $ruleName `
                -FilePath    $targetPath `
                -Action      $action `
                -UserOrGroup $userGroup `
                -Level       $level `
                -Description $desc
        }
    }

    if ($rule -eq $false) { return $false }

    # Agregar metadato de coleccion
    $rule | Add-Member -NotePropertyName 'Collection' -NotePropertyValue $collection -Force

    msg_success "Regla '$ruleName' creada: [$action] [$ruleType] [$collection] -> $userGroup"
    return $rule
}

# -----------------------------------------------------------------------------
# Remove-AppLockerGPOsForGroup
# Elimina TODAS las GPOs de AppLocker vinculadas a la OU de un grupo,
# desvinculandolas primero y luego borrandolas del dominio.
# Se llama al inicio de Invoke-AppLockerPractica para garantizar un estado
# limpio antes de crear las nuevas GPOs.
#
# Parametros:
#   -OuDN        DN de la OU (ej: OU=Cuates,DC=practica,DC=local)
#   -GPOPattern  Patron de nombre para filtrar (ej: 'AppLocker-Cuates')
#                Si se omite, elimina TODAS las GPOs vinculadas a la OU.
#
# Devuelve: numero de GPOs eliminadas
# -----------------------------------------------------------------------------
function Remove-AppLockerGPOsForGroup {
    param(
        [Parameter(Mandatory)] [string] $OuDN,
        [string] $GPOPattern = 'AppLocker'
    )

    [int]$removed = 0

    # Rastrear nombres ya eliminados para no intentar doble borrado
    $deletedNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    # ── Paso 1: GPOs vinculadas a la OU ──────────────────────────────────────
    $links = $null
    try {
        $inheritance = Get-GPInheritance -Target $OuDN -ErrorAction Stop
        $links = $inheritance.GpoLinks
    } catch {
        Write-Log WARN "No se pudo leer herencia de '$OuDN': $_"
        return [int]0
    }

    if ($null -ne $links -and $links.Count -gt 0) {
        foreach ($link in $links) {
            $gpoName = $link.DisplayName
            if ($GPOPattern -and $gpoName -notlike "*$GPOPattern*") { continue }

            # Desvincular primero
            try {
                Remove-GPLink -Name $gpoName -Target $OuDN -ErrorAction SilentlyContinue | Out-Null
                Write-Log INFO "GPO desvinculada de '$OuDN': $gpoName"
            } catch {
                Write-Log WARN "No se pudo desvincular '$gpoName': $_"
            }

            # Eliminar del dominio
            try {
                Remove-GPO -Name $gpoName -ErrorAction Stop | Out-Null
                Write-Log SUCCESS "GPO eliminada: $gpoName"
                $removed++
                [void]$deletedNames.Add($gpoName)
            } catch {
                Write-Log WARN "No se pudo eliminar la GPO '$gpoName': $_"
            }
        }
    } else {
        Write-Log INFO "No hay GPOs vinculadas a: $OuDN"
    }

    # ── Paso 2: GPOs huerfanas en el dominio (existen pero no estan vinculadas) ──
    try {
        $allGPOs = Get-GPO -All -ErrorAction SilentlyContinue
        if ($null -ne $allGPOs) {
            foreach ($g in $allGPOs) {
                $gName = $g.DisplayName
                if ($gName -notlike "*$GPOPattern*") { continue }
                if ($deletedNames.Contains($gName)) { continue }
                try {
                    Remove-GPO -Name $gName -ErrorAction Stop | Out-Null
                    Write-Log SUCCESS "GPO huerfana eliminada: $gName"
                    $removed++
                    [void]$deletedNames.Add($gName)
                } catch {
                    # Ya eliminada en el paso anterior o no existe — ignorar
                }
            }
        }
    } catch {}

    return [int]$removed
}

# -----------------------------------------------------------------------------
# New-AppLockerXmlCuates
# Genera el XML para GRP_Cuates: AuditOnly en Exe, todo permitido.
# AuditOnly = registra en el log pero NO bloquea nada.
# El grupo Cuates puede ejecutar notepad y cualquier otra aplicacion.
# -----------------------------------------------------------------------------
function New-AppLockerXmlCuates {
    param([Parameter(Mandatory)] [string] $DomainName)

    $sidCuates = $null
    try {
        $sidCuates = (Get-ADGroup 'GRP_Cuates' -ErrorAction Stop).SID.Value
    } catch {
        Write-Log WARN "No se pudo obtener SID de GRP_Cuates. Usando S-1-1-0 (Everyone)."
        $sidCuates = 'S-1-1-0'
    }

    return @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Appx" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Exe" EnforcementMode="AuditOnly">
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000001"
      Name="Permitir todo a SYSTEM"
      Description="SYSTEM debe poder ejecutar cualquier proceso del SO"
      UserOrGroupSid="S-1-5-18"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000002"
      Name="Permitir todo a Servicio de red"
      Description="NT AUTHORITY\NetworkService"
      UserOrGroupSid="S-1-5-20"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000003"
      Name="Permitir todo a Servicio local"
      Description="NT AUTHORITY\LocalService"
      UserOrGroupSid="S-1-5-19"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="fd686d83-a829-4351-8ff4-27c7de5755d2"
      Name="Permitir todo a Cuates"
      Description="Cuates pueden ejecutar cualquier aplicacion incluido notepad"
      UserOrGroupSid="S-1-1-0"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="MsiInstaller" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Script" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@
}

# -----------------------------------------------------------------------------
# New-AppLockerXmlNoCuates
# Genera el XML para GRP_NoCuates: bloquea notepad.exe por ruta (Exceptions)
# Y por hash (cubre renombrado del binario).
#
# CRITICO — GpoStatus debe ser AllSettingsEnabled (NO ComputerSettingsDisabled):
#   AppLocker SOLO funciona via Computer Configuration. Si se deshabilita
#   Computer Settings, Get-AppLockerPolicy -Effective devuelve vacio aunque
#   la GPO llegue al cliente (gpresult la muestra pero no se aplica).
#   La proteccion de dwm.exe se logra con reglas Allow explicitas para los
#   procesos criticos del sistema, no deshabilitando Computer Settings.
#
# ESTRATEGIA:
#   1. FilePathRule Allow con <Exceptions> de ruta — caso normal
#   2. FileHashRule Deny con hash dinamico — cubre renombrado/copia
#   3. Reglas Allow explicitas para procesos del sistema (dwm, winlogon, etc.)
#      para evitar pantalla negra con AllSettingsEnabled activo
# -----------------------------------------------------------------------------
function New-AppLockerXmlNoCuates {
    param(
        [Parameter(Mandatory)] [string] $DomainName,
        [string] $NotepadPath = $null
    )

    $sidNoCuates = $null
    try {
        $sidNoCuates = (Get-ADGroup 'GRP_NoCuates' -ErrorAction Stop).SID.Value
    } catch {
        Write-Log ERROR "No se pudo obtener SID de GRP_NoCuates. Abortando."
        return $null
    }

    Write-Log INFO "SID GRP_NoCuates: $sidNoCuates"

    # ── Calcular hash de notepad en tiempo de ejecucion ───────────────────────
    $hashRuleXml = ''
    if (-not [string]::IsNullOrWhiteSpace($NotepadPath) -and (Test-Path $NotepadPath -PathType Leaf)) {
        try {
            $hashObj    = Get-FileHash -Path $NotepadPath -Algorithm SHA256 -ErrorAction Stop
            $fileItem   = Get-Item $NotepadPath -ErrorAction Stop
            $hashData   = '0x' + $hashObj.Hash          # formato AppLocker: 0xABCD...
            $fileSize   = $fileItem.Length
            $fileName   = $fileItem.Name
            $hashId     = [guid]::NewGuid().ToString()

            Write-Log INFO "Hash notepad.exe: $($hashObj.Hash) ($fileSize bytes)"

            $hashRuleXml = @"
    <FileHashRule
      Id="$hashId"
      Name="Bloquear notepad por hash a NoCuates (cubre renombrado)"
      Description="Bloquea el binario de notepad.exe sin importar nombre o ruta"
      UserOrGroupSid="$sidNoCuates"
      Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256"
            Data="$hashData"
            SourceFileName="$fileName"
            SourceFileLength="$fileSize" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
"@
        } catch {
            Write-Log WARN "No se pudo calcular hash de notepad: $_. Se omite FileHashRule."
        }
    } else {
        Write-Log WARN "NotepadPath no disponible — FileHashRule Deny omitida."
    }

    return @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Appx" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000010"
      Name="Permitir todo a SYSTEM"
      Description="SYSTEM debe poder ejecutar cualquier proceso del SO sin restriccion"
      UserOrGroupSid="S-1-5-18"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000011"
      Name="Permitir todo a Servicio de red"
      Description="NT AUTHORITY\NetworkService necesario para servicios del sistema"
      UserOrGroupSid="S-1-5-20"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000012"
      Name="Permitir todo a Servicio local"
      Description="NT AUTHORITY\LocalService necesario para servicios del sistema"
      UserOrGroupSid="S-1-5-19"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
    <FilePublisherRule
      Id="a9e18c21-ff8f-43cf-b9fc-db40eed693ba"
      Name="Permitir Microsoft a Administradores"
      Description="Administradores pueden ejecutar todo"
      UserOrGroupSid="S-1-5-32-544"
      Action="Allow">
      <Conditions>
        <FilePublisherCondition
          PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US"
          ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000030"
      Name="Permitir System32 variable a NoCuates excepto notepad"
      Description="Cubre %WINDIR%\System32\* excluyendo notepad.exe"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\System32\*" />
      </Conditions>
      <Exceptions>
        <FilePathCondition Path="%WINDIR%\System32\notepad.exe" />
      </Exceptions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000031"
      Name="Permitir System32 ruta absoluta a NoCuates"
      Description="Cubre C:\Windows\System32\* - necesario para dwm.exe"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="C:\Windows\System32\*" />
      </Conditions>
      <Exceptions>
        <FilePathCondition Path="C:\Windows\System32\notepad.exe" />
      </Exceptions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000032"
      Name="Permitir Windows raiz a NoCuates excepto notepad"
      Description="Cubre %WINDIR%\* y C:\Windows\* excluyendo notepad"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\*" />
      </Conditions>
      <Exceptions>
        <FilePathCondition Path="%WINDIR%\notepad.exe" />
        <FilePathCondition Path="%WINDIR%\System32\notepad.exe" />
        <FilePathCondition Path="C:\Windows\notepad.exe" />
        <FilePathCondition Path="C:\Windows\System32\notepad.exe" />
      </Exceptions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000033"
      Name="Permitir Program Files a NoCuates"
      Description="Permite ejecutar desde Program Files"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES%\*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000034"
      Name="Permitir Program Files x86 a NoCuates"
      Description="Permite ejecutar desde Program Files x86"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES(X86)%\*" />
      </Conditions>
    </FilePathRule>
$hashRuleXml  </RuleCollection>
  <RuleCollection Type="MsiInstaller" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Script" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@
}

# -----------------------------------------------------------------------------
# Invoke-AppLockerSetup
# Flujo principal de configuracion de AppLocker para la practica.
# Ofrece dos modos:
#   A) Practica (recomendado): genera las dos GPOs correctas automaticamente
#   B) Personalizado: wizard regla por regla para configuraciones avanzadas
# -----------------------------------------------------------------------------
function Invoke-AppLockerSetup {
    Write-LogSection "Configuracion de AppLocker"

    # Verificar modulo GroupPolicy
    try { Import-Module GroupPolicy -ErrorAction Stop } catch {
        Write-Log ERROR "El modulo GroupPolicy no esta disponible."
        return $false
    }

    # AppIdSvc en el servidor (con sc.exe para evitar error en DC)
    if (-not (Test-AppLockerService)) {
        Enable-AppLockerService | Out-Null
    }

    # GPO para que los clientes arranquen con AppIDSvc automatico
    if ($script:AD_DOMAIN) {
        New-AppIDSvcGPO -DomainName $script:AD_DOMAIN | Out-Null
    }

    # Localizar notepad.exe
    $notepadPath = Get-NotepadPath
    if ($notepadPath) {
        msg_success "notepad.exe localizado: $notepadPath"
    }

    # Obtener SIDs para mostrar informacion al usuario
    $sidNoCuates = $null
    $sidCuates   = $null
    try {
        $grpNC = Get-ADGroup 'GRP_NoCuates' -EA SilentlyContinue
        $grpC  = Get-ADGroup 'GRP_Cuates'   -EA SilentlyContinue
        if ($grpNC) { $sidNoCuates = $grpNC.SID.Value }
        if ($grpC)  { $sidCuates   = $grpC.SID.Value  }
    } catch {}

    Write-Host ""
    if ($sidCuates)   { msg_info "SID GRP_Cuates   : $sidCuates" }
    if ($sidNoCuates) { msg_info "SID GRP_NoCuates : $sidNoCuates" }
    Write-Host ""

    # ── Modo de configuracion ─────────────────────────────────────────────────
    $modeSel = Read-Selection `
        -Prompt "Modo de configuracion" `
        -Options @(
            "Practica (recomendado) — genera las dos GPOs correctas automaticamente",
            "Personalizado — wizard regla por regla"
        )
    if ($modeSel -eq $false) { return $false }

    if ($modeSel.Index -eq 0) {
        return Invoke-AppLockerPractica
    } else {
        return Invoke-AppLockerPersonalizado
    }
}

# -----------------------------------------------------------------------------
# Invoke-AppLockerPractica
# Genera automaticamente las dos GPOs correctas para la practica:
#   GPO Cuates   -> OU=Cuates   -> AuditOnly, todo permitido
#   GPO NoCuates -> OU=NoCuates -> Enabled, notepad bloqueado por FilePathRule+Exceptions
# -----------------------------------------------------------------------------
function Invoke-AppLockerPractica {
    Write-LogSection "AppLocker — Modo Practica"

    if (-not $script:AD_DOMAIN -or -not $script:AD_DOMAIN_DN) {
        Write-Log ERROR "No hay conexion al dominio."
        return $false
    }

    # Nombres de GPO
    $gpoCuatesNombre   = Read-InputLoop `
        -Prompt    "Nombre de la GPO para Cuates (Enter para 'AppLocker-Cuates')" `
        -Validator { $true } -AllowEmpty $true
    if ($null -eq $gpoCuatesNombre -or $gpoCuatesNombre -eq $false -or $gpoCuatesNombre -eq '') {
        $gpoCuatesNombre = 'AppLocker-Cuates'
    }

    $gpoNoCuatesNombre = Read-InputLoop `
        -Prompt    "Nombre de la GPO para NoCuates (Enter para 'AppLocker-NoCuates')" `
        -Validator { $true } -AllowEmpty $true
    if ($null -eq $gpoNoCuatesNombre -or $gpoNoCuatesNombre -eq $false -or $gpoNoCuatesNombre -eq '') {
        $gpoNoCuatesNombre = 'AppLocker-NoCuates'
    }

    # Seleccion de OUs
    $ouCuates = Read-InputLoop `
        -Prompt    "DN de la OU de Cuates (Enter para 'OU=Cuates,$script:AD_DOMAIN_DN')" `
        -Validator { $true } -AllowEmpty $true
    if ($null -eq $ouCuates -or $ouCuates -eq $false -or $ouCuates -eq '') {
        $ouCuates = "OU=Cuates,$script:AD_DOMAIN_DN"
    }

    $ouNoCuates = Read-InputLoop `
        -Prompt    "DN de la OU de NoCuates (Enter para 'OU=NoCuates,$script:AD_DOMAIN_DN')" `
        -Validator { $true } -AllowEmpty $true
    if ($null -eq $ouNoCuates -or $ouNoCuates -eq $false -or $ouNoCuates -eq '') {
        $ouNoCuates = "OU=NoCuates,$script:AD_DOMAIN_DN"
    }

    # Ruta para guardar los XMLs
    $saveDir = "$env:USERPROFILE\Desktop"
    $saveCuates   = "$saveDir\AppLocker_Cuates_$(Get-Date -Format 'yyyyMMdd').xml"
    $saveNoCuates = "$saveDir\AppLocker_NoCuates_$(Get-Date -Format 'yyyyMMdd').xml"

    # Resumen
    Write-Host ""
    Write-LogSection "Resumen"
    msg_info "GPO Cuates   : $gpoCuatesNombre  ->  $ouCuates"
    msg_info "GPO NoCuates : $gpoNoCuatesNombre  ->  $ouNoCuates"
    msg_info "Estrategia   : FilePathRule+Exceptions (ruta) + FileHashRule Deny (hash dinamico)"
    msg_alert "AppLocker tarda ~2 minutos tras el arranque del cliente en cargar las reglas."
    Write-Host ""

    if (-not (Read-Confirm -Prompt "Confirmar y aplicar las dos GPOs" -Default 'S')) {
        return $false
    }

    # ── Limpiar GPOs existentes ANTES de crear (estado limpio garantizado) ────
    msg_process "Eliminando GPOs AppLocker existentes para comenzar desde cero..."

    $nCuatesRemoved = Remove-AppLockerGPOsForGroup `
        -OuDN       $ouCuates `
        -GPOPattern 'AppLocker'

    $nNoCuatesRemoved = Remove-AppLockerGPOsForGroup `
        -OuDN       $ouNoCuates `
        -GPOPattern 'AppLocker'

    $totalRemoved = $nCuatesRemoved + $nNoCuatesRemoved
    if ($totalRemoved -gt 0) {
        msg_success "Se eliminaron $totalRemoved GPO(s) previas de AppLocker."
        # Breve pausa para que AD replique la eliminacion
        Start-Sleep -Seconds 3
    } else {
        msg_info "No habia GPOs AppLocker previas."
    }

    # ── GPO 1: Cuates ─────────────────────────────────────────────────────────
    msg_process "Generando GPO para Cuates..."
    $xmlCuates = New-AppLockerXmlCuates -DomainName $script:AD_DOMAIN
    $okCuates  = Apply-AppLockerPolicyGPO `
        -PolicyXML   $xmlCuates `
        -GPOName     $gpoCuatesNombre `
        -OuDN        $ouCuates `
        -SaveXMLPath $saveCuates `
        -DomainName  $script:AD_DOMAIN

    if ($okCuates) {
        msg_success "GPO Cuates aplicada: notepad PERMITIDO (AuditOnly)."
    } else {
        msg_error "Fallo al aplicar GPO Cuates."
    }

    # ── GPO 2: NoCuates ───────────────────────────────────────────────────────
    msg_process "Generando GPO para NoCuates..."

    # Calcular path de notepad para el hash dinamico (ya fue localizado en Invoke-AppLockerSetup
    # pero lo recalculamos aqui para ser independientes del contexto de llamada)
    $notepadPathForHash = Get-NotepadPath
    if ($notepadPathForHash) {
        msg_success "Hash de notepad.exe se incluira en la politica (cubre renombrado)."
    } else {
        msg_alert "notepad.exe no localizado — la politica solo bloqueara por ruta, no por hash."
    }

    $xmlNoCuates = New-AppLockerXmlNoCuates `
        -DomainName  $script:AD_DOMAIN `
        -NotepadPath $notepadPathForHash
    if ($null -eq $xmlNoCuates) {
        msg_error "No se pudo generar el XML de NoCuates (SID no encontrado)."
        return $false
    }

    $okNoCuates = Apply-AppLockerPolicyGPO `
        -PolicyXML   $xmlNoCuates `
        -GPOName     $gpoNoCuatesNombre `
        -OuDN        $ouNoCuates `
        -SaveXMLPath $saveNoCuates `
        -DomainName  $script:AD_DOMAIN

    if ($okNoCuates) {
        msg_success "GPO NoCuates aplicada: notepad BLOQUEADO (ruta + hash dinamico)."
    } else {
        msg_error "Fallo al aplicar GPO NoCuates."
    }

    # Forzar actualizacion de politicas en el servidor
    try { Invoke-GPUpdate -Force -ErrorAction SilentlyContinue } catch {}

    Write-Host ""
    msg_info "XMLs guardados en el escritorio:"
    msg_info "  $saveCuates"
    msg_info "  $saveNoCuates"
    Write-Host ""
    msg_alert "En el cliente Win10: gpupdate /force"
    msg_alert "Espera 2 minutos antes de probar notepad."

    return ($okCuates -and $okNoCuates)
}

# -----------------------------------------------------------------------------
# Invoke-AppLockerPersonalizado
# Wizard regla por regla para configuraciones avanzadas.
# Conservado del flujo original para casos fuera de la practica.
# -----------------------------------------------------------------------------
function Invoke-AppLockerPersonalizado {
    Write-LogSection "AppLocker — Modo Personalizado"

    $gpoName = Read-InputLoop `
        -Prompt    "Nombre de la GPO de AppLocker" `
        -Validator { param($v) $v.Length -ge 3 } `
        -ErrorMsg  "Minimo 3 caracteres."
    if ($gpoName -eq $false) { return $false }

    $ouSel = Get-OUSelection -Prompt "OU a la que se vinculara la GPO de AppLocker"
    if ($null -eq $ouSel -or $ouSel -eq $false) { return $false }

    Write-Host ""
    msg_info "Configuracion del modo de enforcement por coleccion"
    msg_info "  AuditOnly      — Solo registra en el log, NO bloquea"
    msg_info "  Enabled        — Aplica las reglas y bloquea"
    msg_info "  NotConfigured  — La coleccion no se gestiona"
    Write-Host ""

    $collections = [ordered]@{}
    foreach ($coll in $script:AL_COLLECTIONS) {
        $modeSel = Read-Selection `
            -Prompt  "Modo para coleccion '$coll'" `
            -Options @('AuditOnly', 'Enabled', 'NotConfigured')
        $collections[$coll] = if ($modeSel -eq $false) { 'NotConfigured' } else { $modeSel.Value }
    }

    $allRules = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        $addRule = Read-Confirm `
            -Prompt "Agregar $(if ($allRules.Count -eq 0) { 'una' } else { 'otra' }) regla" `
            -Default 'S'
        if (-not $addRule) { break }
        $rule = Invoke-AppLockerRuleWizard
        if ($rule -ne $false -and $null -ne $rule) {
            $allRules.Add($rule)
            msg_success "Total de reglas: $($allRules.Count)"
        }
    }

    if ($allRules.Count -eq 0) {
        Write-Log WARN "No se creo ninguna regla."
        return $false
    }

    $xmlSavePath = $null
    if (Read-Confirm -Prompt "Guardar copia del XML" -Default 'S') {
        $suggested = "$env:USERPROFILE\Desktop\AppLocker_$($gpoName -replace '\s','_')_$(Get-Date -Format 'yyyyMMdd').xml"
        $xmlSavePath = Read-InputLoop -Prompt "Ruta (Enter para '$suggested')" -Validator { $true } -AllowEmpty $true
        if ($null -eq $xmlSavePath -or $xmlSavePath -eq $false) { $xmlSavePath = $suggested }
    }

    $policyXML = Build-AppLockerPolicyXML -Rules $allRules.ToArray() -Collections $collections

    if (-not (Read-Confirm -Prompt "Confirmar y aplicar" -Default 'S')) { return $false }

    # Limpiar GPOs existentes en la OU antes de aplicar la nueva
    msg_process "Eliminando GPOs AppLocker existentes en la OU seleccionada..."
    $nRemoved = Remove-AppLockerGPOsForGroup `
        -OuDN       $ouSel.Value `
        -GPOPattern 'AppLocker'
    if ($nRemoved -gt 0) {
        msg_success "Se eliminaron $nRemoved GPO(s) previas de AppLocker."
        Start-Sleep -Seconds 3
    } else {
        msg_info "No habia GPOs AppLocker previas en la OU."
    }

    return Apply-AppLockerPolicyGPO `
        -PolicyXML   $policyXML `
        -GPOName     $gpoName `
        -OuDN        $ouSel.Value `
        -SaveXMLPath $xmlSavePath
}


# -----------------------------------------------------------------------------
# Invoke-AppLockerMenu
# Menu del modulo para integracion con ac_manager.ps1
# -----------------------------------------------------------------------------
function Invoke-AppLockerMenu {
    while ($true) {
        Write-Host ""
        draw_header "Control de Ejecucion — AppLocker"

        $sel = Read-Selection `
            -Prompt "Selecciona una opcion" `
            -Options @(
                "Configuracion completa (reglas + GPO + enforcement)",
                "Agregar regla individual",
                "Verificar estado del servicio AppIdSvc",
                "Ver politica AppLocker activa en este equipo",
                "Exportar politica AppLocker activa a XML"
            ) `
            -AllowBack $true

        if ($null -eq $sel -or $sel -eq $false) { return }

        switch ($sel.Index) {
            0 { Invoke-AppLockerSetup }

            1 {
                $rule = Invoke-AppLockerRuleWizard
                if ($rule -ne $false -and $null -ne $rule) {
                    msg_success "Regla creada. Para aplicarla usa la opcion de configuracion completa."
                }
            }

            2 {
                if (Test-AppLockerService) {
                    msg_success "El servicio AppIdSvc esta ACTIVO."
                } else {
                    msg_alert "El servicio AppIdSvc NO esta activo."
                    Enable-AppLockerService
                }
            }

            3 {
                try {
                    $policy = Get-AppLockerPolicy -Effective -ErrorAction Stop
                    if ($null -eq $policy) {
                        msg_info "No hay politica AppLocker activa en este equipo."
                    } else {
                        Write-Separator
                        $policy.RuleCollections | ForEach-Object {
                            $coll = $_
                            msg_info "Coleccion: $($coll.RuleCollectionType)  [$($coll.EnforcementMode)]"
                            $coll | ForEach-Object {
                                $_.Rules | ForEach-Object {
                                    msg_info "  [$($_.Action)] $($_.Name) -> $($_.UserOrGroupSid)"
                                }
                            }
                        }
                        Write-Separator
                    }
                } catch {
                    Write-Log ERROR "No se pudo obtener la politica activa: $_"
                }
            }

            4 {
                $path = Read-InputLoop `
                    -Prompt    "Ruta para guardar el XML" `
                    -Validator { param($v) $v.Length -ge 5 } `
                    -ErrorMsg  "Ingresa una ruta valida."
                if ($path -eq $false) { break }
                try {
                    Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop |
                        Set-Content -Path $path -Encoding UTF8 -ErrorAction Stop
                    Write-Log SUCCESS "Politica exportada a: $path"
                } catch {
                    Write-Log ERROR "No se pudo exportar la politica: $_"
                }
            }
        }

        msg_pause
    }
}