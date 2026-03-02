#!/bin/bash
# =============================================================================
# ftp_lib/ftp_groups.sh — CRUD de grupos FTP y permisos de directorios de grupo
# =============================================================================

_cargar_grupos() {
    FTP_GROUPS=()
    [ ! -f "$VSFTPD_GROUPS_FILE" ] && return 0
    while IFS= read -r linea; do
        linea="${linea%%#*}"
        linea="${linea//[[:space:]]/}"
        [ -z "$linea" ] && continue
        FTP_GROUPS+=("$linea")
    done < "$VSFTPD_GROUPS_FILE"
}

_guardar_grupos() {
    mkdir -p "$VSFTPD_DIR"
    printf '%s\n' "${FTP_GROUPS[@]}" > "$VSFTPD_GROUPS_FILE"
}

_pedir_grupos_iniciales() {
    if [ -s "$VSFTPD_GROUPS_FILE" ]; then
        _cargar_grupos
        msg_info "Grupos existentes: ${FTP_GROUPS[*]}"
        return 0
    fi

    separator
    msg_info "Define los grupos FTP (al menos uno). Linea vacia para terminar."
    separator

    FTP_GROUPS=()
    while true; do
        msg_input "Nombre del grupo (Enter para terminar): "
        read -r grupo
        if [[ -z "$grupo" ]]; then
            [ ${#FTP_GROUPS[@]} -eq 0 ] && msg_error "Al menos un grupo requerido" && continue
            break
        fi
        if [[ ! "$grupo" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            msg_error "Nombre invalido: solo minusculas, numeros, _ y -"
            continue
        fi
        local dup=false
        for g in "${FTP_GROUPS[@]}"; do [[ "$g" == "$grupo" ]] && dup=true && break; done
        $dup && msg_alert "'$grupo' ya esta en la lista" && continue
        FTP_GROUPS+=("$grupo")
        msg_success "Grupo '$grupo' agregado"
    done

    _guardar_grupos
    msg_success "Grupos guardados: ${FTP_GROUPS[*]}"
}

listar_grupos_ftp() {
    separator
    msg_info "Grupos FTP:"
    for grupo in "${FTP_GROUPS[@]}"; do
        local dir="$FTP_ROOT/$grupo"
        echo ""
        echo "  Grupo     : $grupo"
        echo "  Directorio: $dir"
        if [ -d "$dir" ]; then
            echo "  Permisos  : $(stat -c '%A  %U:%G' "$dir")"
        else
            echo "  Directorio: no existe"
        fi
        local miembros
        miembros=$(grep ":${grupo}$" "$VSFTPD_USERS_META" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
        echo "  Miembros  : ${miembros:-(sin miembros)}"
    done
    echo ""
    separator
    msg_info "Directorio general: $FTP_GENERAL"
    if [ -d "$FTP_GENERAL" ]; then
        echo "  Permisos: $(stat -c '%A  %U:%G' "$FTP_GENERAL")"
        echo "  ACL:"
        getfacl "$FTP_GENERAL" 2>/dev/null | grep -v '^#' | grep -v '^$' | sed 's/^/    /'
    else
        msg_alert "$FTP_GENERAL no existe"
    fi
}

crear_grupo_ftp() {
    separator
    msg_input "Nombre del nuevo grupo: "
    read -r nuevo_grupo

    [[ -z "$nuevo_grupo" || ! "$nuevo_grupo" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && \
        msg_error "Nombre invalido" && return 1

    for g in "${FTP_GROUPS[@]}"; do
        [[ "$g" == "$nuevo_grupo" ]] && msg_alert "El grupo '$nuevo_grupo' ya existe" && return 1
    done

    if ! getent group "$nuevo_grupo" &>/dev/null; then
        groupadd "$nuevo_grupo" || { msg_error "groupadd fallo"; return 1; }
    fi

    local dir="$FTP_ROOT/$nuevo_grupo"
    mkdir -p "$dir"
    chown root:"$nuevo_grupo" "$dir"
    chmod 770 "$dir"

    FTP_GROUPS+=("$nuevo_grupo")
    _guardar_grupos
    msg_success "Grupo '$nuevo_grupo' creado"
}

eliminar_grupo_ftp() {
    separator
    listar_grupos_ftp

    msg_input "Nombre del grupo a eliminar: "
    read -r grupo_eliminar

    local encontrado=false
    for g in "${FTP_GROUPS[@]}"; do
        [[ "$g" == "$grupo_eliminar" ]] && encontrado=true && break
    done
    $encontrado || { msg_error "Grupo no encontrado"; return 1; }
    [ "${#FTP_GROUPS[@]}" -le 1 ] && { msg_error "Debe quedar al menos un grupo"; return 1; }

    local miembros
    miembros=$(grep ":${grupo_eliminar}$" "$VSFTPD_USERS_META" 2>/dev/null | cut -d: -f1)
    if [ -n "$miembros" ]; then
        msg_info "Usuarios a reasignar: $(echo "$miembros" | tr '\n' ' ')"
        local grupo_destino=""
        _pedir_grupo grupo_destino
        while IFS= read -r u; do
            [ -z "$u" ] && continue
            _meta_set "$u" "$grupo_destino"
            _actualizar_mounts_usuario "$u" "$grupo_destino"
            chown root:"$grupo_destino" "$FTP_ROOT/${FTP_USER_PREFIX}${u}/$u" 2>/dev/null
            msg_success "'$u' reasignado a '$grupo_destino'"
        done <<< "$miembros"
    fi

    local dir="$FTP_ROOT/$grupo_eliminar"
    if [ -d "$dir" ]; then
        msg_input "Eliminar directorio $dir? [s/N]: "
        read -r resp
        [[ "$resp" =~ ^[Ss]$ ]] && rm -rf "$dir" && msg_success "Directorio eliminado"
    fi

    getent group "$grupo_eliminar" &>/dev/null && groupdel "$grupo_eliminar" 2>/dev/null

    local nuevos=()
    for g in "${FTP_GROUPS[@]}"; do
        [[ "$g" != "$grupo_eliminar" ]] && nuevos+=("$g")
    done
    FTP_GROUPS=("${nuevos[@]}")
    _guardar_grupos
    msg_success "Grupo '$grupo_eliminar' eliminado"
}

gestionar_permisos_directorios() {
    separator
    msg_info "Permisos actuales:"
    echo ""
    for path in "$FTP_ROOT" "$FTP_GENERAL"; do
        [ -d "$path" ] && printf "  %-45s %s\n" "$path" "$(stat -c '%A %U:%G' "$path")"
    done
    for grupo in "${FTP_GROUPS[@]}"; do
        local d="$FTP_ROOT/$grupo"
        [ -d "$d" ] \
            && printf "  %-45s %s\n" "$d" "$(stat -c '%A %U:%G' "$d")" \
            || printf "  %-45s %s\n" "$d" "(no existe)"
    done
    separator
    reparar_permisos
}

reparar_grupos_usuarios() {
    separator
    msg_process "Verificando grupos primarios de usuarios FTP..."
    while IFS=: read -r u g; do
        [ -z "$u" ] && continue
        if id "$u" &>/dev/null; then
            local gid_actual
            gid_actual=$(id -gn "$u")
            if [ "$gid_actual" != "$g" ]; then
                usermod -g "$g" "$u" && msg_success "$u: grupo primario corregido ($gid_actual -> $g)"
            else
                msg_info "$u: grupo primario OK ($g)"
            fi
            # Garantizar grupo SSH
            usermod -aG "$FTP_SSH_GROUP" "$u" 2>/dev/null || true
        else
            msg_alert "Usuario del sistema '$u' no existe"
        fi
    done < "$VSFTPD_USERS_META" 2>/dev/null
    msg_success "Revision completada"
}