#!/bin/bash
# =============================================================================
# ws_lib/ws_ftp_source.sh — Instalación de servicios HTTP desde repositorio FTP
#
# Integración con ws_install.sh:
#   Cuando el usuario elige "repositorio FTP" al instalar un servicio,
#   este módulo:
#     1. Pide credenciales FTP
#     2. Navega la estructura http/Linux|Windows/<Servicio>/
#     3. Lista los paquetes disponibles
#     4. El usuario selecciona la versión
#     5. Descarga el paquete y verifica SHA256
#     6. Instala el paquete descargado
#
# Estructura esperada en el FTP:
#   <directorio_usuario>/
#   └── http/
#       ├── Linux/
#       │   ├── Apache/  → *.rpm + *.rpm.sha256
#       │   ├── Nginx/   → *.rpm + *.rpm.sha256
#       │   └── Tomcat/  → *.rpm + *.rpm.sha256
#       └── Windows/
#           ├── Apache/  → *.zip + *.zip.sha256
#           ├── Nginx/   → *.zip + *.zip.sha256
#           └── Tomcat/  → *.exe + *.exe.sha256
#
# Requiere: source lib/ui.sh, source ws_lib/ws_utils.sh
# =============================================================================

[[ -n "${_WS_FTP_SOURCE_LOADED:-}" ]] && return 0
readonly _WS_FTP_SOURCE_LOADED=1

# Directorio temporal para descargas FTP
_FTP_SRC_TMPDIR=""

# Credenciales de la sesión FTP actual (se rellenan en ftp_src_conectar)
_FTP_SRC_HOST=""
_FTP_SRC_PORT="21"
_FTP_SRC_USER=""
_FTP_SRC_PASS=""
_FTP_SRC_SSL=""
_FTP_SRC_PROTO="ftp"    # Protocolo detectado: ftp | ftps
_FTP_SRC_BASE_PATH=""   # Ruta base donde está http/ en el FTP

# -----------------------------------------------------------------------------
# _ftp_src_limpiar  (interna)
# Elimina el directorio temporal al salir o en error.
# -----------------------------------------------------------------------------
_ftp_src_limpiar() {
    [[ -n "$_FTP_SRC_TMPDIR" && -d "$_FTP_SRC_TMPDIR" ]] && \
        rm -rf "$_FTP_SRC_TMPDIR"
}

# -----------------------------------------------------------------------------
# _ftp_src_curl  (interna)
# Wrapper de curl FTP con credenciales y SSL ya configurados.
# $@ = argumentos adicionales para curl
# -----------------------------------------------------------------------------
_ftp_src_curl() {
    curl -sf \
         --connect-timeout 15 \
         ${_FTP_SRC_SSL} \
         -u "${_FTP_SRC_USER}:${_FTP_SRC_PASS}" \
         "$@"
}

# -----------------------------------------------------------------------------
# _ftp_src_listar_dir  (interna)
# Lista el contenido de un directorio FTP.
# $1 = ruta en el FTP (relativa a la raíz del FTP)
# Imprime una línea por entrada.
# -----------------------------------------------------------------------------
_ftp_src_listar_dir() {
    local ruta="$1"
    _ftp_src_curl \
        "${_FTP_SRC_PROTO}://${_FTP_SRC_HOST}:${_FTP_SRC_PORT}${ruta}" \
        -l 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# ftp_src_conectar
#
# Solicita credenciales FTP al usuario y verifica la conexión.
# Detecta automáticamente si el servidor soporta FTPS.
# Retorna 0 si la conexión es exitosa.
# -----------------------------------------------------------------------------
ftp_src_conectar() {
    separator
    msg_info "Repositorio FTP — Credenciales"
    separator
    echo ""

    msg_input "IP del servidor FTP: "; read -r _FTP_SRC_HOST
    [[ -z "$_FTP_SRC_HOST" ]] && { msg_error "La IP no puede estar vacía"; return 1; }

    msg_input "Puerto [21]: "; read -r _FTP_SRC_PORT
    _FTP_SRC_PORT="${_FTP_SRC_PORT:-21}"

    msg_input "Usuario: "; read -r _FTP_SRC_USER
    [[ -z "$_FTP_SRC_USER" ]] && { msg_error "El usuario no puede estar vacío"; return 1; }

    msg_input "Contraseña: "; read -rs _FTP_SRC_PASS; echo
    [[ -z "$_FTP_SRC_PASS" ]] && { msg_error "La contraseña no puede estar vacía"; return 1; }

    msg_input "Directorio base en el FTP [/]: "; read -r _FTP_SRC_BASE_PATH
    _FTP_SRC_BASE_PATH="${_FTP_SRC_BASE_PATH:-/}"
    # Garantizar slash inicial, quitar slash final (excepto raiz)
    [[ "$_FTP_SRC_BASE_PATH" != /* ]] && _FTP_SRC_BASE_PATH="/${_FTP_SRC_BASE_PATH}"
    [[ "$_FTP_SRC_BASE_PATH" != "/" ]] && _FTP_SRC_BASE_PATH="${_FTP_SRC_BASE_PATH%/}"

    echo ""
    msg_process "Verificando conexión..."

    # Orden: FTPS cert válido → FTPS cert autofirmado → FTP plano
    if curl -sf --connect-timeout 10 --ftp-ssl \
            -u "${_FTP_SRC_USER}:${_FTP_SRC_PASS}" \
            "ftp://${_FTP_SRC_HOST}:${_FTP_SRC_PORT}/" \
            -l &>/dev/null; then
        _FTP_SRC_SSL="--ftp-ssl"
        _FTP_SRC_PROTO="ftp"
        msg_success "Conexión FTPS (STARTTLS) establecida"
    elif curl -sf --connect-timeout 10 --ftp-ssl --insecure \
            -u "${_FTP_SRC_USER}:${_FTP_SRC_PASS}" \
            "ftp://${_FTP_SRC_HOST}:${_FTP_SRC_PORT}/" \
            -l &>/dev/null; then
        _FTP_SRC_SSL="--ftp-ssl --insecure"
        _FTP_SRC_PROTO="ftp"
        msg_success "Conexión FTPS (STARTTLS, certificado autofirmado aceptado)"
        msg_alert  "Certificado autofirmado — tráfico cifrado sin validación de identidad"
    elif curl -sf --connect-timeout 10 \
            -u "${_FTP_SRC_USER}:${_FTP_SRC_PASS}" \
            "ftp://${_FTP_SRC_HOST}:${_FTP_SRC_PORT}/" \
            -l &>/dev/null; then
        _FTP_SRC_SSL=""
        _FTP_SRC_PROTO="ftp"
        msg_success "Conexión FTP establecida"
    else
        msg_error "No se pudo conectar a ${_FTP_SRC_HOST}:${_FTP_SRC_PORT}"
        msg_info  "Modos probados: FTPS/STARTTLS, FTPS/cert-autofirmado, FTP plano"
        msg_info  "Verifique IP, puerto y credenciales"
        return 1
    fi

    # Crear directorio temporal para descargas
    _FTP_SRC_TMPDIR=$(mktemp -d /tmp/ftp_src_XXXXXX)
    trap '_ftp_src_limpiar' EXIT

    return 0
}

# -----------------------------------------------------------------------------
# _ftp_src_ruta_servicio  (interna)
# Calcula la ruta FTP para un servicio y OS dados.
# $1 = servicio interno (httpd|nginx|tomcat)
# $2 = os (Linux|Windows)
# -----------------------------------------------------------------------------
_ftp_src_ruta_servicio() {
    local servicio="$1"
    local os="$2"
    local nombre_dir

    case "$servicio" in
        httpd|apache) nombre_dir="Apache" ;;
        nginx)        nombre_dir="Nginx"  ;;
        tomcat)       nombre_dir="Tomcat" ;;
        *)            nombre_dir="$servicio" ;;
    esac

    echo "${_FTP_SRC_BASE_PATH}/http/${os}/${nombre_dir}"
}

# -----------------------------------------------------------------------------
# _ftp_src_extension_servicio  (interna)
# Devuelve la extensión de paquete esperada según el OS.
# -----------------------------------------------------------------------------
_ftp_src_extension_servicio() {
    local os="$1"
    case "$os" in
        Linux)   echo "rpm" ;;
        Windows) echo "zip\|exe\|msi" ;;
        *)       echo "rpm" ;;
    esac
}

# -----------------------------------------------------------------------------
# ftp_src_listar_versiones
#
# Lista los paquetes disponibles para un servicio en el FTP.
# Filtra los archivos .sha256 — solo muestra los instaladores.
#
# $1 = servicio (httpd|nginx|tomcat)
# $2 = os (Linux|Windows) — default Linux
# Llena el array global _FTP_SRC_VERSIONES con los nombres de archivo.
# -----------------------------------------------------------------------------
ftp_src_listar_versiones() {
    local servicio="$1"
    local os="${2:-Linux}"
    local ruta; ruta=$(_ftp_src_ruta_servicio "$servicio" "$os")
    local ext; ext=$(_ftp_src_extension_servicio "$os")

    _FTP_SRC_VERSIONES=()

    msg_process "Listando versiones en ${ruta}..."

    local listado
    listado=$(_ftp_src_listar_dir "${ruta}/") || {
        msg_error "No se pudo listar el directorio: ${ruta}"
        msg_info  "Verifique que el repositorio FTP está construido correctamente"
        return 1
    }

    if [[ -z "$listado" ]]; then
        msg_alert "No hay paquetes disponibles en ${ruta}"
        return 1
    fi

    # Filtrar solo instaladores (excluir .sha256 y archivos ocultos)
    while IFS= read -r linea; do
        [[ -z "$linea" ]] && continue
        [[ "$linea" == *.sha256 ]] && continue
        [[ "$linea" == .* ]] && continue
        # Verificar que es un paquete del tipo esperado
        if echo "$linea" | grep -qE "\.(rpm|zip|exe|msi)$"; then
            _FTP_SRC_VERSIONES+=("$linea")
        fi
    done <<< "$listado"

    if [[ ${#_FTP_SRC_VERSIONES[@]} -eq 0 ]]; then
        msg_alert "No se encontraron paquetes en ${ruta}"
        return 1
    fi

    # Ordenar de más reciente a más antigua (sort -Vr)
    local sorted
    sorted=$(printf '%s\n' "${_FTP_SRC_VERSIONES[@]}" | sort -Vr)
    mapfile -t _FTP_SRC_VERSIONES <<< "$sorted"

    return 0
}

# -----------------------------------------------------------------------------
# ftp_src_seleccionar_version
#
# Muestra las versiones disponibles y permite al usuario seleccionar una.
# $1 = servicio
# $2 = os
# $3 = variable destino para el nombre del archivo seleccionado
# -----------------------------------------------------------------------------
ftp_src_seleccionar_version() {
    local servicio="$1"
    local os="${2:-Linux}"
    local __var="$3"

    ftp_src_listar_versiones "$servicio" "$os" || return 1

    local total=${#_FTP_SRC_VERSIONES[@]}

    clear
    separator
    msg_info "Versiones disponibles en repositorio FTP — ${servicio} (${os})"
    separator
    echo ""
    printf "  %-5s %-50s\n" "NUM" "ARCHIVO"
    separator

    local i
    for i in "${!_FTP_SRC_VERSIONES[@]}"; do
        local num=$(( i + 1 ))
        local archivo="${_FTP_SRC_VERSIONES[$i]}"
        # Destacar la más reciente
        if (( i == 0 )); then
            printf "  ${GREEN}%-5s${NC} %-50s ${GREEN}← más reciente${NC}\n" \
                   "${num})" "$archivo"
        else
            printf "  ${BLUE}%-5s${NC} %-50s\n" "${num})" "$archivo"
        fi
    done

    echo ""

    local opcion
    while true; do
        msg_input "Seleccione versión [1-${total}]: "; read -r opcion
        if [[ "$opcion" =~ ^[0-9]+$ ]] && \
           (( opcion >= 1 && opcion <= total )); then
            break
        fi
        msg_error "Selección inválida — ingrese un número entre 1 y ${total}"
    done

    local _sel="${_FTP_SRC_VERSIONES[$(( opcion - 1 ))]}"
    printf -v "$__var" "%s" "$_sel"

    echo ""
    msg_success "Versión seleccionada: ${_sel}"
    return 0
}

# -----------------------------------------------------------------------------
# ftp_src_descargar_verificar
#
# Descarga un paquete del FTP y verifica su integridad con el .sha256
# correspondiente.
#
# $1 = servicio
# $2 = os (Linux|Windows)
# $3 = nombre del archivo a descargar
# $4 = variable destino para la ruta local del archivo descargado
# -----------------------------------------------------------------------------
ftp_src_descargar_verificar() {
    local servicio="$1"
    local os="${2:-Linux}"
    local archivo="$3"
    local __var_destino="$4"

    local ruta_dir; ruta_dir=$(_ftp_src_ruta_servicio "$servicio" "$os")
    local url_paquete="${_FTP_SRC_PROTO}://${_FTP_SRC_HOST}:${_FTP_SRC_PORT}${ruta_dir}/${archivo}"
    local url_sha256="${_FTP_SRC_PROTO}://${_FTP_SRC_HOST}:${_FTP_SRC_PORT}${ruta_dir}/${archivo}.sha256"
    local destino_local="${_FTP_SRC_TMPDIR}/${archivo}"
    local sha256_local="${_FTP_SRC_TMPDIR}/${archivo}.sha256"

    separator
    msg_info "Descargando desde repositorio FTP"
    separator
    echo ""
    msg_info "Servidor : ${_FTP_SRC_HOST}:${_FTP_SRC_PORT}"
    msg_info "Archivo  : ${archivo}"
    echo ""

    # Paso 1: Descargar el paquete
    msg_process "Descargando ${archivo}..."
    if ! _ftp_src_curl \
            -o "$destino_local" \
            "$url_paquete" 2>/dev/null; then
        msg_error "No se pudo descargar: ${archivo}"
        msg_info  "Ruta FTP: ${ruta_dir}/${archivo}"
        return 1
    fi

    if [[ ! -s "$destino_local" ]]; then
        msg_error "El archivo descargado está vacío"
        rm -f "$destino_local"
        return 1
    fi
    msg_success "Descarga completada: $(du -h "$destino_local" | cut -f1)"

    # Paso 2: Descargar el .sha256
    msg_process "Descargando hash de integridad..."
    if ! _ftp_src_curl \
            -o "$sha256_local" \
            "$url_sha256" 2>/dev/null || [[ ! -s "$sha256_local" ]]; then
        msg_alert "No se encontró archivo .sha256 en el FTP"
        msg_alert "Continuando sin verificación de integridad"
        printf -v "$__var_destino" "%s" "$destino_local"
        return 0
    fi
    msg_success "Hash descargado"

    # Paso 3: Verificar integridad
    msg_process "Verificando integridad SHA256..."

    # El .sha256 puede tener el nombre de archivo con o sin ruta
    # Normalizamos para que sha256sum -c funcione desde el directorio temporal
    local hash_esperado; hash_esperado=$(awk '{print $1}' "$sha256_local")
    local hash_real; hash_real=$(sha256sum "$destino_local" | awk '{print $1}')

    if [[ "$hash_esperado" == "$hash_real" ]]; then
        msg_success "Integridad verificada — SHA256 coincide"
        msg_info    "  ${hash_real:0:16}...${hash_real: -8}"
    else
        msg_error "¡INTEGRIDAD COMPROMETIDA! El SHA256 NO coincide"
        msg_info  "  Esperado : ${hash_esperado:0:32}..."
        msg_info  "  Real     : ${hash_real:0:32}..."
        msg_error "El archivo puede estar corrupto o haber sido alterado"
        rm -f "$destino_local" "$sha256_local"
        return 1
    fi

    printf -v "$__var_destino" "%s" "$destino_local"
    return 0
}

# -----------------------------------------------------------------------------
# ftp_src_instalar_rpm
#
# Instala un RPM descargado desde el FTP usando dnf.
# $1 = ruta local del archivo RPM
# $2 = nombre del servicio (para logs)
# -----------------------------------------------------------------------------
ftp_src_instalar_rpm() {
    local rpm_path="$1"
    local servicio="$2"
    local nombre; nombre=$(basename "$rpm_path")

    separator
    msg_info "Instalando ${nombre} desde RPM local"
    separator
    echo ""

    if ! [[ "$rpm_path" =~ \.rpm$ ]]; then
        msg_error "El archivo no es un RPM: ${nombre}"
        return 1
    fi

    # Verificar que el RPM es válido
    msg_process "Verificando paquete RPM..."
    if ! rpm -K "$rpm_path" &>/dev/null && \
       ! rpm --nosignature -K "$rpm_path" &>/dev/null; then
        msg_alert "No se pudo verificar la firma del RPM — continuando"
    else
        msg_success "RPM válido"
    fi

    # dnf5 eliminó localinstall — se usa "dnf install" con ruta absoluta
    msg_process "Instalando RPM con dnf..."
    if sudo dnf install -y --nogpgcheck "$rpm_path" 2>&1 \
       | while IFS= read -r linea; do echo "    $linea"; done; then

        # Verificar instalación
        local paquete_nombre
        paquete_nombre=$(rpm -qp --queryformat "%{NAME}" "$rpm_path" 2>/dev/null)
        if rpm -q "$paquete_nombre" &>/dev/null; then
            local ver_inst
            ver_inst=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$paquete_nombre")
            msg_success "Instalado: ${paquete_nombre} v${ver_inst}"
            return 0
        else
            msg_error "dnf reportó éxito pero el paquete no aparece instalado"
            return 1
        fi
    else
        msg_error "Error durante la instalación del RPM"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# ftp_src_flujo_completo
#
# Orquesta el flujo completo de instalación desde FTP:
#   conectar → listar → seleccionar → descargar → verificar → instalar
#
# $1 = servicio (httpd|nginx|tomcat)
# $2 = variable destino para la versión instalada (para http_crear_index)
#
# Retorna 0 si la instalación fue exitosa.
# -----------------------------------------------------------------------------
ftp_src_flujo_completo() {
    local servicio="$1"
    local __var_version="${2:-}"

    # Paso 1: Credenciales FTP
    ftp_src_conectar || return 1
    echo ""

    # Paso 2: Seleccionar versión desde FTP
    local archivo_sel=""
    ftp_src_seleccionar_version "$servicio" "Linux" archivo_sel || return 1
    echo ""

    # Paso 3: Descargar y verificar
    local rpm_local=""
    ftp_src_descargar_verificar "$servicio" "Linux" "$archivo_sel" rpm_local || return 1
    echo ""

    # Paso 4: Instalar
    ftp_src_instalar_rpm "$rpm_local" "$servicio" || return 1

    # Devolver versión instalada si se pidió
    if [[ -n "$__var_version" ]]; then
        local paquete_nombre
        paquete_nombre=$(rpm -qp --queryformat "%{NAME}" "$rpm_local" 2>/dev/null)
        local ver
        ver=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$paquete_nombre" 2>/dev/null)
        printf -v "$__var_version" "%s" "$ver"
    fi

    return 0
}

export -f ftp_src_conectar
export -f ftp_src_listar_versiones
export -f ftp_src_seleccionar_version
export -f ftp_src_descargar_verificar
export -f ftp_src_instalar_rpm
export -f ftp_src_flujo_completo
export -f _ftp_src_curl
export -f _ftp_src_listar_dir
export -f _ftp_src_ruta_servicio
export -f _ftp_src_extension_servicio
export -f _ftp_src_limpiar