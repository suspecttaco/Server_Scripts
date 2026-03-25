# =============================================================================
# ac_lib/ac_csv.ps1 — Lectura, validacion y distribucion de usuarios desde CSV
# Uso: . .\ac_lib\ac_csv.ps1
# Requiere: lib/ui.ps1, lib/input.ps1, ac_lib/ac_log.ps1, ac_lib/ac_ad.ps1
# =============================================================================

# -----------------------------------------------------------------------------
# CONSTANTES DE MODULO
# -----------------------------------------------------------------------------

# Columnas que el modulo reconoce. Las marcadas Required deben estar en el CSV.
# El usuario elige cual columna del CSV mapea a cada campo logico.
$script:CSV_FIELD_MAP = [ordered]@{
    FirstName      = @{ Required = $true;  Label = "Nombre(s)"                  }
    LastName       = @{ Required = $true;  Label = "Apellido(s)"                }
    SamAccountName = @{ Required = $true;  Label = "Nombre de inicio de sesion" }
    Password       = @{ Required = $true;  Label = "Contrasena inicial"         }
    OUTarget       = @{ Required = $true;  Label = "OU de destino"              }
    Group          = @{ Required = $false; Label = "Grupo de seguridad"         }
    Email          = @{ Required = $false; Label = "Correo electronico"         }
    Phone          = @{ Required = $false; Label = "Telefono"                   }
    Office         = @{ Required = $false; Label = "Oficina"                    }
    Description    = @{ Required = $false; Label = "Descripcion"                }
}

# -----------------------------------------------------------------------------
# Get-CSVPreview
# Muestra las primeras N filas del CSV para que el usuario confirme el mapeo.
# -----------------------------------------------------------------------------
function Get-CSVPreview {
    param(
        [Parameter(Mandatory)] [object[]] $Rows,
        [int] $MaxRows = 3
    )

    $preview = $Rows | Select-Object -First $MaxRows
    $cols    = $Rows[0].PSObject.Properties.Name

    Write-Host ""
    msg_info "Vista previa del CSV ($([Math]::Min($MaxRows, $Rows.Count)) de $($Rows.Count) filas):"
    Write-Separator

    # Encabezados
    $header = ($cols | ForEach-Object { $_.PadRight(20) }) -join ' | '
    Write-Host "  $header" -ForegroundColor Cyan

    # Filas
    foreach ($row in $preview) {
        $line = ($cols | ForEach-Object {
            $val = if ([string]::IsNullOrWhiteSpace($row.$_)) { '(vacio)' } else { $row.$_ }
            $val.Substring(0, [Math]::Min(20, $val.Length)).PadRight(20)
        }) -join ' | '
        Write-Host "  $line"
    }

    Write-Separator
}

# -----------------------------------------------------------------------------
# Invoke-ColumnMapping
# Muestra las columnas del CSV y pide al usuario que mapee cada campo logico
# a la columna correcta del archivo.
#
# Devuelve: hashtable { LogicalField -> ColumnName } | $false
# -----------------------------------------------------------------------------
function Invoke-ColumnMapping {
    param(
        [Parameter(Mandatory)] [string[]] $CsvColumns,
        [Parameter(Mandatory)] [string[]] $AvailableOUs
    )

    Write-LogSection "Mapeo de Columnas del CSV"

    msg_info "Columnas detectadas en el CSV:"
    for ($i = 0; $i -lt $CsvColumns.Count; $i++) {
        Write-Host "  [$($i+1)] $($CsvColumns[$i])"
    }
    Write-Host ""

    $mapping = @{}

    foreach ($field in $script:CSV_FIELD_MAP.Keys) {
        $meta     = $script:CSV_FIELD_MAP[$field]
        $label    = $meta.Label
        $required = $meta.Required

        $promptText = if ($required) { "$label  [REQUERIDO]" } else { "$label  (Enter para omitir)" }

        # Intentar autodeteccion por nombre similar
        $autoMatch = $CsvColumns | Where-Object {
            $_ -like "*$field*" -or $_ -like "*$label*"
        } | Select-Object -First 1

        if ($autoMatch) {
            msg_info "Campo '$label' — autodetectado: '$autoMatch'"
            $confirm = Read-Confirm -Prompt "Usar columna '$autoMatch' para '$label'" -Default 'S'
            if ($confirm) {
                $mapping[$field] = $autoMatch
                Write-Log INFO "Mapeo aceptado: $field -> $autoMatch"
                continue
            }
        }

        # Seleccion manual — (omitir) va AL FINAL para no desplazar los numeros de columna
        $options = [System.Collections.Generic.List[string]]($CsvColumns)
        if (-not $required) { $options.Add('(omitir este campo)') }

        $sel = Read-Selection -Prompt $promptText -Options $options.ToArray() -AllowBack $false
        if ($sel -eq $false) {
            if ($required) {
                Write-Log ERROR "Campo requerido '$label' no mapeado. Operacion cancelada."
                return $false
            }
            continue
        }

        $chosen = $sel.Value
        if ($chosen -eq '(omitir este campo)') {
            Write-Log INFO "Campo opcional '$field' omitido."
            continue
        }

        $mapping[$field] = $chosen
        Write-Log INFO "Mapeo: $field -> $chosen"
    }

    # Campo especial: el atributo del CSV que determina la OU destino
    # Puede ser el mismo campo OUTarget o uno diferente
    Write-Host ""
    msg_info "Configuracion de distribucion por OU"
    msg_info "El CSV debe indicar a que OU va cada usuario."
    msg_info "Valores validos en esa columna deben coincidir con los nombres de las OUs existentes."
    Write-Host ""

    # Mostrar OUs disponibles — advertir si solo hay OUs de sistema
    $customOUs = $AvailableOUs | Where-Object { $_ -notmatch 'Domain Controllers|Builtin|ForeignSecurityPrincipals|Managed Service Accounts' }
    if ($customOUs.Count -eq 0) {
        Write-Host ""
        msg_alert "ATENCION: No se encontraron OUs personalizadas en el dominio."
        msg_alert "Solo existe 'Domain Controllers' — debes crear las OUs primero."
        msg_info  "Ve al menu principal -> [1] Gestion AD -> crear OUs (Cuates, NoCuates)."
        Write-Host ""
        $continue = Read-Confirm -Prompt "Continuar de todas formas" -Default "N"
        if (-not $continue) { return $false }
    }
    msg_info "OUs disponibles en el dominio:"
    $AvailableOUs | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkCyan }
    Write-Host ""

    $matchMode = Read-Selection `
        -Prompt "Como se identifica la OU en el CSV" `
        -Options @(
            "Nombre exacto de la OU  (ej: Cuates)",
            "Nombre parcial / contiene  (ej: cuat -> Cuates)",
            "DistinguishedName completo"
        )
    if ($matchMode -eq $false) { return $false }
    $mapping['_OUMatchMode'] = $matchMode.Index   # 0=exact, 1=contains, 2=DN

    return $mapping
}

# -----------------------------------------------------------------------------
# Resolve-OUFromValue
# Resuelve el DN de una OU a partir del valor en el CSV segun el modo de match.
#
# Devuelve: DN string | $null si no encontro
# -----------------------------------------------------------------------------
function Resolve-OUFromValue {
    param(
        [Parameter(Mandatory)] [string]   $Value,
        [Parameter(Mandatory)] [object[]] $OUList,   # [{Name, DN}]
        [Parameter(Mandatory)] [int]      $MatchMode  # 0=exact, 1=contains, 2=DN
    )

    switch ($MatchMode) {
        0 {   # Exacto
            $match = $OUList | Where-Object { $_.Name -eq $Value } | Select-Object -First 1
        }
        1 {   # Contiene
            $match = $OUList | Where-Object {
                $_.Name -like "*$Value*" -or $Value -like "*$($_.Name)*"
            } | Select-Object -First 1
        }
        2 {   # DN completo
            $match = $OUList | Where-Object { $_.DN -eq $Value } | Select-Object -First 1
        }
    }

    if ($match) { return $match.DN }
    return $null
}

# -----------------------------------------------------------------------------
# Test-CSVRow
# Valida una fila del CSV contra las reglas de cada campo.
# Devuelve array de strings con errores encontrados (vacio = valido).
# -----------------------------------------------------------------------------
function Test-CSVRow {
    param(
        [Parameter(Mandatory)] [object]    $Row,
        [Parameter(Mandatory)] [hashtable] $Mapping,
        [int] $RowNumber = 0
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    # FirstName
    if ($Mapping['FirstName']) {
        $v = $Row.($Mapping['FirstName'])
        if ([string]::IsNullOrWhiteSpace($v)) {
            $errors.Add("Fila $RowNumber : Nombre vacio")
        } elseif ($v.Length -lt 1 -or $v.Length -gt 50) {
            $errors.Add("Fila $RowNumber : Nombre invalido '$v' (max 50 chars)")
        }
    }

    # LastName
    if ($Mapping['LastName']) {
        $v = $Row.($Mapping['LastName'])
        if ([string]::IsNullOrWhiteSpace($v)) {
            $errors.Add("Fila $RowNumber : Apellido vacio")
        } elseif ($v.Length -lt 1 -or $v.Length -gt 50) {
            $errors.Add("Fila $RowNumber : Apellido invalido '$v' (max 50 chars)")
        }
    }

    # SamAccountName
    if ($Mapping['SamAccountName']) {
        $v = $Row.($Mapping['SamAccountName'])
        if ([string]::IsNullOrWhiteSpace($v)) {
            $errors.Add("Fila $RowNumber : SamAccountName vacio")
        } elseif ($v -notmatch '^[a-zA-Z0-9._\-]{1,20}$') {
            $errors.Add("Fila $RowNumber : SamAccountName invalido '$v' (max 20 chars, sin espacios)")
        }
    }

    # Password — solo validar que no este vacio; complejidad se valida al crear
    if ($Mapping['Password']) {
        $v = $Row.($Mapping['Password'])
        if ([string]::IsNullOrWhiteSpace($v)) {
            $errors.Add("Fila $RowNumber : Contrasena vacia")
        } elseif ($v.Length -lt 8) {
            $errors.Add("Fila $RowNumber : Contrasena muy corta (minimo 8 caracteres)")
        }
    }

    # OUTarget — no puede estar vacio
    if ($Mapping['OUTarget']) {
        $v = $Row.($Mapping['OUTarget'])
        if ([string]::IsNullOrWhiteSpace($v)) {
            $errors.Add("Fila $RowNumber : Valor de OU destino vacio")
        }
    }

    # Email — solo si esta mapeado y tiene valor
    if ($Mapping['Email']) {
        $v = $Row.($Mapping['Email'])
        if (-not [string]::IsNullOrWhiteSpace($v) -and $v -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            $errors.Add("Fila $RowNumber : Email invalido '$v'")
        }
    }

    return $errors.ToArray()
}

# -----------------------------------------------------------------------------
# Invoke-CSVUserImport
# Flujo completo: leer CSV, mapear columnas, validar, previsualizar y crear
# usuarios en AD usando New-ADDomainUser de ac_ad.ps1.
#
# Parametros:
#   -CsvPath          Ruta del archivo CSV (si $null se solicita al usuario)
#   -DefaultPassword  SecureString de contrasena por defecto (si columna no existe)
#   -EnabledByDefault Bool: estado inicial de las cuentas
#   -MustChangePass   Bool: forzar cambio de contrasena en primer logon
#
# Devuelve: hashtable { Created, Skipped, Failed, Total }
# -----------------------------------------------------------------------------
function Invoke-CSVUserImport {
    param(
        [string]       $CsvPath          = $null,
        [securestring] $DefaultPassword  = $null,
        [bool]         $EnabledByDefault = $true,
        [bool]         $MustChangePass   = $true
    )

    Write-LogSection "Importacion de Usuarios desde CSV"

    if (-not $script:AD_DOMAIN_DN) {
        Write-Log ERROR "No hay conexion al dominio. Ejecuta Initialize-ADConnection primero."
        return $false
    }

    # ── 1. Ruta del archivo ──────────────────────────────────────────────────
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        $CsvPath = Read-FilePath `
            -Prompt "Ruta del archivo CSV" `
            -MustExist $true `
            -Type 'File' `
            -Extension '.csv'
        if ($CsvPath -eq $false) { return $false }
    }

    # ── 2. Leer el CSV ───────────────────────────────────────────────────────
    $rows = $null
    try {
        $rows = Import-Csv -Path $CsvPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Intentar con encoding por defecto
        try {
            $rows = Import-Csv -Path $CsvPath -ErrorAction Stop
        } catch {
            Write-Log ERROR "No se pudo leer el CSV '$CsvPath': $_"
            return $false
        }
    }

    if ($null -eq $rows -or $rows.Count -eq 0) {
        Write-Log ERROR "El CSV esta vacio o no contiene filas de datos."
        return $false
    }

    $csvColumns = $rows[0].PSObject.Properties.Name
    Write-Log INFO "CSV cargado: $($rows.Count) filas, $($csvColumns.Count) columnas."

    # ── 3. Vista previa ──────────────────────────────────────────────────────
    Get-CSVPreview -Rows $rows -MaxRows 3

    $proceed = Read-Confirm -Prompt "El archivo parece correcto, continuar" -Default 'S'
    if (-not $proceed) {
        Write-Log INFO "Importacion cancelada por el usuario."
        return $false
    }

    # ── 4. Opciones globales de cuenta ───────────────────────────────────────
    Write-Host ""
    msg_info "Opciones globales para todos los usuarios del CSV"
    Write-Separator

    $EnabledByDefault = Read-Confirm `
        -Prompt "Crear cuentas habilitadas" `
        -Default $(if ($EnabledByDefault) { 'S' } else { 'N' })

    $MustChangePass = Read-Confirm `
        -Prompt "Forzar cambio de contrasena en primer logon" `
        -Default $(if ($MustChangePass) { 'S' } else { 'N' })

    # Contrasena por defecto si el CSV no tiene esa columna
    if ($null -eq $DefaultPassword) {
        $useDefaultPass = Read-Confirm `
            -Prompt "Usar una contrasena por defecto para todos (en vez de la del CSV)" `
            -Default 'N'
        if ($useDefaultPass) {
            $DefaultPassword = Read-SecureInput `
                -Prompt "Contrasena por defecto" `
                -Confirm $true `
                -MinLength 8
            if ($DefaultPassword -eq $false) { return $false }
        }
    }

    # ── 5. Obtener OUs disponibles ───────────────────────────────────────────
    $ouList = @()
    try {
        $ouList = Get-ADOrganizationalUnit `
            -Filter * `
            -SearchBase $script:AD_DOMAIN_DN `
            -Properties Name, DistinguishedName `
            -ErrorAction Stop |
            Select-Object Name, @{N='DN';E={$_.DistinguishedName}} |
            Sort-Object Name
    } catch {
        Write-Log ERROR "No se pudieron obtener las OUs: $_"
        return $false
    }

    $ouList = @($ouList)
    if ($ouList.Count -eq 0) {
        Write-Log ERROR "No hay OUs en el dominio. Crea al menos una OU antes de importar usuarios."
        return $false
    }

    # ── 6. Mapeo de columnas ─────────────────────────────────────────────────
    $ouNames  = $ouList | Select-Object -ExpandProperty Name
    $mapping  = Invoke-ColumnMapping -CsvColumns $csvColumns -AvailableOUs $ouNames
    if ($mapping -eq $false) { return $false }

    $ouMatchMode = if ($mapping.ContainsKey('_OUMatchMode')) { $mapping['_OUMatchMode'] } else { 0 }

    # ── 7. Validacion previa del CSV completo ────────────────────────────────
    Write-Host ""
    msg_process "Validando todas las filas del CSV..."

    $allErrors    = [System.Collections.Generic.List[string]]::new()
    $rowNum       = 1
    $samsSeen     = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($row in $rows) {
        [string[]]$rowErrors = Test-CSVRow -Row $row -Mapping $mapping -RowNumber $rowNum

        # Verificar SAM duplicado dentro del CSV
        if ($mapping['SamAccountName']) {
            $sam = $row.($mapping['SamAccountName'])
            if (-not [string]::IsNullOrWhiteSpace($sam)) {
                if ($samsSeen.Contains($sam.ToLower())) {
                    $rowErrors += "Fila $rowNum : SamAccountName duplicado en el CSV: '$sam'"
                }
                $samsSeen.Add($sam.ToLower()) | Out-Null
            }
        }

        # Verificar que la OU exista
        if ($mapping['OUTarget']) {
            $ouVal = $row.($mapping['OUTarget'])
            if (-not [string]::IsNullOrWhiteSpace($ouVal)) {
                $resolved = Resolve-OUFromValue -Value $ouVal -OUList $ouList -MatchMode $ouMatchMode
                if (-not $resolved) {
                    $rowErrors += "Fila $rowNum : OU no encontrada para valor '$ouVal'"
                }
            }
        }

        foreach ($e in $rowErrors) { $allErrors.Add($e) }
        $rowNum++
    }

    if ($allErrors.Count -gt 0) {
        Write-Host ""
        msg_alert "Se encontraron $($allErrors.Count) error(es) de validacion:"
        $allErrors | Select-Object -First 20 | ForEach-Object { msg_error "  $_" }
        if ($allErrors.Count -gt 20) {
            msg_alert "  ... y $($allErrors.Count - 20) errores mas (ver log completo)."
        }
        $allErrors | ForEach-Object { Write-Log ERROR $_ -NoEcho $true }

        Write-Host ""
        $forceImport = Read-Confirm `
            -Prompt "Continuar de todas formas (las filas invalidas se omitiran)" `
            -Default 'N'
        if (-not $forceImport) {
            Write-Log INFO "Importacion cancelada por el usuario tras errores de validacion."
            return $false
        }
    } else {
        msg_success "Todas las filas pasaron la validacion."
    }

    # ── 8. Confirmacion final ────────────────────────────────────────────────
    Write-Host ""
    msg_info "Resumen de importacion:"
    msg_info "  Archivo    : $CsvPath"
    msg_info "  Filas      : $($rows.Count)"
    msg_info "  Errores    : $($allErrors.Count)"
    msg_info "  Habilitado : $EnabledByDefault"
    msg_info "  Cambio pass: $MustChangePass"
    Write-Host ""

    $confirm = Read-Confirm -Prompt "Confirmar creacion de usuarios en Active Directory" -Default 'S'
    if (-not $confirm) {
        Write-Log INFO "Importacion cancelada por el usuario."
        return $false
    }

    # ── 9. Crear usuarios ────────────────────────────────────────────────────
    $stats = @{ Created = 0; Skipped = 0; Failed = 0; Total = $rows.Count }
    $rowNum = 1

    foreach ($row in $rows) {
        $sam = if ($mapping['SamAccountName']) { $row.($mapping['SamAccountName']) } else { $null }
        Write-Log INFO "Procesando fila $rowNum/$($rows.Count): $sam"

        # Validar fila individualmente antes de crear
        [string[]]$rowErrors = Test-CSVRow -Row $row -Mapping $mapping -RowNumber $rowNum
        if ($rowErrors -and $rowErrors.Length -gt 0) {
            Write-Log WARN "Fila $rowNum omitida por errores de validacion."
            $stats.Skipped++
            $rowNum++
            continue
        }

        # Resolver OU
        $ouDN = $null
        if ($mapping['OUTarget']) {
            $ouVal = $row.($mapping['OUTarget'])
            $ouDN  = Resolve-OUFromValue -Value $ouVal -OUList $ouList -MatchMode $ouMatchMode
        }
        if (-not $ouDN) {
            Write-Log WARN "Fila $rowNum : OU no resuelta para '$($row.($mapping['OUTarget']))'. Fila omitida."
            $stats.Skipped++
            $rowNum++
            continue
        }

        # Resolver contrasena
        $password = $DefaultPassword
        if ($null -eq $password -and $mapping['Password']) {
            $plainPass = $row.($mapping['Password'])
            try {
                $password = ConvertTo-SecureString $plainPass -AsPlainText -Force
            } catch {
                Write-Log WARN "Fila $rowNum : No se pudo convertir la contrasena. Fila omitida."
                $stats.Skipped++
                $rowNum++
                continue
            }
        }

        if ($null -eq $password) {
            Write-Log WARN "Fila $rowNum : Sin contrasena disponible. Fila omitida."
            $stats.Skipped++
            $rowNum++
            continue
        }

        # Construir UserData
        $userData = @{
            FirstName      = if ($mapping['FirstName'])      { $row.($mapping['FirstName'])      } else { '' }
            LastName       = if ($mapping['LastName'])       { $row.($mapping['LastName'])       } else { '' }
            SamAccountName = $sam
            Password       = $password
            OuDN           = $ouDN
            Enabled        = $EnabledByDefault
            MustChangePass = $MustChangePass
        }

        # Opcionales
        foreach ($opt in @('Group','Email','Phone','Office','Description')) {
            if ($mapping[$opt]) {
                $val = $row.($mapping[$opt])
                if (-not [string]::IsNullOrWhiteSpace($val)) {
                    $userData[$opt] = $val
                }
            }
        }

        # Crear
        $result = New-ADDomainUser -UserData $userData
        if ($result -eq $false) {
            $stats.Failed++
        } else {
            $stats.Created++
        }

        $rowNum++
    }

    # ── 10. Resumen final ────────────────────────────────────────────────────
    Write-Host ""
    Write-LogSection "Resultado de Importacion CSV"
    msg_info  "  Total procesados : $($stats.Total)"
    msg_success "  Creados          : $($stats.Created)"
    msg_alert  "  Omitidos         : $($stats.Skipped)"
    msg_error  "  Fallidos         : $($stats.Failed)"

    Write-Log INFO "Importacion CSV finalizada — Creados: $($stats.Created) | Omitidos: $($stats.Skipped) | Fallidos: $($stats.Failed)"

    return $stats
}

# -----------------------------------------------------------------------------
# Export-CSVTemplate
# Genera un archivo CSV de plantilla con las columnas esperadas y
# 10 usuarios de ejemplo para que el usuario lo complete.
#
# Parametros:
#   -OutputPath  Ruta donde guardar la plantilla (si $null se solicita)
# -----------------------------------------------------------------------------
function Export-CSVTemplate {
    param([string] $OutputPath = $null)

    Write-LogSection "Generar Plantilla CSV"

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $suggested = "$env:USERPROFILE\Desktop\usuarios_plantilla.csv"
        $OutputPath = Read-InputLoop `
            -Prompt "Ruta para guardar la plantilla (Enter para '$suggested')" `
            -Validator { $true } `
            -AllowEmpty $true
        if ($null -eq $OutputPath -or $OutputPath -eq $false) { $OutputPath = $suggested }
    }

    $template = @(
        [PSCustomObject]@{
            Nombre='Juan';       Apellido='Garcia';     Usuario='juan.garcia';
            Contrasena='P@ss12345'; Departamento='Cuates';
            Grupo='GRP_Cuates';  Email='juan.garcia@practica.local';
            Telefono='+52 667 100 0001'; Oficina='Planta Baja'; Descripcion='Usuario de prueba 1'
        }
        [PSCustomObject]@{
            Nombre='Maria';      Apellido='Lopez';      Usuario='maria.lopez';
            Contrasena='P@ss12345'; Departamento='Cuates';
            Grupo='GRP_Cuates';  Email='maria.lopez@practica.local';
            Telefono='+52 667 100 0002'; Oficina='Planta Baja'; Descripcion='Usuario de prueba 2'
        }
        [PSCustomObject]@{
            Nombre='Carlos';     Apellido='Martinez';   Usuario='carlos.martinez';
            Contrasena='P@ss12345'; Departamento='Cuates';
            Grupo='GRP_Cuates';  Email='carlos.martinez@practica.local';
            Telefono='+52 667 100 0003'; Oficina='Piso 1'; Descripcion='Usuario de prueba 3'
        }
        [PSCustomObject]@{
            Nombre='Ana';        Apellido='Rodriguez';  Usuario='ana.rodriguez';
            Contrasena='P@ss12345'; Departamento='No Cuates';
            Grupo='GRP_NoCuates'; Email='ana.rodriguez@practica.local';
            Telefono='+52 667 100 0004'; Oficina='Piso 1'; Descripcion='Usuario de prueba 4'
        }
        [PSCustomObject]@{
            Nombre='Luis';       Apellido='Hernandez';  Usuario='luis.hernandez';
            Contrasena='P@ss12345'; Departamento='No Cuates';
            Grupo='GRP_NoCuates'; Email='luis.hernandez@practica.local';
            Telefono='+52 667 100 0005'; Oficina='Piso 2'; Descripcion='Usuario de prueba 5'
        }
        [PSCustomObject]@{
            Nombre='Sofia';      Apellido='Perez';      Usuario='sofia.perez';
            Contrasena='P@ss12345'; Departamento='No Cuates';
            Grupo='GRP_NoCuates'; Email='sofia.perez@practica.local';
            Telefono='+52 667 100 0006'; Oficina='Piso 2'; Descripcion='Usuario de prueba 6'
        }
        [PSCustomObject]@{
            Nombre='Diego';      Apellido='Sanchez';    Usuario='diego.sanchez';
            Contrasena='P@ss12345'; Departamento='Cuates';
            Grupo='GRP_Cuates';  Email='diego.sanchez@practica.local';
            Telefono='+52 667 100 0007'; Oficina='Planta Baja'; Descripcion='Usuario de prueba 7'
        }
        [PSCustomObject]@{
            Nombre='Valeria';    Apellido='Ramirez';    Usuario='valeria.ramirez';
            Contrasena='P@ss12345'; Departamento='Cuates';
            Grupo='GRP_Cuates';  Email='valeria.ramirez@practica.local';
            Telefono='+52 667 100 0008'; Oficina='Piso 1'; Descripcion='Usuario de prueba 8'
        }
        [PSCustomObject]@{
            Nombre='Miguel';     Apellido='Torres';     Usuario='miguel.torres';
            Contrasena='P@ss12345'; Departamento='No Cuates';
            Grupo='GRP_NoCuates'; Email='miguel.torres@practica.local';
            Telefono='+52 667 100 0009'; Oficina='Piso 2'; Descripcion='Usuario de prueba 9'
        }
        [PSCustomObject]@{
            Nombre='Isabella';   Apellido='Flores';     Usuario='isabella.flores';
            Contrasena='P@ss12345'; Departamento='No Cuates';
            Grupo='GRP_NoCuates'; Email='isabella.flores@practica.local';
            Telefono='+52 667 100 0010'; Oficina='Piso 2'; Descripcion='Usuario de prueba 10'
        }
    )

    try {
        $template | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-Log SUCCESS "Plantilla generada: $OutputPath"
        msg_success "Plantilla guardada en: $OutputPath"
        msg_info "Edita el archivo y vuelve a ejecutar la importacion."
        return $OutputPath
    } catch {
        Write-Log ERROR "No se pudo guardar la plantilla: $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Test-GroupsPopulated
# Verifica si los grupos de seguridad del dominio tienen miembros.
# Idempotencia inteligente: el estado puede decir "completado" pero si los
# grupos estan vacios (ej: CSV no estaba disponible la primera vez), hay
# que re-importar. Devuelve $true si todos los grupos tienen al menos 1 miembro.
# -----------------------------------------------------------------------------
function Test-GroupsPopulated {
    if (-not $script:AD_DOMAIN_DN) { return $false }
    try {
        # Solo verificar grupos GRP_* del proyecto, no built-ins de Windows
        $groups = @(Get-ADGroup -Filter { Name -like "GRP_*" } -SearchBase $script:AD_DOMAIN_DN -ErrorAction Stop)
        if ($groups.Count -eq 0) { return $false }
        foreach ($grp in $groups) {
            $count = @(Get-ADGroupMember -Identity $grp.Name -ErrorAction Stop).Count
            if ($count -eq 0) {
                Write-Log WARN "Grupo '$($grp.Name)' esta vacio — se requiere re-importacion."
                return $false
            }
        }
        return $true
    } catch {
        return $false
    }
}

# -----------------------------------------------------------------------------
# Invoke-CSVMenu
# Menu de opciones del modulo CSV para integracion con ac_manager.ps1
# -----------------------------------------------------------------------------
function Invoke-CSVMenu {
    # Idempotencia inteligente: si hay grupos vacios, avisar al usuario
    if ($script:AD_DOMAIN_DN -and -not (Test-GroupsPopulated)) {
        Write-Host ""
        msg_alert "Se detectaron grupos de seguridad vacios en el dominio."
        msg_alert "Es posible que el CSV no se haya importado correctamente."
        $reimport = Read-Confirm -Prompt "Importar usuarios desde CSV ahora" -Default 'S'
        if ($reimport) {
            Invoke-CSVUserImport
            msg_pause
        }
    }

    while ($true) {
        Write-Host ""
        draw_header "Gestion de Usuarios — CSV / Manual"

        $sel = Read-Selection `
            -Prompt "Selecciona una opcion" `
            -Options @(
                "Importar usuarios desde CSV",
                "Alta manual de usuario (ABC)",
                "Generar plantilla CSV de ejemplo",
                "Ver resumen del dominio"
            ) `
            -AllowBack $true

        if ($null -eq $sel -or $sel -eq $false) { return }

        switch ($sel.Index) {
            0 { Invoke-CSVUserImport  }
            1 { Invoke-ManualUserCreation }
            2 { Export-CSVTemplate    }
            3 { Get-ADDomainSummary   }
        }

        msg_pause
    }
}