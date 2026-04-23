# =============================================================================
# ac_lib/ac_log.ps1 - Logger centralizado con niveles y archivo de salida
# Uso: . .\ac_lib\ac_log.ps1   (requiere lib/ui.ps1 cargado antes)
# =============================================================================

# Variable de script para la ruta del log activo
$script:LOG_PATH     = $null
$script:LOG_ENABLED  = $false
$script:LOG_ECHO     = $true    # Si $true, ademas de escribir al log, muestra en consola

# -----------------------------------------------------------------------------
# Initialize-Log
# Inicializa el archivo de log. Debe llamarse antes de cualquier Write-Log.
# Si la ruta no existe, la crea. Si el archivo ya existe, agrega al final.
#
# Parametros:
#   -Path        Ruta completa del archivo de log
#                Si es $null, se solicita al usuario
#   -Silent      Si $true, no muestra el mensaje de confirmacion
#
# Devuelve: $true si el log quedo listo | $false si fallo
# -----------------------------------------------------------------------------
function Initialize-Log {
    param(
        [string] $Path   = $null,
        [bool]   $Silent = $false
    )

    # Si no se paso ruta, solicitarla al usuario
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
        $suggested  = "$PSScriptRoot\..\logs\ac_manager_$timestamp.log"
        $suggested  = [System.IO.Path]::GetFullPath($suggested)

        Write-Host ""
        msg_info "Configuracion del archivo de log"
        Write-Separator
        msg_info "Ruta sugerida: $suggested"
        msg_input "Ruta del archivo de log (Enter para usar sugerida): "
        $input = Read-Host

        $Path = if ([string]::IsNullOrWhiteSpace($input)) { $suggested } else { $input.Trim().Trim('"') }
    }

    # Crear directorio si no existe
    $dir = Split-Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        } catch {
            msg_error "No se pudo crear el directorio de log: $dir"
            msg_error "Detalle: $_"
            return $false
        }
    }

    # Escribir encabezado de sesion
    try {
        $header = @"
================================================================================
  AC Manager - Sesion de log iniciada
  Fecha    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Usuario  : $env:USERNAME
  Maquina  : $env:COMPUTERNAME
  PowerShell: $($PSVersionTable.PSVersion)
================================================================================
"@
        Add-Content -Path $Path -Value $header -Encoding UTF8 -ErrorAction Stop
    } catch {
        msg_error "No se pudo escribir en el archivo de log: $Path"
        msg_error "Detalle: $_"
        return $false
    }

    $script:LOG_PATH    = $Path
    $script:LOG_ENABLED = $true

    if (-not $Silent) {
        msg_success "Log iniciado en: $Path"
    }

    return $true
}

# -----------------------------------------------------------------------------
# Write-Log
# Escribe una entrada en el log con nivel, timestamp y mensaje.
# Si LOG_ECHO es $true, tambien muestra el mensaje en consola via ui.ps1
#
# Parametros:
#   -Level    INFO | WARN | ERROR | SUCCESS | DEBUG | SYSTEM
#   -Message  Texto del mensaje
#   -NoEcho   Si $true, suprime la salida a consola para esta llamada
#
# Uso tipico:
#   Write-Log INFO "Creando OU: $ouName"
#   Write-Log ERROR "Fallo al crear usuario: $userName"
#   Invoke-Cmdlet 2>&1 | ForEach-Object { Write-Log SYSTEM $_ -NoEcho $true }
# -----------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory, Position=0)]
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG','SYSTEM')]
        [string] $Level,

        [Parameter(Mandatory, Position=1)]
        [string] $Message,

        [bool] $NoEcho = $false
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $levelPad  = $Level.PadRight(7)
    $line      = "[$timestamp] [$levelPad] $Message"

    # Escribir al archivo si el log esta activo
    if ($script:LOG_ENABLED -and $script:LOG_PATH) {
        try {
            Add-Content -Path $script:LOG_PATH -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            # No fallar silenciosamente - advertir en consola
            Write-Host "[ WARN  ] No se pudo escribir en el log: $_" -ForegroundColor Yellow
        }
    }

    # Eco a consola (si aplica)
    if ($script:LOG_ECHO -and -not $NoEcho) {
        switch ($Level) {
            'INFO'    { msg_info    $Message }
            'WARN'    { msg_alert   $Message }
            'ERROR'   { msg_error   $Message }
            'SUCCESS' { msg_success $Message }
            'DEBUG'   { Write-Host "[ DEBUG ] $Message" -ForegroundColor Magenta }
            'SYSTEM'  { } # Salida tecnica suprimida de consola, solo va al log
        }
    }
}

# -----------------------------------------------------------------------------
# Invoke-Logged
# Ejecuta un ScriptBlock y redirige toda su salida (stdout + stderr) al log
# con nivel SYSTEM. La consola solo recibe el mensaje de inicio/fin limpio.
#
# Parametros:
#   -Description  Descripcion de la operacion (para consola y log)
#   -ScriptBlock  Bloque de codigo a ejecutar
#   -PassThru     Si $true, devuelve la salida del bloque ademas de logearla
#
# Devuelve: $true si el bloque no lanzo excepcion | $false si fallo
#           Si PassThru, devuelve el resultado del bloque
# -----------------------------------------------------------------------------
function Invoke-Logged {
    param(
        [Parameter(Mandatory)] [string]      $Description,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [bool] $PassThru = $false
    )

    Write-Log INFO "INICIO: $Description"

    try {
        $output = & $ScriptBlock 2>&1
    } catch {
        Write-Log ERROR "EXCEPCION en '$Description': $_"
        return $false
    }

    # Redirigir toda salida al log con nivel SYSTEM
    foreach ($line in $output) {
        if ($line -is [System.Management.Automation.ErrorRecord]) {
            Write-Log SYSTEM "  [stderr] $line" -NoEcho $true
        } else {
            Write-Log SYSTEM "  [stdout] $line" -NoEcho $true
        }
    }

    Write-Log SUCCESS "FIN: $Description"

    if ($PassThru) { return $output }
    return $true
}

# -----------------------------------------------------------------------------
# Write-LogSection
# Escribe un separador de seccion en el log para facilitar la lectura.
#
# Parametros:
#   -Title   Titulo de la seccion
# -----------------------------------------------------------------------------
function Write-LogSection {
    param([string] $Title)

    $line = "--- $Title $('─' * [Math]::Max(0, 60 - $Title.Length)) "

    if ($script:LOG_ENABLED -and $script:LOG_PATH) {
        try {
            Add-Content -Path $script:LOG_PATH -Value "" -Encoding UTF8
            Add-Content -Path $script:LOG_PATH -Value $line -Encoding UTF8
            Add-Content -Path $script:LOG_PATH -Value "" -Encoding UTF8
        } catch {}
    }

    Write-Host ""
    Write-Separator
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Separator
}

# -----------------------------------------------------------------------------
# Get-LogPath
# Devuelve la ruta del log activo o $null si no esta inicializado.
# -----------------------------------------------------------------------------
function Get-LogPath {
    return $script:LOG_PATH
}

# -----------------------------------------------------------------------------
# Show-Log
# Muestra el contenido del log activo en la consola (tail).
#
# Parametros:
#   -Lines   Numero de ultimas lineas a mostrar (default: 50)
# -----------------------------------------------------------------------------
function Show-Log {
    param([int] $Lines = 50)

    if (-not $script:LOG_ENABLED -or -not $script:LOG_PATH) {
        msg_alert "El log no esta inicializado."
        return
    }

    if (-not (Test-Path $script:LOG_PATH)) {
        msg_alert "El archivo de log no existe: $script:LOG_PATH"
        return
    }

    Write-Host ""
    msg_info "Ultimas $Lines lineas de: $script:LOG_PATH"
    Write-Separator
    Get-Content $script:LOG_PATH -Tail $Lines | ForEach-Object {
        # Colorear segun nivel
        $color = switch -Regex ($_) {
            '\[SUCCESS\]' { 'Green'   }
            '\[ERROR  \]' { 'Red'     }
            '\[WARN   \]' { 'Yellow'  }
            '\[DEBUG  \]' { 'Magenta' }
            '\[SYSTEM \]' { 'DarkGray'}
            default       { 'Gray'    }
        }
        Write-Host $_ -ForegroundColor $color
    }
    Write-Separator
}

# -----------------------------------------------------------------------------
# Close-Log
# Escribe el pie de sesion y cierra el log limpiamente.
# Llamar al salir de ac_manager.ps1
# -----------------------------------------------------------------------------
function Close-Log {
    if (-not $script:LOG_ENABLED -or -not $script:LOG_PATH) { return }

    $footer = @"

================================================================================
  Sesion finalizada: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
================================================================================
"@

    try {
        Add-Content -Path $script:LOG_PATH -Value $footer -Encoding UTF8
    } catch {}

    $script:LOG_ENABLED = $false
    msg_info "Log cerrado: $script:LOG_PATH"
}