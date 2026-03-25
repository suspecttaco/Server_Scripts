# =============================================================================
# lib/input.ps1 — Helpers de entrada interactiva con validacion y reintentos
# Uso: . .\lib\input.ps1   (requiere lib/ui.ps1 cargado antes)
# Reutilizable en cualquier proyecto PowerShell
# =============================================================================

$INPUT_MAX_ATTEMPTS = if ($env:INPUT_MAX_ATTEMPTS) { [int]$env:INPUT_MAX_ATTEMPTS } else { 10 }

# -----------------------------------------------------------------------------
# Read-InputLoop
# Solicita un valor con reintentos hasta que pase la validacion.
#
# Parametros:
#   -Prompt        Texto que se muestra al usuario (sin "-> ")
#   -Validator     ScriptBlock que recibe el valor y devuelve $true/$false
#   -ErrorMsg      Mensaje de error si la validacion falla
#   -AllowEmpty    Si $true, Enter vacio devuelve $null (omitir campo)
#   -MaxAttempts   Maximo de intentos (default: $INPUT_MAX_ATTEMPTS)
#   -Transform     ScriptBlock opcional para transformar el valor antes de devolverlo
#
# Devuelve:
#   string con el valor validado
#   $null si AllowEmpty y el usuario presiono Enter
#   $false si se agotaron los intentos
# -----------------------------------------------------------------------------
function Read-InputLoop {
    param(
        [Parameter(Mandatory)] [string]    $Prompt,
        [Parameter(Mandatory)] [scriptblock] $Validator,
        [string]     $ErrorMsg    = "Valor invalido. Intente de nuevo.",
        [bool]       $AllowEmpty  = $false,
        [int]        $MaxAttempts = $INPUT_MAX_ATTEMPTS,
        [scriptblock]$Transform   = $null
    )

    $attempts = 0
    while ($attempts -lt $MaxAttempts) {
        msg_input "$Prompt$(if ($AllowEmpty) { ' (Enter para omitir)' }): "
        $raw = Read-Host

        # Campo vacio
        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($AllowEmpty) { return $null }
            msg_error "Este campo no puede estar vacio."
            $attempts++
            continue
        }

        # Validacion
        try {
            $valid = & $Validator $raw
        } catch {
            $valid = $false
        }

        if (-not $valid) {
            msg_error $ErrorMsg
            $attempts++
            continue
        }

        # Transformacion opcional
        if ($null -ne $Transform) {
            try { $raw = & $Transform $raw } catch {}
        }

        return $raw
    }

    msg_error "Demasiados intentos fallidos ($MaxAttempts). Operacion cancelada."
    return $false
}

# -----------------------------------------------------------------------------
# Read-Selection
# Muestra una lista numerada y devuelve el indice (0-based) y el valor elegido.
#
# Parametros:
#   -Prompt    Texto de la pregunta
#   -Options   Array de strings con las opciones
#   -AllowBack Si $true, agrega opcion "0. Volver" que devuelve $null
#
# Devuelve:
#   [PSCustomObject] con .Index (0-based) y .Value (string)
#   $null si AllowBack y el usuario eligio 0
#   $false si se agotaron los intentos
# -----------------------------------------------------------------------------
function Read-Selection {
    param(
        [Parameter(Mandatory)] [string]   $Prompt,
        [Parameter(Mandatory)] [string[]] $Options,
        [bool] $AllowBack = $false
    )

    if ($Options.Count -eq 0) {
        msg_error "No hay opciones disponibles."
        return $false
    }

    $attempts = 0
    while ($attempts -lt $INPUT_MAX_ATTEMPTS) {
        Write-Host ""
        msg_info $Prompt
        Write-Separator

        if ($AllowBack) {
            Write-Host "  [0] Volver" -ForegroundColor DarkGray
        }

        for ($i = 0; $i -lt $Options.Count; $i++) {
            Write-Host "  [$($i + 1)] $($Options[$i])"
        }

        Write-Separator
        msg_input "Selecciona una opcion: "
        $raw = Read-Host

        if ([string]::IsNullOrWhiteSpace($raw)) {
            msg_error "Debes ingresar un numero."
            $attempts++
            continue
        }

        if ($AllowBack -and $raw -eq '0') { return $null }

        $num = 0
        if (-not [int]::TryParse($raw, [ref]$num)) {
            msg_error "Ingresa solo el numero de la opcion."
            $attempts++
            continue
        }

        if ($num -lt 1 -or $num -gt $Options.Count) {
            msg_error "Opcion fuera de rango. Elige entre 1 y $($Options.Count)."
            $attempts++
            continue
        }

        return [PSCustomObject]@{ Index = $num - 1; Value = $Options[$num - 1] }
    }

    msg_error "Demasiados intentos fallidos. Operacion cancelada."
    return $false
}

# -----------------------------------------------------------------------------
# Read-MultiSelect
# Muestra una lista numerada y permite elegir multiples opciones.
# El usuario ingresa los numeros separados por comas (ej: "1,3,4")
# o "todos" / "*" para seleccionar todo.
#
# Parametros:
#   -Prompt      Texto de la pregunta
#   -Options     Array de strings con las opciones
#   -MinSelect   Minimo de items a seleccionar (default: 1)
#   -MaxSelect   Maximo de items a seleccionar (default: todos)
#   -AllowAll    Si $true, acepta "todos" o "*" como entrada
#
# Devuelve:
#   [PSCustomObject[]] array con .Index y .Value por cada seleccion
#   $false si se agotaron los intentos
# -----------------------------------------------------------------------------
function Read-MultiSelect {
    param(
        [Parameter(Mandatory)] [string]   $Prompt,
        [Parameter(Mandatory)] [string[]] $Options,
        [int]  $MinSelect = 1,
        [int]  $MaxSelect = 0,       # 0 = sin limite
        [bool] $AllowAll  = $true
    )

    if ($Options.Count -eq 0) {
        msg_error "No hay opciones disponibles."
        return $false
    }

    if ($MaxSelect -eq 0) { $MaxSelect = $Options.Count }

    $attempts = 0
    while ($attempts -lt $INPUT_MAX_ATTEMPTS) {
        Write-Host ""
        msg_info $Prompt
        Write-Separator

        for ($i = 0; $i -lt $Options.Count; $i++) {
            Write-Host "  [$($i + 1)] $($Options[$i])"
        }

        if ($AllowAll) {
            Write-Host "  [*] Todos" -ForegroundColor DarkGray
        }

        Write-Separator
        msg_input "Selecciona opciones separadas por coma (ej: 1,3,4): "
        $raw = Read-Host

        if ([string]::IsNullOrWhiteSpace($raw)) {
            msg_error "Debes seleccionar al menos $MinSelect opcion(es)."
            $attempts++
            continue
        }

        # Seleccion total
        if ($AllowAll -and ($raw.Trim() -eq '*' -or $raw.Trim().ToLower() -eq 'todos')) {
            return @(0..($Options.Count - 1) | ForEach-Object {
                [PSCustomObject]@{ Index = $_; Value = $Options[$_] }
            })
        }

        # Parsear numeros
        $parts  = $raw -split ',' | ForEach-Object { $_.Trim() }
        $result = [System.Collections.Generic.List[PSCustomObject]]::new()
        $valid  = $true

        foreach ($part in $parts) {
            $num = 0
            if (-not [int]::TryParse($part, [ref]$num)) {
                msg_error "Valor no valido: '$part'. Usa solo numeros separados por comas."
                $valid = $false
                break
            }
            if ($num -lt 1 -or $num -gt $Options.Count) {
                msg_error "Numero fuera de rango: $num. Rango valido: 1-$($Options.Count)."
                $valid = $false
                break
            }
            $idx = $num - 1
            if ($result | Where-Object { $_.Index -eq $idx }) {
                msg_error "Numero duplicado: $num."
                $valid = $false
                break
            }
            $result.Add([PSCustomObject]@{ Index = $idx; Value = $Options[$idx] })
        }

        if (-not $valid) { $attempts++; continue }

        if ($result.Count -lt $MinSelect) {
            msg_error "Debes seleccionar al menos $MinSelect opcion(es)."
            $attempts++
            continue
        }

        if ($result.Count -gt $MaxSelect) {
            msg_error "Puedes seleccionar como maximo $MaxSelect opcion(es)."
            $attempts++
            continue
        }

        return $result.ToArray()
    }

    msg_error "Demasiados intentos fallidos. Operacion cancelada."
    return $false
}

# -----------------------------------------------------------------------------
# Read-Confirm
# Solicita confirmacion Si/No.
#
# Parametros:
#   -Prompt    Pregunta a mostrar
#   -Default   Valor por defecto si el usuario presiona Enter ('S' o 'N')
#              $null = no hay default, Enter no se acepta
#
# Devuelve: $true (Si) | $false (No)
# -----------------------------------------------------------------------------
function Read-Confirm {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [string] $Default = $null
    )

    $hint = switch ($Default) {
        'S' { '[S/n]' }
        'N' { '[s/N]' }
        default { '[s/n]' }
    }

    $attempts = 0
    while ($attempts -lt $INPUT_MAX_ATTEMPTS) {
        msg_input "$Prompt $hint : "
        $raw = Read-Host

        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($Default -eq 'S') { return $true  }
            if ($Default -eq 'N') { return $false }
            msg_error "Responde 's' (si) o 'n' (no)."
            $attempts++
            continue
        }

        switch ($raw.Trim().ToUpper()) {
            'S'  { return $true  }
            'SI' { return $true  }
            'N'  { return $false }
            'NO' { return $false }
            default {
                msg_error "Respuesta no reconocida. Escribe 's' o 'n'."
                $attempts++
            }
        }
    }

    # Si se agotaron los intentos, usa el default o false
    if ($Default -eq 'S') { return $true }
    return $false
}

# -----------------------------------------------------------------------------
# Read-SecureInput
# Solicita un valor sensible (contrasena) como SecureString con confirmacion.
#
# Parametros:
#   -Prompt      Texto del campo
#   -Confirm     Si $true, pide confirmacion (escribir dos veces)
#   -MinLength   Longitud minima requerida (default: 1)
#   -Validator   ScriptBlock adicional opcional sobre el string plano
#   -ErrorMsg    Mensaje si falla el validador adicional
#
# Devuelve: [SecureString]
# -----------------------------------------------------------------------------
function Read-SecureInput {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [bool]        $Confirm    = $true,
        [int]         $MinLength  = 1,
        [scriptblock] $Validator  = $null,
        [string]      $ErrorMsg   = "La contrasena no cumple los requisitos."
    )

    $attempts = 0
    while ($attempts -lt $INPUT_MAX_ATTEMPTS) {
        msg_input "${Prompt}: "
        $secure1 = Read-Host -AsSecureString

        # Extraer texto plano para validar longitud
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure1)
        )

        if ($plain.Length -lt $MinLength) {
            msg_error "Minimo $MinLength caracteres requeridos."
            $attempts++
            continue
        }

        if ($null -ne $Validator) {
            try { $ok = & $Validator $plain } catch { $ok = $false }
            if (-not $ok) {
                msg_error $ErrorMsg
                $attempts++
                continue
            }
        }

        if ($Confirm) {
            msg_input "Confirma ${Prompt}: "
            $secure2 = Read-Host -AsSecureString
            $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2)
            )

            if ($plain -ne $plain2) {
                msg_error "Las contrasenas no coinciden. Intente de nuevo."
                $attempts++
                continue
            }
        }

        # Limpiar variables de texto plano de memoria
        $plain  = $null
        $plain2 = $null

        return $secure1
    }

    msg_error "Demasiados intentos fallidos. Operacion cancelada."
    return $false
}

# -----------------------------------------------------------------------------
# Read-IntInRange
# Solicita un entero dentro de un rango [Min, Max].
#
# Parametros:
#   -Prompt     Texto del campo
#   -Min        Valor minimo permitido
#   -Max        Valor maximo permitido
#   -Default    Valor default si el usuario presiona Enter ($null = ninguno)
#   -AllowEmpty Si $true y Default es $null, Enter devuelve $null
#
# Devuelve: [int] | $null si AllowEmpty y Enter | $false si fallo total
# -----------------------------------------------------------------------------
function Read-IntInRange {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] [int]    $Min,
        [Parameter(Mandatory)] [int]    $Max,
        [object] $Default    = $null,
        [bool]   $AllowEmpty = $false
    )

    $hint = if ($null -ne $Default) { " [default: $Default]" } else { "" }

    $attempts = 0
    while ($attempts -lt $INPUT_MAX_ATTEMPTS) {
        msg_input "$Prompt ($Min-$Max)$hint : "
        $raw = Read-Host

        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($null -ne $Default) { return [int]$Default }
            if ($AllowEmpty)        { return $null          }
            msg_error "Este campo no puede estar vacio."
            $attempts++
            continue
        }

        $num = 0
        if (-not [int]::TryParse($raw.Trim(), [ref]$num)) {
            msg_error "Ingresa solo un numero entero."
            $attempts++
            continue
        }

        if ($num -lt $Min -or $num -gt $Max) {
            msg_error "Valor fuera de rango. Debe estar entre $Min y $Max."
            $attempts++
            continue
        }

        return [int]$num
    }

    msg_error "Demasiados intentos fallidos. Operacion cancelada."
    return $false
}

# -----------------------------------------------------------------------------
# Read-FilePath
# Solicita una ruta de archivo o directorio con validacion de existencia.
#
# Parametros:
#   -Prompt      Texto del campo
#   -MustExist   Si $true, la ruta debe existir
#   -Type        'File' | 'Directory' | 'Any'
#   -Extension   Extension requerida (ej: '.csv') — solo aplica a Type='File'
#   -AllowEmpty  Si $true, Enter devuelve $null
#
# Devuelve: string con la ruta | $null | $false
# -----------------------------------------------------------------------------
function Read-FilePath {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [bool]   $MustExist  = $true,
        [string] $Type       = 'Any',    # File | Directory | Any
        [string] $Extension  = '',
        [bool]   $AllowEmpty = $false
    )

    $attempts = 0
    while ($attempts -lt $INPUT_MAX_ATTEMPTS) {
        msg_input "$Prompt$(if ($AllowEmpty) { ' (Enter para omitir)' }): "
        $raw = Read-Host

        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($AllowEmpty) { return $null }
            msg_error "La ruta no puede estar vacia."
            $attempts++
            continue
        }

        $raw = $raw.Trim().Trim('"')

        if ($MustExist) {
            if (-not (Test-Path $raw)) {
                msg_error "La ruta no existe: $raw"
                $attempts++
                continue
            }
            if ($Type -eq 'File' -and -not (Test-Path $raw -PathType Leaf)) {
                msg_error "La ruta debe ser un archivo, no un directorio."
                $attempts++
                continue
            }
            if ($Type -eq 'Directory' -and -not (Test-Path $raw -PathType Container)) {
                msg_error "La ruta debe ser un directorio, no un archivo."
                $attempts++
                continue
            }
        }

        if ($Extension -ne '' -and $Type -eq 'File') {
            if (-not $raw.EndsWith($Extension, [System.StringComparison]::OrdinalIgnoreCase)) {
                msg_error "El archivo debe tener extension $Extension"
                $attempts++
                continue
            }
        }

        return $raw
    }

    msg_error "Demasiados intentos fallidos. Operacion cancelada."
    return $false
}

# -----------------------------------------------------------------------------
# Read-StringList
# Solicita una lista de valores ingresados uno por uno.
# El usuario escribe un valor y presiona Enter; linea vacia termina la lista.
#
# Parametros:
#   -Prompt       Texto inicial
#   -ItemPrompt   Texto por cada item (ej: "Extension")
#   -MinItems     Minimo de items requeridos
#   -MaxItems     Maximo de items (0 = sin limite)
#   -Validator    ScriptBlock opcional por cada item
#   -ErrorMsg     Mensaje si falla validacion de item
#   -Transform    ScriptBlock opcional de transformacion por item
#
# Devuelve: string[] | $false
# -----------------------------------------------------------------------------
function Read-StringList {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [string]      $ItemPrompt = "Item",
        [int]         $MinItems   = 1,
        [int]         $MaxItems   = 0,
        [scriptblock] $Validator  = $null,
        [string]      $ErrorMsg   = "Valor no valido.",
        [scriptblock] $Transform  = $null
    )

    Write-Host ""
    msg_info $Prompt
    if ($MaxItems -eq 0) {
        msg_info "Ingresa un item por linea. Presiona Enter en linea vacia para terminar."
    } else {
        msg_info "Ingresa hasta $MaxItems items. Presiona Enter en linea vacia para terminar."
    }
    Write-Separator

    $list = [System.Collections.Generic.List[string]]::new()

    while ($true) {
        if ($MaxItems -gt 0 -and $list.Count -ge $MaxItems) {
            msg_info "Limite de $MaxItems items alcanzado."
            break
        }

        msg_input "$ItemPrompt $($list.Count + 1): "
        $raw = Read-Host

        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($list.Count -lt $MinItems) {
                msg_error "Debes ingresar al menos $MinItems item(s). Continua."
                continue
            }
            break
        }

        $raw = $raw.Trim()

        if ($null -ne $Validator) {
            try { $ok = & $Validator $raw } catch { $ok = $false }
            if (-not $ok) {
                msg_error $ErrorMsg
                continue
            }
        }

        if ($null -ne $Transform) {
            try { $raw = & $Transform $raw } catch {}
        }

        if ($list.Contains($raw)) {
            msg_alert "Item duplicado ignorado: $raw"
            continue
        }

        $list.Add($raw)
        msg_success "Agregado: $raw  (total: $($list.Count))"
    }

    return $list.ToArray()
}