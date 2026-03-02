#!/bin/bash
# =============================================================================
# ftp_lib/ftp_dirs.sh — Estructura de directorios y permisos
#
# Se usan bind mounts en lugar de symlinks porque vsftpd no puede seguir
# symlinks que apuntan fuera del chroot del usuario.
# Los mounts se persisten via unidades systemd .mount en /etc/systemd/system/.
#
# El usuario del sistema se llama igual que el login FTP,
# el directorio chroot tiene el prefijo ftp_.
# =============================================================================

# Aplica contexto SELinux public_content_rw_t a un path.
_selinux_ftp_context() {
    command -v restorecon &>/dev/null && restorecon -R "$1" &>/dev/null || true
}

# Convierte una ruta absoluta en nombre de unidad systemd .mount
_path_to_unit() {
    local path="${1#/}"          # quitar / inicial
    echo "${path//\//-}.mount"   # sustituir / por -
}

# Crea y activa un bind mount persistente via systemd.
_crear_bind_mount() {
    local origen="$1" destino="$2"
    local unit_name
    unit_name=$(_path_to_unit "$destino")
    local unit_file="/etc/systemd/system/${unit_name}"

    mkdir -p "$destino"

    cat > "$unit_file" <<UNIT
[Unit]
Description=FTP bind mount ${origen} -> ${destino}
After=local-fs.target

[Mount]
What=${origen}
Where=${destino}
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now "$unit_name" &>/dev/null \
        && msg_success "Bind mount: $destino" \
        || msg_error "Error al montar: $destino"
}

# Desmonta y elimina la unidad systemd de un bind mount.
_eliminar_bind_mount() {
    local destino="$1"
    local unit_name
    unit_name=$(_path_to_unit "$destino")
    local unit_file="/etc/systemd/system/${unit_name}"

    systemctl disable --now "$unit_name" &>/dev/null || true
    umount "$destino" 2>/dev/null || true
    rm -f "$unit_file"
    systemctl daemon-reload
    rmdir "$destino" 2>/dev/null || true
}

_crear_estructura_directorios() {
    msg_process "Creando estructura base en $FTP_ROOT..."

    mkdir -p "$FTP_GENERAL"
    for grupo in "${FTP_GROUPS[@]}"; do
        mkdir -p "$FTP_ROOT/$grupo"
    done

    chown root:root "$FTP_ROOT"; chmod 755 "$FTP_ROOT"

    # general: escribible por todos los usuarios FTP via ACL
    # El sticky bit evita que un usuario borre archivos de otro
    chown root:ftp "$FTP_GENERAL"; chmod 775 "$FTP_GENERAL"; chmod +t "$FTP_GENERAL"

    # ACLs por defecto en general: cualquier archivo o directorio creado aqui
    # hereda permisos que permiten a otros usuarios FTP entrar y leer.
    # Sin esto, un usuario de grupo A crea una carpeta con permisos de su umask
    # y usuarios de grupo B no pueden entrar aunque general sea "tierra de nadie".
    setfacl -m other::rwx "$FTP_GENERAL" 2>/dev/null || true
    setfacl -m group::rwx "$FTP_GENERAL" 2>/dev/null || true
    setfacl -d -m other::rwx "$FTP_GENERAL" 2>/dev/null || true
    setfacl -d -m group::rwx "$FTP_GENERAL" 2>/dev/null || true

    for grupo in "${FTP_GROUPS[@]}"; do
        local dir="$FTP_ROOT/$grupo"
        chown root:"$grupo" "$dir"
        chmod 2770 "$dir"
        chmod +t "$dir"
    done

    # Chroot para usuario anonimo: root:root 755 (no escribible — exigencia vsftpd)
    # con bind mount de general dentro para que pueda explorar
    local anon_root="$FTP_ROOT/ftp_anonymous"
    mkdir -p "$anon_root"
    chown root:root "$anon_root"; chmod 755 "$anon_root"
    _crear_bind_mount "$FTP_GENERAL" "$anon_root/general"

    _selinux_ftp_context "$FTP_ROOT"
    msg_success "Estructura base creada"
}

# Crea chroot raiz, carpeta privada, bind mounts, usuario del sistema y ACLs.
_crear_directorios_usuario() {
    local usuario="$1" grupo="$2"
    local user_root="$FTP_ROOT/${FTP_USER_PREFIX}${usuario}"

    # --- Usuario del sistema ---
    if ! id "$usuario" &>/dev/null; then
        useradd \
            --shell /sbin/nologin \
            --home-dir "$user_root" \
            --no-create-home \
            --gid "$grupo" \
            --groups "$FTP_SSH_GROUP" \
            --password '!' \
            "$usuario"
        msg_success "Usuario del sistema '$usuario' creado (grupo: $grupo, SSH bloqueado)"
    fi
    usermod -g "$grupo" "$usuario" 2>/dev/null
    usermod -aG "$FTP_SSH_GROUP" "$usuario" 2>/dev/null

    # --- Chroot raiz: root:root 755 (vsftpd exige que no sea escribible por el usuario) ---
    mkdir -p "$user_root"
    chown root:root "$user_root"; chmod 755 "$user_root"

    # --- Carpeta privada ---
    local privada="$user_root/$usuario"
    mkdir -p "$privada"
    chown "$usuario":"$grupo" "$privada"; chmod 700 "$privada"

    # --- Bind mounts (en lugar de symlinks que vsftpd no puede seguir fuera del chroot) ---
    _crear_bind_mount "$FTP_GENERAL"     "$user_root/general"
    _crear_bind_mount "$FTP_ROOT/$grupo" "$user_root/$grupo"

    # --- ACLs ---
    setfacl -m  "u:${usuario}:rwx" "$FTP_GENERAL"       2>/dev/null || true
    setfacl -m  "u:${usuario}:rwx" "$FTP_ROOT/$grupo"   2>/dev/null || true
    setfacl -d -m "u:${usuario}:rwx" "$FTP_ROOT/$grupo"  2>/dev/null || true

    # --- SELinux ---
    _selinux_ftp_context "$user_root"
}

# Desmonta y elimina todos los bind mounts de un usuario.
_eliminar_mounts_usuario() {
    local usuario="$1"
    local user_root="$FTP_ROOT/${FTP_USER_PREFIX}${usuario}"

    _eliminar_bind_mount "$user_root/general"

    for g in "${FTP_GROUPS[@]}"; do
        [ -d "$user_root/$g" ] && _eliminar_bind_mount "$user_root/$g"
    done
}

# Actualiza bind mounts cuando cambia el grupo de un usuario.
_actualizar_mounts_usuario() {
    local usuario="$1" nuevo_grupo="$2"
    local user_root="$FTP_ROOT/${FTP_USER_PREFIX}${usuario}"

    for g in "${FTP_GROUPS[@]}"; do
        [ -d "$user_root/$g" ] && _eliminar_bind_mount "$user_root/$g"
    done

    _crear_bind_mount "$FTP_GENERAL"           "$user_root/general"
    _crear_bind_mount "$FTP_ROOT/$nuevo_grupo" "$user_root/$nuevo_grupo"
}

_renombrar_directorios_usuario() {
    local viejo="$1" nuevo="$2" grupo="$3"
    local old_root="$FTP_ROOT/${FTP_USER_PREFIX}${viejo}"
    local new_root="$FTP_ROOT/${FTP_USER_PREFIX}${nuevo}"

    [ ! -d "$old_root" ] && return 0

    # Desmontar antes de mover
    _eliminar_mounts_usuario "$viejo"

    mv "$old_root" "$new_root"

    # Renombrar carpeta privada interna si coincide con el nombre viejo
    if [ -d "$new_root/$viejo" ]; then
        mv "$new_root/$viejo" "$new_root/$nuevo"
        chown "$nuevo":"$grupo" "$new_root/$nuevo"
        chmod 700 "$new_root/$nuevo"
    fi

    # Remontar con rutas nuevas
    _crear_bind_mount "$FTP_GENERAL"     "$new_root/general"
    _crear_bind_mount "$FTP_ROOT/$grupo" "$new_root/$grupo"

    _selinux_ftp_context "$new_root"
}

reparar_permisos() {
    separator
    msg_process "Reparando permisos..."

    chown root:root "$FTP_ROOT"; chmod 755 "$FTP_ROOT"

    if [ -d "$FTP_GENERAL" ]; then
        chown root:ftp "$FTP_GENERAL"; chmod 775 "$FTP_GENERAL"; chmod +t "$FTP_GENERAL"
        msg_success "$FTP_GENERAL reparado"
        while IFS=: read -r u _; do
            [ -z "$u" ] && continue
            id "$u" &>/dev/null && \
                setfacl -m "u:${u}:rwx" "$FTP_GENERAL" 2>/dev/null || true
        done < "$VSFTPD_USERS_META" 2>/dev/null
    fi

    for grupo in "${FTP_GROUPS[@]}"; do
        local d="$FTP_ROOT/$grupo"
        if [ -d "$d" ]; then
            chown root:"$grupo" "$d"; chmod 2770 "$d"; chmod +t "$d"
            msg_success "$d reparado"
        fi
    done

    while IFS=: read -r u g; do
        [ -z "$u" ] && continue
        local user_root="$FTP_ROOT/${FTP_USER_PREFIX}${u}"
        local privada="$user_root/$u"

        [ -d "$user_root" ] && { chown root:root "$user_root"; chmod 755 "$user_root"; }
        if [ -d "$privada" ]; then
            chown "$u":"$g" "$privada"; chmod 700 "$privada"
            msg_success "$privada reparada"
        fi

        # Garantizar bloqueo SSH
        id "$u" &>/dev/null && usermod -aG "$FTP_SSH_GROUP" "$u" 2>/dev/null || true

        # Re-activar bind mounts si no estan montados
        local unit_gen unit_grp
        unit_gen=$(_path_to_unit "$user_root/general")
        unit_grp=$(_path_to_unit "$user_root/$g")
        systemctl is-active --quiet "$unit_gen" || \
            systemctl start "$unit_gen" &>/dev/null || \
            _crear_bind_mount "$FTP_GENERAL"  "$user_root/general"
        systemctl is-active --quiet "$unit_grp" || \
            systemctl start "$unit_grp" &>/dev/null || \
            _crear_bind_mount "$FTP_ROOT/$g"  "$user_root/$g"

    done < "$VSFTPD_USERS_META" 2>/dev/null

    # Propagar ACLs correctas a carpetas de grupo para usuarios existentes
    msg_process "Propagando ACLs en carpetas de grupo..."
    while IFS=: read -r u g; do
        [ -z "$u" ] && continue
        local grupo_dir="$FTP_ROOT/$g"
        [ ! -d "$grupo_dir" ] && continue
        # Aplicar rwx a todos los miembros del grupo en todo el contenido existente
        while IFS=: read -r u2 g2; do
            [ -z "$u2" ] && continue
            [ "$g2" != "$g" ] && continue
            find "$grupo_dir" -type d | while read -r dir; do
                setfacl -m "u:${u2}:rwx" "$dir" 2>/dev/null || true
                setfacl -d -m "u:${u2}:rwx" "$dir" 2>/dev/null || true
            done
        done < "$VSFTPD_USERS_META" 2>/dev/null
    done < "$VSFTPD_USERS_META" 2>/dev/null
    msg_success "ACLs de grupos propagadas"

    # Propagar ACLs correctas a todo lo existente dentro de general
    msg_process "Propagando ACLs en $FTP_GENERAL..."
    find "$FTP_GENERAL" -type d | while read -r dir; do
        setfacl -m other::rwx "$dir" 2>/dev/null || true
        setfacl -d -m other::rwx "$dir" 2>/dev/null || true
    done
    find "$FTP_GENERAL" -type f | while read -r file; do
        setfacl -m other::rwx "$file" 2>/dev/null || true
    done
    msg_success "ACLs propagadas en $FTP_GENERAL"

    if command -v restorecon &>/dev/null; then
        msg_process "Reparando contexto SELinux..."
        restorecon -Rv "$FTP_ROOT" &>/dev/null
        msg_success "Contexto SELinux reparado"
    fi

    msg_success "Reparacion completada"
}