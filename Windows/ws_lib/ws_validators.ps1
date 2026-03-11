#
# ws_lib/ws_validators.ps1
# Validaciones específicas para la gestión de servicios HTTP — Windows Server 2022
#
# Equivalente a validatorsHTTP.sh de la práctica Linux.
# Cada función devuelve $true (válido) o $false (inválido) e imprime
# mensajes de error con msg_error / msg_info.
#
# Uso: . "$PSScriptRoot\validatorsHTTP.ps1"
# Requiere: utils.ps1 y utilsHTTP.ps1 cargados antes
#

#Requires -Version 5.1

#
# http_validar_puerto
#
# Valida que un número de puerto sea apropiado para un servicio HTTP.
# Equivalente exacto de http_validar_puerto de validatorsHTTP.sh
#
# Verificaciones:
#   1. Formato — debe ser un entero positivo
#   2. No puede ser 0 (reservado por kernel)
#   3. Rango TCP válido 1-65535
#   4. Puertos privilegiados <1024 — advertencia (no bloqueo)
#   5. No en lista de puertos reservados del sistema
#   6. No ocupado por otro proceso distinto de httpd/nginx/tomcat
#
# Uso: http_validar_puerto "8080"  → $true / $false
#
function http_validar_puerto {
    param([string]$Puerto)

    # ── Verificación 1: Formato — debe ser un entero positivo ────────────────
    if ($Puerto -notmatch '^\d+$') {
        msg_error "El puerto debe ser un numero entero positivo"
        msg_info  "Ejemplos validos: 80, 8080, 8888"
        return $false
    }

    $p = [int]$Puerto

    # ── Verificación 2: Puerto 0 reservado por el kernel ─────────────────────
    if ($p -eq 0) {
        msg_error "El puerto 0 esta reservado por el sistema operativo"
        return $false
    }

    # ── Verificación 3: Rango TCP válido ─────────────────────────────────────
    if ($p -lt 1 -or $p -gt 65535) {
        msg_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return $false
    }

    # ── Verificación 4: Puertos privilegiados <1024 — advertencia ────────────
    if ($p -lt 1024) {
        msg_alert "El puerto $p es un puerto privilegiado (requiere permisos elevados)"
        msg_info    "Se recomienda usar puertos >= 1024 para servicios de prueba"
    }

    # ── Verificación 5: Puertos reservados para otros servicios ──────────────
    if ($Script:HTTP_PUERTOS_RESERVADOS -contains $p) {
        msg_error "El puerto $p esta reservado para otro servicio del sistema"
        msg_info  "Puertos reservados: $($Script:HTTP_PUERTOS_RESERVADOS -join ', ')"
        msg_info  "Elija un puerto diferente"
        return $false
    }

    # ── Verificación 6: Puerto actualmente en uso ─────────────────────────────
    if (http_puerto_en_uso $p) {
        $proceso = http_quien_usa_puerto $p
        # Si el proceso es un servicio HTTP propio no es conflicto real
        if ($proceso -match '(httpd|nginx|tomcat|w3wp|iisexpress)') {
            msg_alert "Puerto $p en uso por '$proceso' (servicio HTTP)"
            msg_info    "Se aceptara — el instalador sobreescribira la configuracion"
            msg_success "Puerto $p aceptado"
            return $true
        }
        msg_error "El puerto $p ya esta en uso por: $proceso"
        msg_info  "Use 'Get-NetTCPConnection -LocalPort $p' para ver detalles"
        msg_info  "Elija un puerto diferente"
        return $false
    }

    msg_success "Puerto $p disponible"
    return $true
}

#
# http_validar_puerto_cambio
#
# Variante para cambio de puerto: acepta el puerto ACTUAL del servicio
# aunque esté en uso (no es conflicto — es el propio servicio).
#
# Uso: http_validar_puerto_cambio "8888" "8080"
#   $1 = nuevo puerto deseado
#   $2 = puerto actual del servicio
#
function http_validar_puerto_cambio {
    param([string]$PuertoNuevo, [string]$PuertoActual)

    if ($PuertoNuevo -notmatch '^\d+$') {
        msg_error "El puerto debe ser un numero entero positivo"
        return $false
    }

    $pn = [int]$PuertoNuevo
    $pa = [int]$PuertoActual

    if ($pn -eq 0) {
        msg_error "El puerto 0 esta reservado por el sistema operativo"
        return $false
    }

    if ($pn -lt 1 -or $pn -gt 65535) {
        msg_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return $false
    }

    # No tiene sentido cambiar al mismo puerto
    if ($pn -eq $pa) {
        msg_alert "El puerto nuevo ($pn) es igual al actual"
        msg_info    "Seleccione un puerto diferente al actual ($pa)"
        return $false
    }

    if ($Script:HTTP_PUERTOS_RESERVADOS -contains $pn) {
        msg_error "El puerto $pn esta reservado para otro servicio"
        return $false
    }

    if (http_puerto_en_uso $pn) {
        $proceso = http_quien_usa_puerto $pn
        msg_error "El puerto $pn ya esta en uso por: $proceso"
        return $false
    }

    msg_success "Puerto $pn disponible para el cambio"
    return $true
}

#
# http_validar_servicio
#
# Valida que la opción ingresada corresponda a un servicio HTTP gestionable
# en Windows Server 2022.
# Equivalente a http_validar_servicio de validatorsHTTP.sh
#
# Uso: http_validar_servicio "2"     → válido (Apache)
#      http_validar_servicio "iis"   → válido
#
function http_validar_servicio {
    param([string]$Entrada)

    if ([string]::IsNullOrWhiteSpace($Entrada)) {
        msg_error "Debe seleccionar un servicio"
        msg_info  "Opciones: 1) IIS  2) Apache (httpd)  3) Nginx  4) Tomcat"
        return $false
    }

    switch ($Entrada.ToLower()) {
        { $_ -in '1', 'iis' } { return $true }
        { $_ -in '2', 'apache', 'httpd' } { return $true }
        { $_ -in '3', 'nginx' } { return $true }
        { $_ -in '4', 'tomcat' } { return $true }
        default {
            msg_error "Servicio no reconocido: '$Entrada'"
            msg_info  "Servicios disponibles en Windows Server:"
            Write-Host  "    1) IIS     — servidor web nativo de Windows"
            Write-Host  "    2) Apache  — httpd para Windows (Chocolatey)"
            Write-Host  "    3) Nginx   — servidor web / proxy inverso"
            Write-Host  "    4) Tomcat  — servidor de aplicaciones Java"
            return $false
        }
    }
}

#
# http_validar_opcion_menu
#
# Valida que una opción numérica de menú esté en el rango 1..MaxOpciones.
# Equivalente a http_validar_opcion_menu de validatorsHTTP.sh
#
# Uso: http_validar_opcion_menu "2" 5  → $true / $false
#
function http_validar_opcion_menu {
    param([string]$Opcion, [int]$MaxOpciones)

    if ($Opcion -notmatch '^\d+$') {
        msg_error "Opcion invalida: '$Opcion'"
        msg_info  "Ingrese un numero entre 1 y $MaxOpciones"
        return $false
    }

    $op = [int]$Opcion
    if ($op -lt 1 -or $op -gt $MaxOpciones) {
        msg_error "Opcion fuera de rango: $op"
        msg_info  "Rango valido: 1 a $MaxOpciones"
        return $false
    }

    return $true
}

#
# http_validar_version
#
# Valida que una versión elegida exista en la lista de versiones disponibles.
# Equivalente a http_validar_version de validatorsHTTP.sh
#
# Uso: http_validar_version "1.28.0" @("1.28.0","1.26.2")  → $true / $false
#
function http_validar_version {
    param([string]$VersionElegida, [string[]]$VersionesDisponibles)

    if ([string]::IsNullOrWhiteSpace($VersionElegida)) {
        msg_error "Debe especificar una version"
        return $false
    }

    if ($VersionesDisponibles -contains $VersionElegida) {
        return $true
    }

    msg_error "La version '$VersionElegida' no esta disponible"
    msg_info  "Versiones disponibles:"
    $VersionesDisponibles | ForEach-Object { Write-Host "    - $_" }
    return $false
}

#
# http_validar_indice_version
#
# Valida que el índice (base 1) esté dentro del total de versiones.
# Equivalente a http_validar_indice_version de validatorsHTTP.sh
#
# Uso: http_validar_indice_version "2" 4  → $true / $false
#
function http_validar_indice_version {
    param([string]$Indice, [int]$TotalVersiones)

    if ($Indice -notmatch '^\d+$') {
        msg_error "Debe ingresar el numero de la version deseada"
        return $false
    }

    $idx = [int]$Indice
    if ($idx -lt 1 -or $idx -gt $TotalVersiones) {
        msg_error "Seleccion fuera de rango: $idx"
        msg_info  "Seleccione un numero entre 1 y $TotalVersiones"
        return $false
    }

    return $true
}

#
# http_validar_metodo_http
#
# Valida que el método HTTP a restringir sea un método estándar reconocido.
# Equivalente a http_validar_metodo_http de validatorsHTTP.sh
#
# Uso: http_validar_metodo_http "TRACE"  → $true / $false
#
function http_validar_metodo_http {
    param([string]$Metodo)

    if ([string]::IsNullOrWhiteSpace($Metodo)) {
        msg_error "Debe especificar un metodo HTTP"
        msg_info  "Metodos disponibles: TRACE, TRACK, DELETE, PUT, OPTIONS, PATCH"
        return $false
    }

    $m = $Metodo.ToUpper()

    switch ($m) {
        { $_ -in 'GET', 'POST' } {
            # Métodos esenciales — nunca deben restringirse
            msg_error "El metodo $m es esencial y no debe restringirse"
            msg_info  "Restriccion tipica: TRACE, TRACK, DELETE, PUT no son necesarios"
            return $false
        }
        { $_ -in 'TRACE', 'TRACK', 'DELETE', 'PUT', 'OPTIONS', 'PATCH', 'CONNECT', 'HEAD' } {
            return $true
        }
        default {
            msg_error "Metodo HTTP no reconocido: '$Metodo'"
            msg_info  "Metodos HTTP estandar: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE, CONNECT"
            return $false
        }
    }
}

#
# http_validar_directorio_web
#
# Valida que un directorio webroot exista y sea accesible.
# Equivalente a http_validar_directorio_web de validatorsHTTP.sh
#
# Uso: http_validar_directorio_web "C:\inetpub\wwwroot" "IUSR"
#
function http_validar_directorio_web {
    param([string]$Directorio, [string]$UsuarioServicio)

    if (-not (Test-Path $Directorio -PathType Container)) {
        msg_error "El directorio web no existe: $Directorio"
        msg_info  "Se creara automaticamente durante la instalacion"
        return $false
    }

    # Verificar que el usuario del servicio existe
    if (-not (check_user_exists $UsuarioServicio)) {
        msg_alert "El usuario del servicio '$UsuarioServicio' no existe aun"
        msg_info    "Se creara durante la instalacion"
        return $true  # No es error crítico en este punto
    }

    return $true
}

#
# http_validar_lineas_log
#
# Valida el número de líneas de log a mostrar (rango: 10-500).
# Equivalente a http_validar_lineas_log de validatorsHTTP.sh
#
# Uso: http_validar_lineas_log "100"  → $true / $false
#
function http_validar_lineas_log {
    param([string]$Lineas)

    if ($Lineas -notmatch '^\d+$') {
        msg_error "El numero de lineas debe ser un entero positivo"
        return $false
    }

    $n = [int]$Lineas
    if ($n -lt 10) {
        msg_error "Minimo 10 lineas de log"
        return $false
    }

    if ($n -gt 500) {
        msg_error "Maximo recomendado: 500 lineas (valor: $n)"
        msg_info  "Para analisis extenso use Get-EventLog o el Visor de Eventos"
        return $false
    }

    return $true
}

#
# http_validar_confirmacion
#
# Valida que la respuesta de confirmación sea s/n.
# Equivalente a http_validar_confirmacion de validatorsHTTP.sh
#
# Retorna: 0=confirmado, 1=negado, 2=inválido
# Uso: $r = http_validar_confirmacion "s"
#
function http_validar_confirmacion {
    param([string]$Respuesta)

    switch ($Respuesta.ToLower()) {
        { $_ -in 's', 'si', 'yes', 'y' } { return 0 }   # Confirmado
        { $_ -in 'n', 'no' } { return 1 }   # Negado — decisión válida
        '' {
            msg_error "Debe responder s (si) o n (no)"
            return 2
        }
        default {
            msg_error "Respuesta no reconocida: '$Respuesta'"
            msg_info  "Responda: s (si) o n (no)"
            return 2
        }
    }
}