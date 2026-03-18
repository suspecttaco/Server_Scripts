#!/bin/bash
# =============================================================================
# ftp_repo_builder.sh — Construye el repositorio FTP de paquetes HTTP
#
# Descarga paquetes para Linux (Fedora/RPM) y Windows, genera hashes SHA256,
# organiza la estructura y sube al servidor FTP vsftpd.
#
# Estructura en el FTP (dentro del directorio personal del usuario FTP):
#   http/
#   ├── Linux/
#   │   ├── Apache/   → httpd RPMs + .sha256
#   │   ├── Nginx/    → nginx RPMs + .sha256
#   │   └── Tomcat/   → tomcat RPMs + .sha256
#   └── Windows/
#       ├── Apache/   → ApacheLounge .zip + .sha256
#       ├── Nginx/    → nginx .zip + .sha256
#       └── Tomcat/   → Tomcat .exe + .sha256
#
# Uso: bash ftp_repo_builder.sh
# Requiere: curl, wget, dnf (repoquery), sha256sum, python3
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Colores
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'

_ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
_err()     { echo -e "${RED}[ERROR]${NC} $1" >&2; }
_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
_info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
_proc()    { echo -e "${BLUE}[---]${NC}   $1"; }
_input()   { echo -ne "${CYAN}→${NC} $1"; }
_sep()     { echo -e "${CYAN}------------------------------------------------------------${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Directorio de trabajo temporal
# ─────────────────────────────────────────────────────────────────────────────
WORK_DIR=$(mktemp -d /tmp/ftp_repo_XXXXXX)
trap 'echo ""; _info "Limpiando directorio temporal..."; rm -rf "$WORK_DIR"' EXIT

# Estructura local
LINUX_DIR="${WORK_DIR}/http/Linux"
WIN_DIR="${WORK_DIR}/http/Windows"
MAX_VERSIONS=10

# ─────────────────────────────────────────────────────────────────────────────
# Verificar dependencias
# ─────────────────────────────────────────────────────────────────────────────
_verificar_deps() {
    _info "Verificando dependencias..."
    local faltantes=()
    for cmd in curl wget sha256sum python3 dnf; do
        command -v "$cmd" &>/dev/null || faltantes+=("$cmd")
    done

    if [[ ${#faltantes[@]} -gt 0 ]]; then
        _warn "Instalando dependencias faltantes: ${faltantes[*]}"
        sudo dnf install -y "${faltantes[@]}" &>/dev/null || {
            _err "No se pudieron instalar: ${faltantes[*]}"
            exit 1
        }
    fi
    _ok "Dependencias OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# Pedir credenciales FTP
# ─────────────────────────────────────────────────────────────────────────────
_pedir_credenciales_ftp() {
    _sep
    echo -e "  ${CYAN}Credenciales del servidor FTP destino${NC}"
    _sep
    echo ""

    _input "IP del servidor FTP: "; read -r FTP_HOST
    [[ -z "$FTP_HOST" ]] && { _err "La IP no puede estar vacía"; exit 1; }

    _input "Puerto FTP [21]: "; read -r FTP_PORT
    FTP_PORT="${FTP_PORT:-21}"

    _input "Usuario FTP: "; read -r FTP_USER
    [[ -z "$FTP_USER" ]] && { _err "El usuario no puede estar vacío"; exit 1; }

    _input "Contraseña: "; read -rs FTP_PASS; echo
    [[ -z "$FTP_PASS" ]] && { _err "La contraseña no puede estar vacía"; exit 1; }

    _input "Directorio destino en el FTP [/]: "; read -r FTP_DEST_DIR
    FTP_DEST_DIR="${FTP_DEST_DIR:-/}"
    # Normalizar: quitar trailing slash salvo que sea /
    [[ "$FTP_DEST_DIR" != "/" ]] && FTP_DEST_DIR="${FTP_DEST_DIR%/}"

    echo ""
    _ok "Credenciales recibidas"
    _info "  Host    : ${FTP_HOST}:${FTP_PORT}"
    _info "  Usuario : ${FTP_USER}"
    _info "  Destino : ${FTP_DEST_DIR}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Verificar conectividad FTP
# ─────────────────────────────────────────────────────────────────────────────
_verificar_ftp() {
    _proc "Verificando conexión FTP..."
    if curl -s --connect-timeout 10 \
            --ftp-ssl \
            -u "${FTP_USER}:${FTP_PASS}" \
            "ftp://${FTP_HOST}:${FTP_PORT}/" \
            -l &>/dev/null; then
        _ok "Conexión FTP establecida (FTPS)"
        FTP_SSL="--ftp-ssl"
    elif curl -s --connect-timeout 10 \
            -u "${FTP_USER}:${FTP_PASS}" \
            "ftp://${FTP_HOST}:${FTP_PORT}/" \
            -l &>/dev/null; then
        _ok "Conexión FTP establecida (FTP plano)"
        FTP_SSL=""
    else
        _err "No se pudo conectar al FTP en ${FTP_HOST}:${FTP_PORT}"
        _info "Verifique IP, puerto y credenciales"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Generar SHA256 de un archivo y guardarlo como .sha256
# ─────────────────────────────────────────────────────────────────────────────
_generar_sha256() {
    local archivo="$1"
    local nombre_base; nombre_base=$(basename "$archivo")
    local dir; dir=$(dirname "$archivo")

    _proc "Generando SHA256 para ${nombre_base}..."
    local hash; hash=$(sha256sum "$archivo" | awk '{print $1}')
    echo "${hash}  ${nombre_base}" > "${dir}/${nombre_base}.sha256"
    _ok "SHA256: ${hash:0:16}...  → ${nombre_base}.sha256"
    echo "$hash"
}

# ─────────────────────────────────────────────────────────────────────────────
# Verificar hash oficial contra el generado localmente
# $1 = archivo descargado
# $2 = URL del hash oficial (sha256 o sha512)
# $3 = "sha256"|"sha512"
# Retorna 0 si coincide o si no hay hash oficial (genera local)
# ─────────────────────────────────────────────────────────────────────────────
_verificar_hash_oficial() {
    local archivo="$1"
    local url_hash="${2:-}"
    local tipo="${3:-sha256}"
    local nombre_base; nombre_base=$(basename "$archivo")

    if [[ -z "$url_hash" ]]; then
        _warn "Sin hash oficial — generando SHA256 localmente"
        _generar_sha256 "$archivo" > /dev/null
        return 0
    fi

    _proc "Descargando hash oficial..."
    local hash_oficial
    hash_oficial=$(curl -sf --connect-timeout 10 "$url_hash" 2>/dev/null \
                   | awk '{print $1}' | tr '[:upper:]' '[:lower:]') || {
        _warn "No se pudo descargar el hash oficial — generando localmente"
        _generar_sha256 "$archivo" > /dev/null
        return 0
    }

    local hash_local
    if [[ "$tipo" == "sha512" ]]; then
        hash_local=$(sha512sum "$archivo" | awk '{print $1}')
    else
        hash_local=$(sha256sum "$archivo" | awk '{print $1}')
    fi
    hash_local=$(echo "$hash_local" | tr '[:upper:]' '[:lower:]')

    if [[ "$hash_local" == "$hash_oficial" ]]; then
        _ok "Hash verificado contra oficial (${tipo})"
        # Guardar como sha256 para uniformidad (el ws_ftp_source.sh siempre usa sha256sum)
        echo "${hash_local}  ${nombre_base}" > "$(dirname "$archivo")/${nombre_base}.sha256"
        return 0
    else
        _err "Hash NO coincide con el oficial"
        _info "  Oficial : ${hash_oficial:0:32}..."
        _info "  Local   : ${hash_local:0:32}..."
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# LINUX — Descargar RPMs via dnf download
# ─────────────────────────────────────────────────────────────────────────────
_descargar_linux_paquete() {
    local paquete="$1"   # httpd | nginx | tomcat
    local servicio="$2"  # Apache | Nginx | Tomcat  (nombre display)
    local destino="${LINUX_DIR}/${servicio}"

    mkdir -p "$destino"
    _sep
    _info "Linux — ${servicio} (RPM)"
    _sep

    # Obtener versiones disponibles vía repoquery
    _proc "Consultando versiones en repositorio DNF..."
    local versiones
    versiones=$(dnf repoquery \
                    --arch "$(uname -m)" \
                    --showduplicates \
                    --queryformat "%{version}-%{release}.%{arch}" \
                    "$paquete" 2>/dev/null \
                | grep -v "^$" | sort -Vr | uniq | head -"$MAX_VERSIONS")

    if [[ -z "$versiones" ]]; then
        _warn "No se encontraron versiones para '${paquete}' — omitiendo"
        return 0
    fi

    local total; total=$(echo "$versiones" | wc -l)
    _ok "Versiones encontradas: ${total}"
    echo "$versiones" | head -5 | sed 's/^/    /'
    [[ $total -gt 5 ]] && echo "    ..."

    # Descargar cada RPM
    local descargados=0
    while IFS= read -r ver; do
        [[ -z "$ver" ]] && continue
        local pkg_ver="${paquete}-${ver}"
        _proc "Descargando ${pkg_ver}..."

        # dnf download descarga el RPM al directorio indicado
        if dnf download \
                --arch "$(uname -m)" \
                --destdir "$destino" \
                "${pkg_ver}" &>/dev/null 2>&1; then

            # Encontrar el RPM descargado (puede tener nombre ligeramente diferente)
            local rpm_file
            rpm_file=$(find "$destino" -name "${paquete}-${ver%.*}*.rpm" \
                       -newer "${destino}/.timestamp" 2>/dev/null | head -1)
            # Fallback: cualquier RPM nuevo
            [[ -z "$rpm_file" ]] && \
                rpm_file=$(find "$destino" -name "*.rpm" \
                          -newer "${destino}/.timestamp_prev" 2>/dev/null | tail -1)

            if [[ -n "$rpm_file" ]]; then
                _generar_sha256 "$rpm_file" > /dev/null
                (( descargados++ ))
                _ok "$(basename "$rpm_file")"
            fi
        else
            _warn "No se pudo descargar ${pkg_ver}"
        fi
        # Actualizar timestamp para detectar archivos nuevos en próxima iteración
        touch "${destino}/.timestamp"
    done <<< "$versiones"

    # Limpiar timestamps temporales
    rm -f "${destino}/.timestamp" "${destino}/.timestamp_prev"

    _ok "${servicio} Linux: ${descargados} paquete(s) descargado(s)"
}

# ─────────────────────────────────────────────────────────────────────────────
# LINUX — Descargar todos los servicios
# ─────────────────────────────────────────────────────────────────────────────
_descargar_linux() {
    echo ""
    _info "=== Descargando paquetes Linux (RPM) ==="
    echo ""

    _descargar_linux_paquete "httpd"  "Apache"
    _descargar_linux_paquete "nginx"  "Nginx"
    _descargar_linux_paquete "tomcat" "Tomcat"
}

# ─────────────────────────────────────────────────────────────────────────────
# WINDOWS — Apache (ApacheLounge)
# Fuente oficial de binarios Apache para Windows con hashes SHA256 publicados
# ─────────────────────────────────────────────────────────────────────────────
_descargar_windows_apache() {
    local destino="${WIN_DIR}/Apache"
    mkdir -p "$destino"
    _sep
    _info "Windows — Apache (ApacheLounge)"
    _sep

    _proc "Consultando versiones en ApacheLounge..."

    # Obtener página de descargas de ApacheLounge
    local pagina
    pagina=$(curl -sf --connect-timeout 15 \
             "https://www.apachelounge.com/download/" 2>/dev/null) || {
        _warn "No se pudo acceder a ApacheLounge — omitiendo Apache Windows"
        return 0
    }

    # Extraer URLs de ZIPs de Apache (ej: httpd-2.4.62-250207-win64-VS17.zip)
    local urls
    urls=$(echo "$pagina" \
           | grep -oP 'href="[^"]*httpd-[\d.]+-[^"]*win64[^"]*\.zip"' \
           | grep -oP '"[^"]+"' | tr -d '"' \
           | sed 's|^/|https://www.apachelounge.com/|' \
           | grep -v "debug\|devel\|mod_" \
           | sort -Vr | head -"$MAX_VERSIONS")

    if [[ -z "$urls" ]]; then
        _warn "No se encontraron binarios Apache en ApacheLounge"
        return 0
    fi

    local descargados=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        local nombre; nombre=$(basename "$url")
        local archivo="${destino}/${nombre}"

        _proc "Descargando ${nombre}..."
        if curl -sf --connect-timeout 30 -L \
                --progress-bar \
                -o "$archivo" "$url" 2>/dev/null; then
            # Buscar hash SHA256 oficial en la página
            local hash_url
            hash_url=$(echo "$pagina" \
                       | grep -oP "href=\"[^\"]*${nombre%.zip}[^\"]*sha256[^\"]*\"" \
                       | grep -oP '"[^"]+"' | tr -d '"' | head -1)
            [[ -n "$hash_url" && "$hash_url" != http* ]] && \
                hash_url="https://www.apachelounge.com/${hash_url}"

            _verificar_hash_oficial "$archivo" "$hash_url" "sha256"
            (( descargados++ ))
        else
            _warn "No se pudo descargar ${nombre}"
            rm -f "$archivo"
        fi
    done <<< "$urls"

    _ok "Apache Windows: ${descargados} paquete(s)"
}

# ─────────────────────────────────────────────────────────────────────────────
# WINDOWS — Nginx
# nginx.org publica ZIPs oficiales para Windows. Sin hash oficial — se genera local.
# ─────────────────────────────────────────────────────────────────────────────
_descargar_windows_nginx() {
    local destino="${WIN_DIR}/Nginx"
    mkdir -p "$destino"
    _sep
    _info "Windows — Nginx (nginx.org)"
    _sep

    _proc "Consultando versiones en nginx.org..."
    local pagina
    pagina=$(curl -sf --connect-timeout 15 \
             "https://nginx.org/en/download.html" 2>/dev/null) || {
        _warn "No se pudo acceder a nginx.org — omitiendo Nginx Windows"
        return 0
    }

    # Extraer URLs de ZIPs Windows (nginx/nginx-X.Y.Z.zip)
    local urls
    urls=$(echo "$pagina" \
           | grep -oP 'href="[^"]*/nginx/nginx-[\d.]+\.zip"' \
           | grep -oP '"[^"]+"' | tr -d '"' \
           | sed 's|^/|https://nginx.org|' \
           | sort -Vr | head -"$MAX_VERSIONS")

    if [[ -z "$urls" ]]; then
        _warn "No se encontraron ZIPs de Nginx para Windows"
        return 0
    fi

    local descargados=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        local nombre; nombre=$(basename "$url")
        local archivo="${destino}/${nombre}"

        _proc "Descargando ${nombre}..."
        if curl -sf --connect-timeout 30 -L \
                --progress-bar \
                -o "$archivo" "$url" 2>/dev/null; then
            # Nginx no publica hashes — generar localmente
            _generar_sha256 "$archivo" > /dev/null
            (( descargados++ ))
        else
            _warn "No se pudo descargar ${nombre}"
            rm -f "$archivo"
        fi
    done <<< "$urls"

    _ok "Nginx Windows: ${descargados} paquete(s)"
}

# ─────────────────────────────────────────────────────────────────────────────
# WINDOWS — Tomcat
# apache.org publica instaladores .exe con SHA512 oficial
# ─────────────────────────────────────────────────────────────────────────────
_descargar_windows_tomcat() {
    local destino="${WIN_DIR}/Tomcat"
    mkdir -p "$destino"
    _sep
    _info "Windows — Tomcat (apache.org)"
    _sep

    # Versiones major activas de Tomcat
    local versiones_major=("11" "10" "9")
    local descargados=0

    for major in "${versiones_major[@]}"; do
        _proc "Consultando Tomcat ${major}.x..."

        local cgi_url
        if [[ "$major" == "9" ]]; then
            cgi_url="https://tomcat.apache.org/download-90.cgi"
        else
            cgi_url="https://tomcat.apache.org/download-${major}.cgi"
        fi

        local pagina
        pagina=$(curl -sf --connect-timeout 15 "$cgi_url" 2>/dev/null) || {
            _warn "No se pudo acceder a la página de Tomcat ${major}.x"
            continue
        }

        # Detectar versión más reciente (ej: 10.1.52)
        local version_full
        version_full=$(echo "$pagina" \
                       | grep -oP 'v[\d.]+' | grep "^v${major}\." \
                       | sort -Vr | head -1 | tr -d 'v')

        [[ -z "$version_full" ]] && {
            _warn "No se encontró versión para Tomcat ${major}.x"
            continue
        }

        _info "Versión más reciente: Tomcat ${version_full}"

        # URL del instalador Windows 64-bit .exe
        local exe_url="https://dlcdn.apache.org/tomcat/tomcat-${major}/v${version_full}/bin/apache-tomcat-${version_full}.exe"
        local sha512_url="https://downloads.apache.org/tomcat/tomcat-${major}/v${version_full}/bin/apache-tomcat-${version_full}.exe.sha512"
        local nombre="apache-tomcat-${version_full}.exe"
        local archivo="${destino}/${nombre}"

        _proc "Descargando ${nombre}..."
        if curl -sf --connect-timeout 60 -L \
                --progress-bar \
                -o "$archivo" "$exe_url" 2>/dev/null && [[ -s "$archivo" ]]; then
            _verificar_hash_oficial "$archivo" "$sha512_url" "sha512"
            (( descargados++ ))
        else
            _warn "No se pudo descargar ${nombre}"
            rm -f "$archivo"
            # Intentar mirror alternativo
            _proc "Intentando mirror alternativo..."
            local mirror_url="https://archive.apache.org/dist/tomcat/tomcat-${major}/v${version_full}/bin/apache-tomcat-${version_full}.exe"
            if curl -sf --connect-timeout 60 -L \
                    --progress-bar \
                    -o "$archivo" "$mirror_url" 2>/dev/null && [[ -s "$archivo" ]]; then
                _verificar_hash_oficial "$archivo" "$sha512_url" "sha512"
                (( descargados++ ))
            else
                rm -f "$archivo"
            fi
        fi
    done

    _ok "Tomcat Windows: ${descargados} paquete(s)"
}

# ─────────────────────────────────────────────────────────────────────────────
# WINDOWS — Descargar todos
# ─────────────────────────────────────────────────────────────────────────────
_descargar_windows() {
    echo ""
    _info "=== Descargando paquetes Windows ==="
    echo ""
    _info "Nota: IIS no tiene binario descargable — se activa como feature de Windows Server."
    echo ""

    _descargar_windows_apache
    _descargar_windows_nginx
    _descargar_windows_tomcat
}

# ─────────────────────────────────────────────────────────────────────────────
# Mostrar resumen de lo descargado
# ─────────────────────────────────────────────────────────────────────────────
_mostrar_resumen() {
    _sep
    _info "Resumen de paquetes descargados:"
    _sep
    echo ""

    local total=0
    local servicios=("Apache" "Nginx" "Tomcat")

    for svc in "${servicios[@]}"; do
        local linux_count=0 win_count=0
        [[ -d "${LINUX_DIR}/${svc}" ]] && \
            linux_count=$(find "${LINUX_DIR}/${svc}" -name "*.rpm" 2>/dev/null | wc -l)

        # Extensiones Windows
        if [[ -d "${WIN_DIR}/${svc}" ]]; then
            win_count=$(find "${WIN_DIR}/${svc}" \
                        -name "*.zip" -o -name "*.exe" -o -name "*.msi" \
                        2>/dev/null | wc -l)
        fi

        printf "  %-10s  Linux: %-3s RPM   Windows: %-3s paquetes\n" \
               "${svc}" "$linux_count" "$win_count"
        (( total += linux_count + win_count ))
    done

    echo ""
    _ok "Total: ${total} paquete(s) + ${total} archivo(s) .sha256"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Subir al servidor FTP
# ─────────────────────────────────────────────────────────────────────────────
_subir_ftp() {
    _sep
    _info "Subiendo al servidor FTP..."
    _sep
    echo ""

    local errores=0
    local subidos=0

    # Recorrer todos los archivos (paquetes + hashes)
    while IFS= read -r archivo; do
        [[ -z "$archivo" ]] && continue

        # Calcular ruta relativa desde WORK_DIR
        local ruta_relativa="${archivo#${WORK_DIR}/}"
        local ruta_ftp="${FTP_DEST_DIR}/${ruta_relativa}"
        # Normalizar doble slash
        ruta_ftp=$(echo "$ruta_ftp" | sed 's|//|/|g')

        local dir_ftp; dir_ftp=$(dirname "$ruta_ftp")
        local nombre; nombre=$(basename "$archivo")

        # Crear directorio en FTP (curl crea directorios con --ftp-create-dirs)
        _proc "Subiendo ${ruta_relativa}..."

        if curl -sf \
                --connect-timeout 30 \
                $FTP_SSL \
                -u "${FTP_USER}:${FTP_PASS}" \
                --ftp-create-dirs \
                -T "$archivo" \
                "ftp://${FTP_HOST}:${FTP_PORT}${ruta_ftp}" 2>/dev/null; then
            (( subidos++ ))
        else
            _warn "Error al subir: ${nombre}"
            (( errores++ ))
        fi
    done < <(find "$WORK_DIR" -type f \( \
                -name "*.rpm" \
                -o -name "*.zip" \
                -o -name "*.exe" \
                -o -name "*.msi" \
                -o -name "*.sha256" \
             \) | sort)

    echo ""
    _ok "Subidos: ${subidos} archivo(s)"
    [[ $errores -gt 0 ]] && _warn "Errores: ${errores} archivo(s) no se pudieron subir"
    return $(( errores > 0 ? 1 : 0 ))
}

# ─────────────────────────────────────────────────────────────────────────────
# Menú de selección de qué descargar
# ─────────────────────────────────────────────────────────────────────────────
_menu_seleccion() {
    _sep
    echo -e "  ${CYAN}¿Qué paquetes descargar?${NC}"
    _sep
    echo ""
    echo -e "  ${BLUE}1)${NC} Linux + Windows (completo)"
    echo -e "  ${BLUE}2)${NC} Solo Linux (RPM)"
    echo -e "  ${BLUE}3)${NC} Solo Windows"
    echo -e "  ${BLUE}0)${NC} Salir"
    echo ""
    _input "Opción: "; read -r opcion

    case "$opcion" in
        1) DESCARGAR_LINUX=true;  DESCARGAR_WINDOWS=true  ;;
        2) DESCARGAR_LINUX=true;  DESCARGAR_WINDOWS=false ;;
        3) DESCARGAR_LINUX=false; DESCARGAR_WINDOWS=true  ;;
        0) exit 0 ;;
        *) _err "Opción inválida"; exit 1 ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}  FTP Repo Builder — Repositorio de paquetes HTTP${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    _verificar_deps
    echo ""

    _pedir_credenciales_ftp
    echo ""

    _verificar_ftp
    echo ""

    _menu_seleccion
    echo ""

    # Crear estructura de directorios
    mkdir -p "${LINUX_DIR}/Apache" "${LINUX_DIR}/Nginx" "${LINUX_DIR}/Tomcat"
    mkdir -p "${WIN_DIR}/Apache"   "${WIN_DIR}/Nginx"   "${WIN_DIR}/Tomcat"

    # Descargar
    $DESCARGAR_LINUX   && _descargar_linux
    $DESCARGAR_WINDOWS && _descargar_windows

    _mostrar_resumen

    # Confirmar antes de subir
    _input "¿Subir al servidor FTP ${FTP_HOST}? [S/N]: "; read -r confirm
    if [[ ! "${confirm^^}" =~ ^(S|SI|Y|YES)$ ]]; then
        _info "Cancelado. Los archivos quedan en: ${WORK_DIR}"
        trap - EXIT   # No limpiar el directorio temporal
        exit 0
    fi

    echo ""
    _subir_ftp

    echo ""
    _sep
    _ok "Repositorio FTP construido exitosamente"
    _sep
    echo ""
    _info "Estructura en el FTP (${FTP_DEST_DIR}):"
    echo "    http/"
    echo "    ├── Linux/"
    echo "    │   ├── Apache/   (RPM + .sha256)"
    echo "    │   ├── Nginx/    (RPM + .sha256)"
    echo "    │   └── Tomcat/   (RPM + .sha256)"
    echo "    └── Windows/"
    echo "        ├── Apache/   (.zip ApacheLounge + .sha256)"
    echo "        ├── Nginx/    (.zip oficial + .sha256)"
    echo "        └── Tomcat/   (.exe oficial + .sha256)"
    echo ""
}

main "$@"