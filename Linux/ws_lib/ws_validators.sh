#!/bin/bash
# =============================================================================
# ws_lib/ws_validators.sh — Validaciones para gestión de servicios web
# Requiere: source lib/ui.sh, source ws_lib/ws_utils.sh
# =============================================================================

http_validar_puerto() {
    local puerto="$1"

    if [[ ! "$puerto" =~ ^[0-9]+$ ]]; then
        msg_error "El puerto debe ser un numero entero positivo"
        msg_info "Ejemplos validos: 80, 8080, 8888"
        return 1
    fi

    if (( puerto == 0 )); then
        msg_error "El puerto 0 esta reservado por el sistema operativo"
        return 1
    fi

    if (( puerto < 1 || puerto > 65535 )); then
        msg_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return 1
    fi

    if (( puerto < 1024 )); then
        msg_alert "El puerto $puerto es un puerto privilegiado (requiere root)"
        msg_info "Se recomienda usar puertos >= 1024 para servicios de prueba"
    fi

    local reservado
    for reservado in "${HTTP_PUERTOS_RESERVADOS[@]}"; do
        if (( puerto == reservado )); then
            msg_error "El puerto $puerto esta reservado para otro servicio del sistema"
            msg_info "Puertos reservados: ${HTTP_PUERTOS_RESERVADOS[*]}"
            return 1
        fi
    done

    if http_puerto_en_uso "$puerto"; then
        local proceso_ocupante
        proceso_ocupante=$(http_quien_usa_puerto "$puerto")
        if echo "$proceso_ocupante" | grep -qE "(^|/)(httpd|nginx|tomcat)$"; then
            msg_alert "Puerto $puerto en uso por '${proceso_ocupante}' (servicio HTTP)"
            msg_info "Se aceptara — el instalador sobreescribira la configuracion"
            msg_success "Puerto $puerto aceptado"
            return 0
        fi
        msg_error "El puerto $puerto ya esta en uso por: ${proceso_ocupante}"
        msg_info "Use 'ss -tlnp' para ver todos los puertos activos"
        return 1
    fi

    msg_success "Puerto $puerto disponible"
    return 0
}

http_validar_puerto_cambio() {
    local puerto_nuevo="$1"
    local puerto_actual="$2"

    if [[ ! "$puerto_nuevo" =~ ^[0-9]+$ ]]; then
        msg_error "El puerto debe ser un numero entero positivo"
        return 1
    fi

    if (( puerto_nuevo == 0 )); then
        msg_error "El puerto 0 esta reservado por el sistema operativo"
        return 1
    fi

    if (( puerto_nuevo < 1 || puerto_nuevo > 65535 )); then
        msg_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return 1
    fi

    if [[ "$puerto_nuevo" == "$puerto_actual" ]]; then
        msg_alert "El puerto nuevo ($puerto_nuevo) es igual al actual"
        msg_info "Seleccione un puerto diferente al actual ($puerto_actual)"
        return 1
    fi

    local reservado
    for reservado in "${HTTP_PUERTOS_RESERVADOS[@]}"; do
        if (( puerto_nuevo == reservado )); then
            msg_error "El puerto $puerto_nuevo esta reservado para otro servicio"
            return 1
        fi
    done

    if http_puerto_en_uso "$puerto_nuevo"; then
        local proceso_ocupante
        proceso_ocupante=$(http_quien_usa_puerto "$puerto_nuevo")
        msg_error "El puerto $puerto_nuevo ya esta en uso por: ${proceso_ocupante}"
        return 1
    fi

    msg_success "Puerto $puerto_nuevo disponible para el cambio"
    return 0
}

http_validar_servicio() {
    local entrada="$1"

    if [[ -z "$entrada" ]]; then
        msg_error "Debe seleccionar un servicio"
        msg_info "Opciones: 1) Apache (httpd)  2) Nginx  3) Tomcat"
        return 1
    fi

    local entrada_lower="${entrada,,}"
    case "$entrada_lower" in
        1|apache|httpd) ;;
        2|nginx) ;;
        3|tomcat) ;;
        iis|"apache win"|"nginx win")
            msg_error "El servicio '$entrada' es exclusivo de Windows"
            msg_info "En Fedora Linux los servicios disponibles son: Apache, Nginx, Tomcat"
            return 1
            ;;
        *)
            msg_error "Servicio no reconocido: '$entrada'"
            msg_info "Servicios disponibles en Linux:"
            echo "    1) Apache (httpd) — servidor web clasico"
            echo "    2) Nginx          — servidor web / proxy inverso"
            echo "    3) Tomcat         — servidor de aplicaciones Java"
            return 1
            ;;
    esac

    return 0
}

http_validar_version() {
    local version_elegida="$1"
    shift
    local versiones_disponibles=("$@")

    if [[ -z "$version_elegida" ]]; then
        msg_error "Debe especificar una version"
        return 1
    fi

    local version
    for version in "${versiones_disponibles[@]}"; do
        [[ "$version" == "$version_elegida" ]] && return 0
    done

    msg_error "Version no encontrada en los repositorios: '$version_elegida'"
    msg_info "Versiones disponibles:"
    for version in "${versiones_disponibles[@]}"; do
        echo "    - $version"
    done
    return 1
}

http_validar_opcion_menu() {
    local opcion="$1"
    local max_opciones="$2"

    if [[ ! "$opcion" =~ ^[0-9]+$ ]]; then
        msg_error "Opcion invalida: '$opcion'"
        msg_info "Ingrese un numero entre 1 y $max_opciones"
        return 1
    fi

    if (( opcion < 1 || opcion > max_opciones )); then
        msg_error "Opcion fuera de rango: $opcion"
        msg_info "Rango valido: 1 a $max_opciones"
        return 1
    fi

    return 0
}

http_validar_indice_version() {
    local indice="$1"
    local total_versiones="$2"

    if [[ ! "$indice" =~ ^[0-9]+$ ]]; then
        msg_error "Debe ingresar el numero de la version deseada"
        return 1
    fi

    if (( indice < 1 || indice > total_versiones )); then
        msg_error "Seleccion fuera de rango: $indice"
        msg_info "Seleccione un numero entre 1 y $total_versiones"
        return 1
    fi

    return 0
}

http_validar_directorio_web() {
    local directorio="$1"
    local usuario_servicio="$2"

    if [[ ! -d "$directorio" ]]; then
        msg_error "El directorio web no existe: $directorio"
        msg_info "Se creara automaticamente durante la instalacion"
        return 1
    fi

    if ! id "$usuario_servicio" &>/dev/null; then
        msg_alert "El usuario del servicio '$usuario_servicio' no existe aun"
        msg_info "Se creara durante la instalacion"
        return 0
    fi

    local propietario_actual
    propietario_actual=$(stat -c '%U' "$directorio" 2>/dev/null)

    if [[ "$propietario_actual" != "$usuario_servicio" && \
          "$propietario_actual" != "root" ]]; then
        msg_alert "El directorio $directorio es propiedad de: $propietario_actual"
        msg_info "Deberia ser propiedad de: $usuario_servicio o root"
    fi

    return 0
}

http_validar_metodo_http() {
    local metodo="$1"

    if [[ -z "$metodo" ]]; then
        msg_error "Debe especificar un metodo HTTP"
        msg_info "Metodos disponibles para restringir: TRACE, TRACK, DELETE, PUT, OPTIONS"
        return 1
    fi

    local metodo_upper="${metodo^^}"
    case "$metodo_upper" in
        GET|POST)
            msg_error "El metodo $metodo_upper es esencial y no debe restringirse"
            return 1
            ;;
        TRACE|TRACK|DELETE|PUT|OPTIONS|PATCH|CONNECT|HEAD) ;;
        *)
            msg_error "Metodo HTTP no reconocido: '$metodo'"
            msg_info "Metodos HTTP estandar: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE, CONNECT"
            return 1
            ;;
    esac

    return 0
}

http_validar_lineas_log() {
    local lineas="$1"

    if [[ ! "$lineas" =~ ^[0-9]+$ ]]; then
        msg_error "El numero de lineas debe ser un entero positivo"
        return 1
    fi

    if (( lineas < 10 )); then
        msg_error "Minimo 10 lineas de log"
        return 1
    fi

    if (( lineas > 500 )); then
        msg_error "Maximo recomendado: 500 lineas (valor: $lineas)"
        msg_info "Para analisis extenso use: sudo journalctl -u httpd --no-pager"
        return 1
    fi

    return 0
}

http_validar_confirmacion() {
    local respuesta="$1"
    local respuesta_lower="${respuesta,,}"

    case "$respuesta_lower" in
        s|si|yes|y) return 0 ;;
        n|no)       return 1 ;;
        "")
            msg_error "Debe responder s (si) o n (no)"
            return 2
            ;;
        *)
            msg_error "Respuesta no reconocida: '$respuesta'"
            msg_info "Responda: s (si) o n (no)"
            return 2
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Exports
# -----------------------------------------------------------------------------

export -f http_validar_puerto
export -f http_validar_puerto_cambio
export -f http_validar_servicio
export -f http_validar_version
export -f http_validar_opcion_menu
export -f http_validar_indice_version
export -f http_validar_directorio_web
export -f http_validar_metodo_http
export -f http_validar_lineas_log
export -f http_validar_confirmacion