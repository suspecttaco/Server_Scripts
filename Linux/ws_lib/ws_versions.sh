#!/bin/bash
# =============================================================================
# ws_lib/ws_versions.sh — Gestión de versiones de servicios web (upgrade/downgrade)
# Requiere: source lib/ui.sh, source ws_lib/ws_utils.sh, source ws_lib/ws_validators.sh
#           source ws_lib/ws_status.sh, source ws_lib/ws_install.sh, source ws_lib/ws_config.sh
# =============================================================================


# _http_comparar_versiones  (interna)
#
# Compara dos strings de versión usando 'sort -V' (version sort de GNU).
# Devuelve en stdout la relación entre ambas.
#
# Uso: _http_comparar_versiones "2.4.58" "2.4.62"
# Retorna:
#   0 y stdout "menor"  si $1 < $2
#   0 y stdout "igual"  si $1 == $2
#   0 y stdout "mayor"  si $1 > $2

_http_comparar_versiones() {
    local v1="$1"
    local v2="$2"

    if [[ "$v1" == "$v2" ]]; then
        echo "igual"
        return 0
    fi

    # sort -V ordena correctamente versiones semver: 2.4.9 < 2.4.10
    # El primer resultado de 'sort -V' es la versión menor
    local menor
    menor=$(printf "%s\n%s" "$v1" "$v2" | sort -V | head -1)

    if [[ "$menor" == "$v1" ]]; then
        echo "menor"
    else
        echo "mayor"
    fi
}


# _http_versiones_superiores  (interna)
#
# A partir de la lista completa de versiones disponibles en dnf, filtra
# y devuelve solo las que son numéricamente superiores a la versión actual.
# Usada por http_upgrade_servicio para presentar opciones reales de upgrade.
#
# Uso: _http_versiones_superiores "httpd" "2.4.58-2.fc40" mi_array
#   $1 = servicio
#   $2 = versión actual instalada (formato VERSION-RELEASE)
#   $3 = nombre del array destino

_http_versiones_superiores() {
    local servicio="$1"
    local version_actual="$2"
    local _array_destino="$3"

    # Obtener todas las versiones disponibles del repositorio
    local todas_versiones=()
    if ! http_consultar_versiones "$servicio" todas_versiones; then
        return 1
    fi

    # Extraer solo la parte VERSION del string VERSION-RELEASE para comparar
    # dnf devuelve "2.4.62-1.fc41" — solo necesitamos "2.4.62" para sort -V
    local ver_actual_limpia
    ver_actual_limpia=$(echo "$version_actual" | cut -d'-' -f1)

    local superiores=()
    local ver
    for ver in "${todas_versiones[@]}"; do
        local ver_limpia
        ver_limpia=$(echo "$ver" | cut -d'-' -f1)

        local relacion
        relacion=$(_http_comparar_versiones "$ver_limpia" "$ver_actual_limpia")

        if [[ "$relacion" == "mayor" ]]; then
            superiores+=("$ver")
        fi
    done

    local -n _ref_sup="$_array_destino"
    _ref_sup=("${superiores[@]}")
    return 0
}


# _http_versiones_inferiores  (interna)
#
# Igual que _http_versiones_superiores pero filtra las versiones menores.
# Usada por http_downgrade_servicio.

_http_versiones_inferiores() {
    local servicio="$1"
    local version_actual="$2"
    local _array_destino="$3"

    local todas_versiones=()
    if ! http_consultar_versiones "$servicio" todas_versiones; then
        return 1
    fi

    local ver_actual_limpia
    ver_actual_limpia=$(echo "$version_actual" | cut -d'-' -f1)

    local inferiores=()
    local ver
    for ver in "${todas_versiones[@]}"; do
        local ver_limpia
        ver_limpia=$(echo "$ver" | cut -d'-' -f1)

        local relacion
        relacion=$(_http_comparar_versiones "$ver_limpia" "$ver_actual_limpia")

        if [[ "$relacion" == "menor" ]]; then
            inferiores+=("$ver")
        fi
    done

    local -n _ref_inf="$_array_destino"
    _ref_inf=("${inferiores[@]}")
    return 0
}


# http_ver_version_instalada
#
# Panel completo de información sobre la versión actualmente instalada.
# Muestra:
#   - Versión instalada (rpm -q)
#   - Fecha de instalación del paquete
#   - Puerto activo en este momento
#   - Estado del servicio (activo/inactivo)
#   - Si existe una versión más reciente disponible en dnf
#
# Uso: http_ver_version_instalada

http_ver_version_instalada() {
    clear
    draw_header "Version Instalada de Servicios HTTP"

    local servicios=("httpd" "nginx" "tomcat")
    local nombres=("Apache (httpd)" "Nginx" "Tomcat")

    local i
    for i in "${!servicios[@]}"; do
        local svc="${servicios[$i]}"
        local nombre="${nombres[$i]}"
        local paquete
        paquete=$(http_nombre_paquete "$svc")

        echo ""
        echo -e "  ${CYAN}▶ ${nombre}${NC}"
        separator

        # Verificar si está instalado
        if ! rpm -q "$paquete" &>/dev/null; then
            printf "  ${GRAY}[--]${NC}  No instalado\n"
            echo ""
            continue
        fi

        #  Versión completa del paquete 
        local version_completa
        version_completa=$(rpm -q --queryformat \
            "%{VERSION}-%{RELEASE}" "$paquete" 2>/dev/null)
        printf "  ${GREEN}[OK]${NC}  Version instalada : %s\n" "$version_completa"

        #  Fecha de instalación 
        # rpm -q --queryformat con %{INSTALLTIME:date} devuelve fecha legible
        local fecha_instalacion
        fecha_instalacion=$(rpm -q --queryformat \
            "%{INSTALLTIME:date}" "$paquete" 2>/dev/null)
        printf "        Instalado el      : %s\n" "$fecha_instalacion"

        #  Estado del servicio 
        local nombre_systemd
        nombre_systemd=$(http_nombre_systemd "$svc")

        if check_service_active "$nombre_systemd"; then
            local pid
            pid=$(sudo systemctl show "$nombre_systemd" \
                  --property=MainPID --value 2>/dev/null)
            printf "        Servicio          : ${GREEN}ACTIVO${NC} (PID: %s)\n" "$pid"
        else
            printf "        Servicio          : ${YELLOW}INACTIVO${NC}\n"
        fi

        #  Puerto activo 
        local puerto_activo
        puerto_activo=$(_http_obtener_puerto_activo "$nombre_systemd")

        if [[ -n "$puerto_activo" ]]; then
            printf "        Puerto activo     : %s/tcp\n" "$puerto_activo"
        else
            # Leer del archivo de config aunque el servicio esté caído
            local puerto_config
            puerto_config=$(_http_leer_puerto_config "$svc")
            printf "        Puerto en config  : %s/tcp (servicio inactivo)\n" \
                   "${puerto_config:-desconocido}"
        fi

        #  Comparar con la versión más reciente en repositorios 
        # Solo si hay conexión — dnf puede ser lento, avisamos al usuario
        msg_info "  Consultando ultima version disponible en repositorios..."

        local ultima_disponible
        ultima_disponible=$(dnf list --showduplicates "$paquete" 2>/dev/null \
                           | grep "^${paquete}" \
                           | awk '{print $2}' \
                           | sort -Vr \
                           | head -1)

        if [[ -n "$ultima_disponible" ]]; then
            local version_limpia_actual
            version_limpia_actual=$(echo "$version_completa" | cut -d'-' -f1)
            local version_limpia_ultima
            version_limpia_ultima=$(echo "$ultima_disponible" | cut -d'-' -f1)

            local relacion
            relacion=$(_http_comparar_versiones \
                       "$version_limpia_actual" "$version_limpia_ultima")

            case "$relacion" in
                igual)
                    printf "        ${GREEN}Al dia${NC} — ultima version: %s\n" \
                           "$ultima_disponible"
                    ;;
                menor)
                    printf "        ${YELLOW}Actualizacion disponible${NC}: %s → %s\n" \
                           "$version_completa" "$ultima_disponible"
                    msg_info "  Use Grupo D opcion 2) para actualizar"
                    ;;
                mayor)
                    printf "        ${CYAN}Version mas reciente que el repositorio${NC}: %s\n" \
                           "$version_completa"
                    ;;
            esac
        else
            printf "        Version en repo   : no disponible (sin conexion o paquete no encontrado)\n"
        fi

        echo ""
    done

    separator
}


# _http_ejecutar_cambio_version  (interna)
#
# Orquestador común para upgrade y downgrade.
# Ambas operaciones siguen el mismo flujo — solo cambia el comando dnf
# ('upgrade' vs 'downgrade') y el array de versiones a mostrar.
#
# Secuencia:
#   1. Leer versión y puerto actuales (para preservarlos)
#   2. Mostrar versiones disponibles (superiores o inferiores)
#   3. Seleccionar versión destino
#   4. Backup del archivo de configuración
#   5. Ejecutar dnf upgrade/downgrade silencioso
#   6. Verificar que la versión cambió realmente
#   7. Reaplicar el puerto (dnf puede resetear la config)
#   8. Reiniciar el servicio
#   9. Verificar respuesta HTTP
#  10. Actualizar index.html con la nueva versión
#
# Uso: _http_ejecutar_cambio_version "httpd" "upgrade" versiones_array
#   $1 = servicio
#   $2 = "upgrade" | "downgrade"
#   $3 = nombre del array de versiones disponibles para ese sentido

_http_ejecutar_cambio_version() {
    local servicio="$1"
    local operacion="$2"       # "upgrade" o "downgrade"
    local _nombre_array="$3"

    local -n _versiones_disp="$_nombre_array"
    local total="${#_versiones_disp[@]}"

    # Sin versiones disponibles para la operación solicitada
    if (( total == 0 )); then
        if [[ "$operacion" == "upgrade" ]]; then
            msg_info "No hay versiones superiores disponibles en los repositorios"
            msg_info "El servicio ya esta en la version mas reciente"
        else
            msg_info "No hay versiones anteriores disponibles en los repositorios"
            msg_info "Esta es la version mas antigua disponible"
        fi
        return 0
    fi

    #  Paso 1: Leer estado actual 
    local paquete
    paquete=$(http_nombre_paquete "$servicio")

    local version_actual
    version_actual=$(rpm -q --queryformat \
                     "%{VERSION}-%{RELEASE}" "$paquete" 2>/dev/null)

    local puerto_actual
    puerto_actual=$(_http_leer_puerto_config "$servicio")
    [[ -z "$puerto_actual" ]] && {
        case "$servicio" in
            httpd)  puerto_actual="$HTTP_PUERTO_DEFAULT_APACHE" ;;
            nginx)  puerto_actual="$HTTP_PUERTO_DEFAULT_NGINX"  ;;
            tomcat) puerto_actual="$HTTP_PUERTO_DEFAULT_TOMCAT" ;;
        esac
    }

    msg_info "Version actual    : ${version_actual}"
    msg_info "Puerto preservado : ${puerto_actual}/tcp"
    echo ""

    #  Paso 2: Mostrar versiones disponibles 
    local etiqueta_op
    [[ "$operacion" == "upgrade" ]] && etiqueta_op="superiores" \
                                    || etiqueta_op="anteriores"

    msg_info "Versiones ${etiqueta_op} disponibles en repositorios:"
    echo ""
    printf "  %-5s %-35s\n" "NUM" "VERSION"
    separator

    local i
    for i in "${!_versiones_disp[@]}"; do
        printf "  %-5s %-35s\n" "$(( i + 1 )))" "${_versiones_disp[$i]}"
    done

    echo ""

    #  Paso 3: Seleccionar versión destino 
    local indice_elegido
    while true; do
        input_read "Seleccione version destino [1-${total}]" indice_elegido
        if http_validar_indice_version "$indice_elegido" "$total"; then
            break
        fi
        echo ""
    done

    local version_destino="${_versiones_disp[$(( indice_elegido - 1 ))]}"

    echo ""
    msg_alert "Se realizara ${operacion} de ${servicio}:"
    echo "    Version actual  : ${version_actual}"
    echo "    Version destino : ${version_destino}"
    echo "    Puerto          : ${puerto_actual}/tcp (se preservara)"
    echo ""

    local confirmacion
    while true; do
        input_read "Confirmar ${operacion}? [s/n]" confirmacion
        http_validar_confirmacion "$confirmacion"
        local rc=$?
        (( rc == 0 )) && break
        (( rc == 1 )) && {
            msg_info "${operacion^} cancelado"
            sleep 1
            return 0
        }
        echo ""
    done

    separator
    echo ""

    #  Paso 4: Backup del archivo de configuración 
    local archivo_conf
    archivo_conf=$(http_get_conf_archivo "$servicio")

    msg_info "PASO 1/5 — Backup de configuracion"
    http_crear_backup "$archivo_conf"
    echo ""

    #  Paso 5: Ejecutar dnf upgrade o downgrade 
    msg_info "PASO 2/5 — Ejecutando dnf ${operacion} a ${version_destino}"
    echo ""

    # dnf upgrade/downgrade con versión específica:
    #   dnf upgrade -y httpd-2.4.62-1.fc41
    #   dnf downgrade -y httpd-2.4.57-2.fc40
    # --best: usar la mejor coincidencia disponible
    # --allowerasing: permitir reemplazar conflictos si es necesario
    if ! sudo dnf "${operacion}" -y --best \
         "${paquete}-${version_destino}" 2>&1 \
         | while IFS= read -r linea; do echo "    $linea"; done; then
        msg_error "Error durante el ${operacion} — restaurando configuracion"
        http_restaurar_backup "$archivo_conf"
        return 1
    fi

    echo ""

    #  Paso 6: Verificar que la versión cambió realmente 
    msg_info "PASO 3/5 — Verificando version instalada tras ${operacion}"

    local version_nueva
    version_nueva=$(rpm -q --queryformat \
                    "%{VERSION}-%{RELEASE}" "$paquete" 2>/dev/null)

    if [[ "$version_nueva" == "$version_actual" ]]; then
        msg_alert "La version no cambio tras el ${operacion}"
        msg_info "dnf puede haber omitido el cambio si ya estaba satisfecho"
        msg_info "Version reportada: ${version_nueva}"
    else
        msg_success "Version actualizada: ${version_actual} → ${version_nueva}"
    fi

    echo ""

    #  Paso 7: Reaplicar puerto 
    # dnf upgrade/downgrade puede sobrescribir el archivo de configuración
    # con el que viene el nuevo paquete, reseteando el puerto al default.
    # Reaplicamos el puerto guardado SIEMPRE para garantizar consistencia.
    msg_info "PASO 4/5 — Reaplying puerto ${puerto_actual} en configuracion"
    _http_configurar_puerto_inicial "$servicio" "$puerto_actual"
    echo ""

    #  Paso 8: Reiniciar el servicio 
    msg_info "PASO 5/5 — Reiniciando servicio"
    if ! http_reiniciar_servicio "$servicio"; then
        msg_error "El servicio no levanto tras el ${operacion}"
        msg_alert "Restaurando configuracion anterior..."
        http_restaurar_backup "$archivo_conf"

        # Intentar volver a la version anterior
        msg_info "Intentando restaurar version ${version_actual}..."
        sudo dnf "${operacion}" -y --best \
             "${paquete}-${version_actual}" 2>/dev/null
        http_reiniciar_servicio "$servicio"
        return 1
    fi

    echo ""

    #  Paso 9: Verificar respuesta HTTP 
    msg_info "Verificando respuesta HTTP en puerto ${puerto_actual}..."
    sleep 2

    if ! http_verificar_respuesta "$servicio" "$puerto_actual"; then
        msg_alert "El servicio no responde — puede necesitar mas tiempo"
        msg_info "Verifique manualmente: curl -I http://localhost:${puerto_actual}"
    fi

    echo ""

    #  Paso 10: Actualizar index.html 
    http_crear_index "$servicio" "$version_nueva" "$puerto_actual"

    echo ""
    separator
    msg_success "${operacion^} completado: ${version_actual} → ${version_nueva}"
    echo "    Servicio : ${servicio}"
    echo "    Puerto   : ${puerto_actual}/tcp (preservado)"
    separator
}

# 
# http_upgrade_servicio
#
# Actualiza un servicio HTTP a una versión superior disponible en dnf.
# Muestra solo versiones numéricamente mayores a la actual.
# Si ya está en la última versión, informa al usuario sin hacer nada.
#
# Uso: http_upgrade_servicio

http_upgrade_servicio() {
    clear
    draw_header "Upgrade de Servicio HTTP"

    msg_info "Actualiza el servicio a una version superior disponible en"
    msg_info "los repositorios de Fedora. Preserva el puerto configurado."
    echo ""

    # Solo servicios instalados
    local servicio
    if ! _http_seleccionar_servicio_instalado servicio; then
        return 1
    fi

    http_draw_servicio_header "$servicio" "Upgrade de Version"

    msg_info "Consultando versiones superiores disponibles..."
    echo ""

    # Obtener versión actual para filtrar
    local paquete
    paquete=$(http_nombre_paquete "$servicio")
    local version_actual
    version_actual=$(rpm -q --queryformat \
                     "%{VERSION}-%{RELEASE}" "$paquete" 2>/dev/null)

    # Filtrar solo versiones superiores
    local versiones_upgrade=()
    if ! _http_versiones_superiores "$servicio" "$version_actual" \
                                    versiones_upgrade; then
        msg_error "No se pudo obtener versiones del repositorio"
        return 1
    fi

    # Delegar al orquestador común
    _http_ejecutar_cambio_version "$servicio" "upgrade" versiones_upgrade
}


# http_downgrade_servicio
#
# Retrocede un servicio HTTP a una versión anterior disponible en dnf.
# Muestra solo versiones numéricamente menores a la actual.
# Útil cuando una actualización introduce regresiones.
#
# Uso: http_downgrade_servicio

http_downgrade_servicio() {
    clear
    draw_header "Downgrade de Servicio HTTP"

    msg_alert "El downgrade retrocede el servicio a una version anterior."
    msg_alert "Use esto solo si la version actual presenta problemas."
    echo ""

    local servicio
    if ! _http_seleccionar_servicio_instalado servicio; then
        return 1
    fi

    http_draw_servicio_header "$servicio" "Downgrade de Version"

    msg_info "Consultando versiones anteriores disponibles..."
    echo ""

    local paquete
    paquete=$(http_nombre_paquete "$servicio")
    local version_actual
    version_actual=$(rpm -q --queryformat \
                     "%{VERSION}-%{RELEASE}" "$paquete" 2>/dev/null)

    # Filtrar solo versiones inferiores
    local versiones_downgrade=()
    if ! _http_versiones_inferiores "$servicio" "$version_actual" \
                                    versiones_downgrade; then
        msg_error "No se pudo obtener versiones del repositorio"
        return 1
    fi

    # Delegar al orquestador común
    _http_ejecutar_cambio_version "$servicio" "downgrade" versiones_downgrade
}


# http_menu_versiones
#
# Submenú del Grupo D. Llamado desde http_menu_configurar (Grupo C, opción 4).
# Presenta las tres operaciones de gestión de versiones.
#
# Uso: llamado desde http_menu_configurar cuando el usuario elige opcion 4

http_menu_versiones() {
    while true; do
        clear
        draw_header "Gestion de Versiones HTTP"
        echo ""
        echo -e "  ${BLUE}1)${NC} Ver version instalada y disponibilidad de actualizaciones"
        echo -e "  ${BLUE}2)${NC} Upgrade   — actualizar a version superior"
        echo -e "  ${BLUE}3)${NC} Downgrade — retroceder a version anterior"
        echo -e "  ${BLUE}4)${NC} Volver al menu de configuracion"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1)
                http_ver_version_instalada
                echo ""
                msg_pause
                ;;
            2)
                http_upgrade_servicio
                echo ""
                msg_pause
                ;;
            3)
                http_downgrade_servicio
                echo ""
                msg_pause
                ;;
            4)
                return 0
                ;;
            *)
                msg_error "Opcion invalida. Seleccione entre 1 y 4"
                sleep 2
                ;;
        esac
    done
}


#   EXPORTAR FUNCIONES DEL GRUPO D


export -f http_ver_version_instalada
export -f http_upgrade_servicio
export -f http_downgrade_servicio
export -f http_menu_versiones
export -f _http_comparar_versiones
export -f _http_versiones_superiores
export -f _http_versiones_inferiores
export -f _http_ejecutar_cambio_version