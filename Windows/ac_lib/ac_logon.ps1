# =============================================================================
# ac_lib/ac_logon.ps1 — Control de acceso temporal: Logon Hours + GPO
# Uso: . .\ac_lib\ac_logon.ps1
# Requiere: lib/ui.ps1, lib/input.ps1, ac_lib/ac_log.ps1, ac_lib/ac_ad.ps1
# =============================================================================

#Requires -Module ActiveDirectory
#Requires -Module GroupPolicy

# -----------------------------------------------------------------------------
# NOTAS TECNICAS — Formato de 21 bytes para Logon Hours
# -----------------------------------------------------------------------------
# Active Directory representa las horas de logon como un arreglo de 21 bytes
# (168 bits = 7 dias x 24 horas).
#
# Distribucion de bits:
#   Byte 0  bits 0-7  : Dom 00:00-07:59
#   Byte 1  bits 0-7  : Dom 08:00-15:59
#   Byte 2  bits 0-7  : Dom 16:00-23:59
#   Byte 3  bits 0-7  : Lun 00:00-07:59
#   ... y asi sucesivamente (3 bytes por dia)
#
# IMPORTANTE: AD almacena las horas en UTC. El script convierte la hora
# local del servidor al offset UTC correcto usando la zona horaria activa.
#
# Convencion de bits dentro de cada byte:
#   bit 0 (LSB) = primera hora del bloque de 8
#   bit 7 (MSB) = ultima hora del bloque de 8
# -----------------------------------------------------------------------------

# Indice de dias para el arreglo (0=Dom, 1=Lun, ... 6=Sab)
$script:DAY_INDEX = @{
    'Domingo'   = 0
    'Lunes'     = 1
    'Martes'    = 2
    'Miercoles' = 3
    'Jueves'    = 4
    'Viernes'   = 5
    'Sabado'    = 6
}

$script:DAY_NAMES = @('Domingo','Lunes','Martes','Miercoles','Jueves','Viernes','Sabado')

# -----------------------------------------------------------------------------
# Get-UTCOffset
# Devuelve el offset en horas de la zona horaria del servidor respecto a UTC.
# Ejemplo: UTC-7 devuelve -7
# -----------------------------------------------------------------------------
function Get-UTCOffset {
    $tz = [System.TimeZoneInfo]::Local
    return [int]$tz.BaseUtcOffset.TotalHours
}

# -----------------------------------------------------------------------------
# ConvertTo-LogonHoursBytes
# Convierte un rango de horas locales + dias seleccionados al arreglo de
# 21 bytes que requiere Set-ADUser -LogonHours.
#
# Parametros:
#   -StartHour  Hora de inicio permitida (0-23, local)
#   -EndHour    Hora de fin permitida (0-23, local)
#               NOTA: EndHour es EXCLUSIVO (si EndHour=15 permite hasta 14:59)
#               Para permitir hasta las 23:59 usar EndHour=24
#   -Days       Array de nombres de dias permitidos (del $script:DAY_NAMES)
#   -UTCOffset  Offset UTC del servidor (default: auto-detectado)
#
# Devuelve: [byte[]] de 21 elementos
# -----------------------------------------------------------------------------
function ConvertTo-LogonHoursBytes {
    param(
        [Parameter(Mandatory)] [int]      $StartHour,
        [Parameter(Mandatory)] [int]      $EndHour,
        [Parameter(Mandatory)] [string[]] $Days,
        [int] $UTCOffset = (Get-UTCOffset)
    )

    # Inicializar 21 bytes en 0 (todo bloqueado)
    $bytes = [byte[]]::new(21)

    # Funcion interna: activa un bit para una hora local + dia concreto
    # Maneja la conversion UTC y el wraparound de dia
    $setBit = {
        param([int]$localHour, [int]$dayIdx)

        $rawHour = $localHour - $UTCOffset
        $utcHour = $rawHour % 24
        if ($utcHour -lt 0) { $utcHour += 24 }

        $dayShift = 0
        if ($rawHour -lt 0)  { $dayShift = -1 }
        if ($rawHour -ge 24) { $dayShift =  1 }

        $utcDayIdx = (($dayIdx + $dayShift) + 7) % 7

        $byteIndex = ($utcDayIdx * 3) + [Math]::Floor($utcHour / 8)
        $bitIndex  = $utcHour % 8

        $bytes[$byteIndex] = $bytes[$byteIndex] -bor ([byte](1 -shl $bitIndex))
    }

    foreach ($dayName in $Days) {
        if (-not $script:DAY_INDEX.ContainsKey($dayName)) {
            Write-Log WARN "Dia no reconocido ignorado: $dayName"
            continue
        }

        $dayIdx = $script:DAY_INDEX[$dayName]

        # ── Detectar si el rango cruza medianoche ─────────────────────────────
        # Ejemplo: StartHour=15, EndHour=2 → 15:00 a 01:59 del dia siguiente
        # En ese caso dividimos en dos segmentos:
        #   Segmento 1: StartHour ..  23  (en el dia actual)
        #   Segmento 2: 0         .. EndHour (en el dia siguiente, dia+1)
        if ($EndHour -le $StartHour -and $EndHour -ne 0) {
            # Rango cruza medianoche
            # Segmento 1: desde StartHour hasta el final del dia (hora 23 inclusive)
            for ($h = $StartHour; $h -le 23; $h++) {
                & $setBit $h $dayIdx
            }
            # Segmento 2: desde hora 0 hasta EndHour (exclusivo) del dia siguiente
            $nextDayIdx = ($dayIdx + 1) % 7
            for ($h = 0; $h -lt $EndHour; $h++) {
                & $setBit $h $nextDayIdx
            }
        } elseif ($EndHour -eq 0) {
            # EndHour=0 significa hasta el final del dia (23:59)
            for ($h = $StartHour; $h -le 23; $h++) {
                & $setBit $h $dayIdx
            }
        } else {
            # Rango normal dentro del mismo dia
            for ($h = $StartHour; $h -lt $EndHour; $h++) {
                & $setBit $h $dayIdx
            }
        }
    }

    return $bytes
}

# -----------------------------------------------------------------------------
# ConvertFrom-LogonHoursBytes
# Convierte el arreglo de 21 bytes de vuelta a una representacion legible
# en hora local para mostrar al usuario.
#
# Devuelve: string descriptivo por dia con rangos de horas locales
# -----------------------------------------------------------------------------
function ConvertFrom-LogonHoursBytes {
    param(
        [Parameter(Mandatory)] [byte[]] $Bytes,
        [int] $UTCOffset = (Get-UTCOffset)
    )

    if ($Bytes.Count -ne 21) { return "Formato invalido" }

    $result = [System.Collections.Generic.List[string]]::new()

    for ($dayIdx = 0; $dayIdx -lt 7; $dayIdx++) {
        $dayName    = $script:DAY_NAMES[$dayIdx]
        $hoursLocal = [System.Collections.Generic.List[int]]::new()

        for ($utcHour = 0; $utcHour -lt 24; $utcHour++) {
            $byteIndex = ($dayIdx * 3) + [Math]::Floor($utcHour / 8)
            $bitIndex  = $utcHour % 8
            $isSet     = ($Bytes[$byteIndex] -band ([byte](1 -shl $bitIndex))) -ne 0

            if ($isSet) {
                $localHour = ($utcHour + $UTCOffset) % 24
                if ($localHour -lt 0) { $localHour += 24 }
                $hoursLocal.Add($localHour)
            }
        }

        if ($hoursLocal.Count -eq 0) {
            $result.Add("  $($dayName.PadRight(12)): BLOQUEADO")
        } elseif ($hoursLocal.Count -eq 24) {
            $result.Add("  $($dayName.PadRight(12)): 00:00 - 24:00 (todo el dia)")
        } else {
            # Agrupar horas consecutivas en rangos
            $ranges     = [System.Collections.Generic.List[string]]::new()
            $sorted     = $hoursLocal | Sort-Object
            $rangeStart = $sorted[0]
            $prev       = $sorted[0]

            for ($i = 1; $i -lt $sorted.Count; $i++) {
                if ($sorted[$i] -ne ($prev + 1)) {
                    $ranges.Add("$($rangeStart.ToString('D2')):00-$($prev.ToString('D2')):59")
                    $rangeStart = $sorted[$i]
                }
                $prev = $sorted[$i]
            }
            $ranges.Add("$($rangeStart.ToString('D2')):00-$($prev.ToString('D2')):59")
            $result.Add("  $($dayName.PadRight(12)): $($ranges -join ', ')")
        }
    }

    return $result -join "`n"
}

# -----------------------------------------------------------------------------
# Invoke-LogonHoursConfig
# Flujo interactivo para configurar el horario de un grupo o usuario.
# Solicita dias, hora inicio, hora fin; genera y aplica los 21 bytes.
#
# Parametros:
#   -TargetType   'Group' | 'User'
#   -TargetName   Nombre del grupo o usuario AD
#
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Invoke-LogonHoursConfig {
    param(
        [Parameter(Mandatory)] [ValidateSet('Group','User')] [string] $TargetType,
        [Parameter(Mandatory)] [string] $TargetName
    )

    Write-LogSection "Configuracion de Horario de Acceso: $TargetName"

    # ── Zona horaria ──────────────────────────────────────────────────────────
    $currentTZ = [System.TimeZoneInfo]::Local
    $utcOffset = Get-UTCOffset
    $utcSign = if ($utcOffset -ge 0) { '+' } else { '' }
    msg_info "Zona horaria del servidor: $($currentTZ.DisplayName)  (UTC$utcSign$utcOffset)"

    $changeTZ = Read-Confirm `
        -Prompt "Usar esta zona horaria para la conversion" `
        -Default 'S'

    if (-not $changeTZ) {
        $tzList    = [System.TimeZoneInfo]::GetSystemTimeZones() |
                     Select-Object -ExpandProperty DisplayName
        $tzSel     = Read-Selection -Prompt "Selecciona la zona horaria" -Options $tzList
        if ($tzSel -eq $false) { return $false }
        $selectedTZ = [System.TimeZoneInfo]::GetSystemTimeZones() | Where-Object {
            $_.DisplayName -eq $tzSel.Value
        } | Select-Object -First 1
        $utcOffset = [int]$selectedTZ.BaseUtcOffset.TotalHours
        msg_info "Zona horaria seleccionada: $($selectedTZ.DisplayName)"
    }

    # ── Dias de la semana ─────────────────────────────────────────────────────
    Write-Host ""
    $daysSel = Read-MultiSelect `
        -Prompt "Selecciona los dias en que se PERMITE el acceso" `
        -Options $script:DAY_NAMES `
        -MinSelect 1 `
        -AllowAll $true

    if ($daysSel -eq $false) { return $false }
    $selectedDays = $daysSel | ForEach-Object { $_.Value }

    # ── Hora de inicio ────────────────────────────────────────────────────────
    Write-Host ""
    msg_info "Hora de inicio del periodo permitido (hora local, formato 24h)"
    msg_info "Ejemplo: 8 = acceso desde las 08:00"

    $startHour = Read-IntInRange `
        -Prompt "Hora de inicio (0-23)" `
        -Min 0 -Max 23
    if ($startHour -eq $false) { return $false }

    # ── Hora de fin ───────────────────────────────────────────────────────────
    Write-Host ""
    msg_info "Hora de fin del periodo permitido (hora local, formato 24h)"
    msg_info "Ejemplo: 15 = acceso hasta las 14:59  |  24 = hasta las 23:59"

    $endHour = Read-IntInRange `
        -Prompt "Hora de fin (1-24)" `
        -Min 1 -Max 24
    if ($endHour -eq $false) { return $false }

    if ($endHour -le $startHour -and $endHour -ne 24) {
        # Permitir rangos que cruzan medianoche
        $crossMidnight = Read-Confirm `
            -Prompt "La hora de fin ($endHour:00) es menor que la de inicio ($startHour:00). Confirmar rango que cruza medianoche" `
            -Default 'N'
        if (-not $crossMidnight) {
            Write-Log INFO "Configuracion de horario cancelada."
            return $false
        }
    }

    # ── Generar bytes ─────────────────────────────────────────────────────────
    Write-Host ""
    msg_process "Calculando arreglo de 21 bytes (conversion UTC)..."

    # ConvertTo-LogonHoursBytes maneja internamente rangos que cruzan medianoche
    $logonBytes = ConvertTo-LogonHoursBytes `
        -StartHour $startHour `
        -EndHour   $endHour `
        -Days      $selectedDays `
        -UTCOffset $utcOffset

    # ── Vista previa del horario calculado ────────────────────────────────────
    Write-Host ""
    $utcLabel = if ($utcOffset -ge 0) { "UTC+$utcOffset" } else { "UTC$utcOffset" }
    msg_info "Horario calculado (hora local $utcLabel):"
    Write-Separator
    Write-Host (ConvertFrom-LogonHoursBytes -Bytes $logonBytes -UTCOffset $utcOffset)
    Write-Separator

    $confirmBytes = Read-Confirm `
        -Prompt "Aplicar este horario a '$TargetName'" `
        -Default 'S'
    if (-not $confirmBytes) {
        Write-Log INFO "Aplicacion de horario cancelada por el usuario."
        return $false
    }

    # ── Aplicar al objetivo ───────────────────────────────────────────────────
    if ($TargetType -eq 'User') {
        return Set-LogonHoursUser -SamAccountName $TargetName -LogonBytes $logonBytes
    } else {
        return Set-LogonHoursGroup -GroupName $TargetName -LogonBytes $logonBytes
    }
}

# -----------------------------------------------------------------------------
# Set-LogonHoursUser
# Aplica el arreglo de 21 bytes a un usuario individual.
#
# METODO: DirectoryServices.DirectoryEntry en lugar de Set-ADUser.
# Set-ADUser -LogonHours falla cuando el atributo existe con valor vacio en AD
# (comportamiento conocido del modulo ActiveDirectory de PowerShell).
# DirectoryEntry.Properties["logonHours"].Value asigna directamente sin
# importar el estado previo del atributo, resolviendo el problema de raiz.
# -----------------------------------------------------------------------------
function Set-LogonHoursUser {
    param(
        [Parameter(Mandatory)] [string] $SamAccountName,
        [Parameter(Mandatory)] [byte[]] $LogonBytes
    )

    try {
        $dn   = (Get-ADUser -Identity $SamAccountName -ErrorAction Stop).DistinguishedName
        $user = New-Object DirectoryServices.DirectoryEntry("LDAP://$dn")
        $user.Properties["logonHours"].Value = [byte[]]$LogonBytes
        $user.CommitChanges()
        $user.Dispose()
        Write-Log SUCCESS "Horario aplicado al usuario: $SamAccountName"
        return $true
    } catch {
        Write-Log ERROR "No se pudo aplicar horario a '$SamAccountName': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# Set-LogonHoursGroup
# Aplica el arreglo de 21 bytes a todos los miembros de un grupo AD.
# Procesa solo usuarios directos (no grupos anidados).
# -----------------------------------------------------------------------------
function Set-LogonHoursGroup {
    param(
        [Parameter(Mandatory)] [string] $GroupName,
        [Parameter(Mandatory)] [byte[]] $LogonBytes
    )

    Write-Log INFO "Aplicando horario al grupo '$GroupName'..."

    # Obtener miembros del grupo
    $members = $null
    try {
        $members = Get-ADGroupMember -Identity $GroupName -ErrorAction Stop |
                   Where-Object { $_.objectClass -eq 'user' }
    } catch {
        Write-Log ERROR "No se pudo obtener los miembros del grupo '$GroupName': $_"
        return $false
    }

    if ($null -eq $members -or @($members).Count -eq 0) {
        Write-Log WARN "El grupo '$GroupName' no tiene miembros de tipo usuario."
        return $true
    }

    $total   = @($members).Count
    $ok      = 0
    $failed  = 0

    foreach ($member in $members) {
        $result = Set-LogonHoursUser -SamAccountName $member.SamAccountName -LogonBytes $LogonBytes
        if ($result) { $ok++ } else { $failed++ }
    }

    Write-Log INFO "Horario aplicado al grupo '$GroupName': $ok/$total usuarios. Fallidos: $failed"
    return ($failed -eq 0)
}

# -----------------------------------------------------------------------------
# Clear-LogonHours
# Elimina las restricciones de horario de un usuario o todos los miembros
# de un grupo. Util para probar AppLocker sin que LogonHours interfiera.
# Usa DirectoryEntry.Properties["logonHours"].Clear() — mismo metodo que
# Set-LogonHoursUser pero en sentido inverso.
#
# Parametros:
#   -TargetType  'User' | 'Group'
#   -TargetName  SAM del usuario o nombre del grupo
#
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function Clear-LogonHours {
    param(
        [Parameter(Mandatory)] [ValidateSet('User','Group')] [string] $TargetType,
        [Parameter(Mandatory)] [string] $TargetName
    )

    $targets = @()

    if ($TargetType -eq 'User') {
        $targets += $TargetName
    } else {
        try {
            $members = Get-ADGroupMember -Identity $TargetName -ErrorAction Stop |
                       Where-Object { $_.objectClass -eq 'user' }
            $targets  = $members | ForEach-Object { $_.SamAccountName }
        } catch {
            Write-Log ERROR "No se pudo obtener miembros de '$TargetName': $_"
            return $false
        }
    }

    if ($targets.Count -eq 0) {
        Write-Log WARN "No hay usuarios a los que quitar LogonHours."
        return $true
    }

    $ok = 0; $failed = 0
    foreach ($sam in $targets) {
        try {
            $dn   = (Get-ADUser -Identity $sam -ErrorAction Stop).DistinguishedName
            $user = New-Object DirectoryServices.DirectoryEntry("LDAP://$dn")
            $user.Properties["logonHours"].Clear()
            $user.CommitChanges()
            $user.Dispose()
            Write-Log SUCCESS "LogonHours eliminados: $sam"
            $ok++
        } catch {
            Write-Log ERROR "No se pudo limpiar LogonHours de '$sam': $_"
            $failed++
        }
    }

    Write-Log INFO "LogonHours eliminados: $ok/$($targets.Count). Fallidos: $failed"
    return ($failed -eq 0)
}

# -----------------------------------------------------------------------------
# Set-GPLinkEnabled
# Habilita o deshabilita el vinculo de una GPO a un target (OU o dominio)
# sin eliminar la GPO. Util para pruebas: deshabilitar logoff forzado
# para probar AppLocker y volver a habilitarlo despues.
#
# Parametros:
#   -GPOName  Nombre de la GPO
#   -Target   DN del target (OU o dominio, ej: "DC=practica,DC=local")
#   -Enabled  $true para habilitar | $false para deshabilitar
# -----------------------------------------------------------------------------
function Set-GPLinkEnabled {
    param(
        [Parameter(Mandatory)] [string] $GPOName,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [bool]   $Enabled
    )

    $linkEnabled = if ($Enabled) { 'Yes' } else { 'No' }
    try {
        Set-GPLink -Name $GPOName -Target $Target -LinkEnabled $linkEnabled `
                   -ErrorAction Stop
        $estado = if ($Enabled) { 'habilitada' } else { 'deshabilitada' }
        Write-Log SUCCESS "GPO '$GPOName' $estado en '$Target'."
        try { Invoke-GPUpdate -Force -ErrorAction SilentlyContinue } catch {}
        return $true
    } catch {
        Write-Log ERROR "No se pudo cambiar estado del link de '$GPOName': $_"
        return $false
    }
}

# -----------------------------------------------------------------------------
# New-ForceLogoffGPO
# Crea o modifica una GPO para habilitar la configuracion
# "Seguridad de red: cerrar la sesion de los usuarios cuando expire el tiempo
#  de inicio de sesion" y la vincula a una OU.
#
# Esta GPO activa el cierre forzado de sesion activa al vencer el horario.
#
# Parametros:
#   -GPOName   Nombre de la GPO (se crea si no existe)
#   -OuDN      DN de la OU donde vincular la GPO
#
# Devuelve: $true | $false
# -----------------------------------------------------------------------------
function New-ForceLogoffGPO {
    param(
        [Parameter(Mandatory)] [string] $GPOName,
        [Parameter(Mandatory)] [string] $OuDN
    )

    Write-LogSection "Configuracion de GPO: Cierre de Sesion Forzado"

    # Verificar modulo GroupPolicy
    try {
        Import-Module GroupPolicy -ErrorAction Stop
    } catch {
        Write-Log ERROR "El modulo GroupPolicy no esta disponible: $_"
        return $false
    }

    # Crear la GPO si no existe
    $gpo = $null
    try {
        $gpo = Get-GPO -Name $GPOName -ErrorAction Stop
        Write-Log INFO "GPO existente encontrada: $GPOName"
    } catch {
        try {
            $gpo = Invoke-Logged "Crear GPO: $GPOName" {
                New-GPO -Name $GPOName -ErrorAction Stop
            } -PassThru $true
            # Extraer el objeto GPO del resultado
            $gpo = Get-GPO -Name $GPOName -ErrorAction Stop
            Write-Log SUCCESS "GPO creada: $GPOName"
        } catch {
            Write-Log ERROR "No se pudo crear la GPO '$GPOName': $_"
            return $false
        }
    }

    # Configurar la clave de registro que activa el cierre forzado
    # HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters
    # EnableForcedLogoff = 1
    #
    # Y la politica de seguridad equivalente via secedit / GPO Security Settings:
    # Network security: Force logoff when logon hours expire = Enabled
    # Ruta GPO: Computer Configuration\Windows Settings\Security Settings\
    #           Local Policies\Security Options\
    #           "Network security: Force logoff when logon hours expire"
    # Clave registry: HKLM\System\CurrentControlSet\Services\LanmanServer\Parameters!EnableForcedLogoff

    try {
        Invoke-Logged "Configurar EnableForcedLogoff en GPO: $GPOName" {
            Set-GPRegistryValue `
                -Name   $GPOName `
                -Key    'HKLM\System\CurrentControlSet\Services\LanmanServer\Parameters' `
                -ValueName 'EnableForcedLogoff' `
                -Type   DWord `
                -Value  1 `
                -ErrorAction Stop
        } | Out-Null
        Write-Log SUCCESS "Clave EnableForcedLogoff configurada en GPO."
    } catch {
        Write-Log ERROR "No se pudo configurar EnableForcedLogoff en la GPO: $_"
        return $false
    }

    # Segunda clave requerida para Windows 10 — sin esta, LanManServer
    # sola no es suficiente para forzar el logoff en clientes Win10.
    try {
        Invoke-Logged "Configurar ForceLogoffWhenHourExpire en GPO: $GPOName" {
            Set-GPRegistryValue `
                -Name      $GPOName `
                -Key       'HKLM\System\CurrentControlSet\Control\Lsa' `
                -ValueName 'ForceLogoffWhenHourExpire' `
                -Type      DWord `
                -Value     1 `
                -ErrorAction Stop
        } | Out-Null
        Write-Log SUCCESS "Clave ForceLogoffWhenHourExpire configurada en GPO."
    } catch {
        Write-Log WARN "No se pudo configurar ForceLogoffWhenHourExpire (no critico): $_"
    }

    # Vincular la GPO a la OU — verificar primero con Get-GPInheritance
    $alreadyLinked = $false
    try {
        $links = Get-GPInheritance -Target $OuDN -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty GpoLinks |
                 Where-Object { $_.DisplayName -eq $GPOName }
        $alreadyLinked = ($null -ne $links)
    } catch {}

    if ($alreadyLinked) {
        Write-Log WARN "La GPO '$GPOName' ya estaba vinculada a '$OuDN'."
    } else {
        try {
            Invoke-Logged "Vincular GPO '$GPOName' a OU: $OuDN" {
                New-GPLink `
                    -Name        $GPOName `
                    -Target      $OuDN `
                    -LinkEnabled Yes `
                    -ErrorAction Stop
            } | Out-Null
            Write-Log SUCCESS "GPO '$GPOName' vinculada a: $OuDN"
        } catch {
            if ($_ -match 'already') {
                Write-Log WARN "La GPO '$GPOName' ya estaba vinculada a '$OuDN'."
            } else {
                Write-Log ERROR "No se pudo vincular la GPO a '$OuDN': $_"
                return $false
            }
        }
    }

    # Forzar actualizacion de politicas inmediatamente
    try {
        Invoke-GPUpdate -Force -ErrorAction SilentlyContinue
        Write-Log INFO "Politicas de grupo actualizadas (gpupdate /force)."
    } catch {}

    return $true
}

# -----------------------------------------------------------------------------
# Invoke-LogonHoursMenu
# Flujo interactivo principal del modulo.
# Permite configurar horarios por grupo o por usuario individual,
# y gestionar la GPO de cierre de sesion forzado.
# -----------------------------------------------------------------------------
function Invoke-LogonHoursMenu {
    while ($true) {
        Write-Host ""
        draw_header "Control de Acceso Temporal — Logon Hours"

        $sel = Read-Selection `
            -Prompt "Selecciona una opcion" `
            -Options @(
                "Configurar horario para un grupo AD",
                "Configurar horario para un usuario AD",
                "Configurar GPO de cierre de sesion forzado",
                "Ver horario actual de un usuario",
                "Ver horario actual de un grupo"
            ) `
            -AllowBack $true

        if ($null -eq $sel -or $sel -eq $false) { return }

        switch ($sel.Index) {

            # ── Horario por grupo ─────────────────────────────────────────────
            0 {
                $groups = $null
                try {
                    $groups = Get-ADGroup -Filter * -SearchBase $script:AD_DOMAIN_DN `
                              -ErrorAction Stop | Sort-Object Name |
                              Select-Object -ExpandProperty Name
                } catch {
                    Write-Log ERROR "No se pudieron listar los grupos: $_"
                    break
                }
                if (@($groups).Count -eq 0) {
                    Write-Log WARN "No hay grupos en el dominio."
                    break
                }
                $grpSel = Read-Selection -Prompt "Selecciona el grupo" -Options $groups -AllowBack $true
                if ($null -eq $grpSel -or $grpSel -eq $false) { break }
                Invoke-LogonHoursConfig -TargetType 'Group' -TargetName $grpSel.Value
            }

            # ── Horario por usuario ───────────────────────────────────────────
            1 {
                $sam = Read-InputLoop `
                    -Prompt "SamAccountName del usuario" `
                    -Validator {
                        param($v)
                        try { Get-ADUser -Identity $v -ErrorAction Stop | Out-Null; $true }
                        catch { $false }
                    } `
                    -ErrorMsg "Usuario no encontrado en AD."
                if ($sam -eq $false) { break }
                Invoke-LogonHoursConfig -TargetType 'User' -TargetName $sam
            }

            # ── GPO cierre forzado ────────────────────────────────────────────
            2 {
                # Nombre de la GPO
                $gpoName = Read-InputLoop `
                    -Prompt "Nombre de la GPO de cierre de sesion" `
                    -Validator { param($v) $v.Length -ge 3 } `
                    -ErrorMsg "El nombre debe tener al menos 3 caracteres."
                if ($gpoName -eq $false) { break }

                # OU destino
                $ouSel = Get-OUSelection `
                    -Prompt "OU a la que se vinculara la GPO" `
                    -MultiSelect $false
                if ($null -eq $ouSel -or $ouSel -eq $false) { break }

                # Confirmar
                Write-Host ""
                msg_info "GPO     : $gpoName"
                msg_info "OU      : $($ouSel.Name)  [$($ouSel.Value)]"
                $ok = Read-Confirm -Prompt "Confirmar creacion y vinculacion de GPO" -Default 'S'
                if (-not $ok) { break }

                New-ForceLogoffGPO -GPOName $gpoName -OuDN $ouSel.Value
            }

            # ── Ver horario de usuario ────────────────────────────────────────
            3 {
                $sam = Read-InputLoop `
                    -Prompt "SamAccountName del usuario" `
                    -Validator {
                        param($v)
                        try { Get-ADUser -Identity $v -ErrorAction Stop | Out-Null; $true }
                        catch { $false }
                    } `
                    -ErrorMsg "Usuario no encontrado en AD."
                if ($sam -eq $false) { break }

                try {
                    $user  = Get-ADUser -Identity $sam -Properties LogonHours -ErrorAction Stop
                    $bytes = $user.LogonHours
                    if ($null -eq $bytes -or @($bytes).Count -ne 21) {
                        msg_info "El usuario '$sam' no tiene restriccion de horario (acceso las 24h)."
                    } else {
                        Write-Host ""
                        msg_info "Horario de acceso para: $sam"
                        Write-Separator
                        Write-Host (ConvertFrom-LogonHoursBytes -Bytes $bytes)
                        Write-Separator
                    }
                } catch {
                    Write-Log ERROR "No se pudo obtener el horario del usuario '$sam': $_"
                }
            }

            # ── Ver horario de grupo (primer miembro) ─────────────────────────
            4 {
                $groups = $null
                try {
                    $groups = Get-ADGroup -Filter * -SearchBase $script:AD_DOMAIN_DN `
                              -ErrorAction Stop | Sort-Object Name |
                              Select-Object -ExpandProperty Name
                } catch {
                    Write-Log ERROR "No se pudieron listar los grupos: $_"
                    break
                }
                $grpSel = Read-Selection -Prompt "Selecciona el grupo" -Options $groups -AllowBack $true
                if ($null -eq $grpSel -or $grpSel -eq $false) { break }

                try {
                    $members = Get-ADGroupMember -Identity $grpSel.Value -ErrorAction Stop |
                               Where-Object { $_.objectClass -eq 'user' } |
                               Select-Object -First 5

                    if (@($members).Count -eq 0) {
                        msg_info "El grupo '$($grpSel.Value)' no tiene miembros de tipo usuario."
                    } else {
                        foreach ($m in $members) {
                            $user  = Get-ADUser -Identity $m.SamAccountName `
                                     -Properties LogonHours -ErrorAction Stop
                            $bytes = $user.LogonHours
                            Write-Host ""
                            msg_info "Usuario: $($m.SamAccountName)"
                            if ($null -eq $bytes -or @($bytes).Count -ne 21) {
                                msg_info "  Sin restriccion (acceso las 24h)"
                            } else {
                                Write-Host (ConvertFrom-LogonHoursBytes -Bytes $bytes)
                            }
                        }
                        if (@($members).Count -eq 5) {
                            msg_info "(Mostrando primeros 5 miembros)"
                        }
                    }
                } catch {
                    Write-Log ERROR "Error al obtener miembros del grupo: $_"
                }
            }
        }

        msg_pause
    }
}