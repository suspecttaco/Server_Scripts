#!/bin/bash
# =============================================================================
# ftp_lib/ftp_users.sh — CRUD de usuarios FTP
#
# =============================================================================

# -----------------------------------------------------------------------------
# Validadores
# -----------------------------------------------------------------------------
_USUARIOS_RESERVADOS=(root bin daemon adm lp sync shutdown halt mail
    operator games ftp nobody systemd-network dbus polkitd sshd chrony
    vsftpd nfsnobody www-data apache nginx ftp_users)

_validar_nombre_usuario() {
    local nombre="$1"
    if [[ ! "$nombre" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]]; then
        msg_error "Nombre invalido '$nombre': minusculas/numeros/_.-; max 32; empieza con letra o _"
        return 1
    fi
    for r in "${_USUARIOS_RESERVADOS[@]}"; do
        [[ "$nombre" == "$r" ]] && msg_error "Nombre reservado: '$nombre'" && return 1
    done
    return 0
}

_pedir_contrasena_confirmada() {
    local __var="$1"
    local p1 p2
    while true; do
        msg_input "Contrasena (min 4 chars): "
        read -rs p1; echo
        [[ ${#p1} -lt 4 ]] && msg_error "Minimo 4 caracteres" && continue
        msg_input "Confirma contrasena: "
        read -rs p2; echo
        [[ "$p1" != "$p2" ]] && msg_error "No coinciden" && continue
        printf -v "$__var" "%s" "$p1"
        return 0
    done
}

_pedir_grupo() {
    local __var="${1:-_grupo_sel}"
    local sel _grupo_interno
    while true; do
        echo "  Grupos disponibles:"
        for i in "${!FTP_GROUPS[@]}"; do
            echo "    $((i+1))) ${FTP_GROUPS[$i]}"
        done
        msg_input "Selecciona grupo [1-${#FTP_GROUPS[@]}]: "
        read -r sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && \
           [ "$sel" -ge 1 ] && [ "$sel" -le "${#FTP_GROUPS[@]}" ]; then
            _grupo_interno="${FTP_GROUPS[$((sel-1))]}"
            printf -v "$__var" "%s" "$_grupo_interno"
            return 0
        fi
        msg_error "Seleccion invalida"
    done
}

# -----------------------------------------------------------------------------
# Gestion de contrasenas y metadatos
# -----------------------------------------------------------------------------
_set_password() {
    local usuario="$1" pass="$2"
    echo "${usuario}:${pass}" | chpasswd
}

_inicializar_archivos_meta() {
    mkdir -p "$VSFTPD_DIR"
    touch "$VSFTPD_USERS_META"; chmod 640 "$VSFTPD_USERS_META"
    msg_success "Archivo de metadatos inicializado"
}

_meta_get_grupo() { grep -m1 "^${1}:" "$VSFTPD_USERS_META" 2>/dev/null | cut -d: -f2; }
_meta_del()       { sed -i "/^${1}:/d" "$VSFTPD_USERS_META"; }
_meta_existe()    { grep -q "^${1}:" "$VSFTPD_USERS_META" 2>/dev/null; }
_meta_set() {
    local u="$1" g="$2"
    if grep -q "^${u}:" "$VSFTPD_USERS_META" 2>/dev/null; then
        sed -i "s|^${u}:.*|${u}:${g}|" "$VSFTPD_USERS_META"
    else
        echo "${u}:${g}" >> "$VSFTPD_USERS_META"
    fi
}

_usuario_existe() { _meta_existe "$1"; }

# -----------------------------------------------------------------------------
# CRUD publico
# -----------------------------------------------------------------------------
crear_usuarios_lote() {
    separator
    msg_input "Numero de usuarios a crear: "
    read -r n
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { msg_error "Numero invalido"; return 1; }

    local total=$n creados=0
    while [ $creados -lt $total ]; do
        separator
        msg_info "Usuario $((creados+1)) de $total"

        local usuario=""
        while true; do
            msg_input "Nombre de usuario FTP: "
            read -r usuario
            _validar_nombre_usuario "$usuario" || continue
            _usuario_existe "$usuario" && msg_error "Ya existe '$usuario'" && continue
            id "$usuario" &>/dev/null && msg_error "Usuario del sistema '$usuario' ya existe" && continue
            break
        done

        local pass=""
        _pedir_contrasena_confirmada pass || { stty echo 2>/dev/null; creados=$((creados+1)); continue; }
        stty echo 2>/dev/null

        local grupo=""
        _pedir_grupo grupo

        _crear_directorios_usuario "$usuario" "$grupo"
        _set_password "$usuario" "$pass"
        _meta_set "$usuario" "$grupo"

        msg_success "Usuario '$usuario' creado en grupo '$grupo'"
        creados=$((creados+1))
    done

    systemctl restart vsftpd
    msg_success "$total usuario(s) procesados. vsftpd reiniciado."
}

actualizar_usuario_ftp() {
    separator
    msg_input "Nombre del usuario FTP a actualizar: "
    read -r usuario

    _usuario_existe "$usuario" || { msg_error "El usuario '$usuario' no existe"; return 1; }

    local grupo_actual; grupo_actual=$(_meta_get_grupo "$usuario")
    msg_info "Usuario FTP : $usuario"
    msg_info "Grupo       : $grupo_actual"
    msg_info "(Enter = sin cambios)"
    separator

    # Nombre de login
    msg_input "Nuevo nombre FTP [$usuario]: "
    read -r nuevo_nombre
    if [[ -n "$nuevo_nombre" && "$nuevo_nombre" != "$usuario" ]]; then
        if ! _validar_nombre_usuario "$nuevo_nombre"; then
            msg_error "Nombre invalido — sin cambios"
        elif _usuario_existe "$nuevo_nombre"; then
            msg_error "'$nuevo_nombre' ya en uso"
        else
            if id "$usuario" &>/dev/null; then
                usermod -l "$nuevo_nombre" "$usuario" 2>/dev/null && \
                    msg_success "Usuario del sistema: '$usuario' -> '$nuevo_nombre'"
            fi
            sed -i "s|^${usuario}:|${nuevo_nombre}:|" "$VSFTPD_USERS_META"
            _renombrar_directorios_usuario "$usuario" "$nuevo_nombre" "$grupo_actual"
            msg_success "Usuario FTP: '$usuario' -> '$nuevo_nombre'"
            usuario="$nuevo_nombre"
        fi
    fi

    # Carpeta privada
    local user_root="$FTP_ROOT/${FTP_USER_PREFIX}${usuario}"
    local carpeta_actual=""
    if [ -d "$user_root" ]; then
        carpeta_actual=$(find "$user_root" -maxdepth 1 -mindepth 1 -type d \
            ! -name "general" $(printf -- "! -name %s " "${FTP_GROUPS[@]}") \
            | xargs -I{} basename {} 2>/dev/null | head -1)
    fi
    if [ -n "$carpeta_actual" ]; then
        msg_input "Renombrar carpeta privada '$carpeta_actual' [Enter = dejar igual]: "
        read -r nuevo_carpeta
        if [[ -n "$nuevo_carpeta" && "$nuevo_carpeta" != "$carpeta_actual" ]]; then
            local ruta_vieja="$user_root/$carpeta_actual"
            local ruta_nueva="$user_root/$nuevo_carpeta"
            if [ -e "$ruta_nueva" ]; then
                msg_error "Ya existe '$nuevo_carpeta' en el chroot — sin cambios"
            else
                mv "$ruta_vieja" "$ruta_nueva"
                chown "$usuario":"$grupo_actual" "$ruta_nueva"
                chmod 700 "$ruta_nueva"
                msg_success "Carpeta privada: '$carpeta_actual' -> '$nuevo_carpeta'"
            fi
        fi
    fi

    # Contrasena
    msg_input "Cambiar contrasena? [s/N]: "; read -r cp
    if [[ "$cp" =~ ^[Ss]$ ]]; then
        local nueva_pass=""
        if _pedir_contrasena_confirmada nueva_pass; then
            stty echo 2>/dev/null
            _set_password "$usuario" "$nueva_pass"
            msg_success "Contrasena actualizada"
        else
            stty echo 2>/dev/null
        fi
    fi

    # Grupo
    msg_info "Grupo actual: $grupo_actual"
    msg_input "Cambiar grupo? [s/N]: "; read -r cg
    if [[ "$cg" =~ ^[Ss]$ ]]; then
        local nuevo_grupo=""
        _pedir_grupo nuevo_grupo
        if [ "$nuevo_grupo" != "$grupo_actual" ]; then
            usermod -g "$nuevo_grupo" "$usuario" 2>/dev/null
            setfacl -x "u:${usuario}" "$FTP_ROOT/$grupo_actual" 2>/dev/null || true
            setfacl -m "u:${usuario}:rwx" "$FTP_ROOT/$nuevo_grupo" 2>/dev/null || true
            setfacl -d -m "u:${usuario}:rw" "$FTP_ROOT/$nuevo_grupo" 2>/dev/null || true
            local privada="$FTP_ROOT/${FTP_USER_PREFIX}${usuario}/$usuario"
            [ -d "$privada" ] && chown "${usuario}":"$nuevo_grupo" "$privada"
            _meta_set "$usuario" "$nuevo_grupo"
            _actualizar_mounts_usuario "$usuario" "$nuevo_grupo"
            msg_success "Grupo: '$grupo_actual' -> '$nuevo_grupo'"
        else
            msg_info "Mismo grupo — sin cambios"
        fi
    fi

    systemctl restart vsftpd
    msg_success "Actualizacion de '$usuario' completada"
}

eliminar_usuario_ftp() {
    separator
    msg_input "Nombre del usuario FTP a eliminar: "
    read -r usuario

    _usuario_existe "$usuario" || { msg_error "El usuario '$usuario' no existe"; return 1; }

    local grupo; grupo=$(_meta_get_grupo "$usuario")
    local user_dir="$FTP_ROOT/${FTP_USER_PREFIX}${usuario}"
    msg_info "Usuario FTP: $usuario  |  Grupo: $grupo  |  Dir: $user_dir"
    msg_input "Confirma eliminar '$usuario' [s/N]: "; read -r confirm
    [[ "$confirm" =~ ^[Ss]$ ]] || { msg_info "Cancelado"; return 0; }

    msg_input "Eliminar directorio del usuario? [s/N]: "; read -r del_dir

    setfacl -x "u:${usuario}" "$FTP_GENERAL"     2>/dev/null || true
    setfacl -x "u:${usuario}" "$FTP_ROOT/$grupo" 2>/dev/null || true

    # Desmontar bind mounts antes de eliminar el usuario/directorio
    _eliminar_mounts_usuario "$usuario"

    id "$usuario" &>/dev/null && userdel "$usuario" && \
        msg_success "Usuario del sistema '$usuario' eliminado"

    _meta_del "$usuario"

    if [[ "$del_dir" =~ ^[Ss]$ ]]; then
        rm -rf "$user_dir"
        msg_success "Directorio eliminado"
    fi

    systemctl restart vsftpd
    msg_success "Usuario '$usuario' eliminado"
}

listar_usuarios_ftp() {
    separator
    msg_info "Usuarios FTP:"
    if [ ! -s "$VSFTPD_USERS_META" ]; then
        msg_alert "No hay usuarios registrados"
        return
    fi
    printf "  %-20s %-15s %-20s %-15s\n" "USUARIO FTP" "GRUPO" "DIRECTORIO CHROOT" "CARPETA PRIVADA"
    printf "  %-20s %-15s %-20s %-15s\n" "-----------" "-----" "-----------------" "---------------"
    while IFS=: read -r u g; do
        [ -z "$u" ] && continue
        local user_root="$FTP_ROOT/${FTP_USER_PREFIX}${u}"
        local privada=""
        if [ -d "$user_root" ]; then
            privada=$(find "$user_root" -maxdepth 1 -mindepth 1 -type d \
                ! -name "general" $(printf -- "! -name %s " "${FTP_GROUPS[@]}") \
                | xargs -I{} basename {} 2>/dev/null | head -1)
        fi
        printf "  %-20s %-15s %-20s %-15s\n" "$u" "$g" "${FTP_USER_PREFIX}${u}" "${privada:-(sin carpeta)}"
    done < "$VSFTPD_USERS_META"
}