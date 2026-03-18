#!/bin/bash
# =============================================================================
# ftp_repo_builder.sh — Construye el repositorio local de paquetes HTTP
#
# Descarga paquetes para Linux (RPM Fedora) y Windows, genera SHA256.
# La carpeta resultante se sube manualmente al FTP via FileZilla.
#
# Estructura generada en ~/ftp_repo/ (o la ruta que elijas):
#   http/
#   ├── Linux/
#   │   ├── Apache/   → httpd-*.rpm  + .sha256
#   │   ├── Nginx/    → nginx-*.rpm  + .sha256
#   │   └── Tomcat/   → tomcat*.rpm  + .sha256
#   └── Windows/
#       ├── Apache/   → httpd-*-win64-*.zip + .sha256  (ApacheLounge)
#       ├── Nginx/    → nginx-*.zip + .sha256          (nginx.org)
#       └── Tomcat/   → apache-tomcat-*.exe + .sha256  (apache.org)
#
# Uso:
#   bash ftp_repo_builder.sh
#   bash ftp_repo_builder.sh ~/mis_paquetes
#
# Requiere: curl, dnf, sha256sum
# Plataforma: Fedora 43 Workstation (o cualquier Fedora con dnf)
# =============================================================================

set -uo pipefail

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
# Directorio de salida (permanente — se sube a mano con FileZilla)
# ─────────────────────────────────────────────────────────────────────────────
WORK_DIR="${1:-${HOME}/ftp_repo}"

# Estructura local
LINUX_DIR="${WORK_DIR}/http/Linux"
WIN_DIR="${WORK_DIR}/http/Windows"
MAX_VERSIONS=5  # minimo 3 (latest, stable, anterior)

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
    local paquete="$1"
    local servicio="$2"
    local destino="${LINUX_DIR}/${servicio}"

    mkdir -p "$destino"
    _sep
    _info "Linux — ${servicio} (RPM)"
    _sep

    # dnf5 (Fedora 43) usa "list --showduplicates"
    # dnf4 usa "repoquery --showduplicates"
    _proc "Consultando versiones en repositorio DNF..."
    local versiones=""

    # Intentar dnf5 primero
    versiones=$(dnf list --showduplicates "$paquete" 2>/dev/null \
                | grep "^${paquete}\." \
                | awk '{print $2}' \
                | sort -Vr | uniq | head -"$MAX_VERSIONS")

    # Fallback dnf4
    if [[ -z "$versiones" ]]; then
        versiones=$(dnf repoquery \
                        --arch "$(uname -m)" \
                        --showduplicates \
                        --queryformat "%{version}-%{release}.%{arch}" \
                        "$paquete" 2>/dev/null \
                    | grep -v "^$" | sort -Vr | uniq | head -"$MAX_VERSIONS")
    fi

    # Si pocas versiones, consultar updates-testing
    if [[ $(echo "$versiones" | grep -c .) -lt 2 ]]; then
        _proc "Pocas versiones — consultando updates-testing..."
        local versiones_extra=""
        versiones_extra=$(dnf list --showduplicates \
                            --enablerepo="updates-testing" \
                            "$paquete" 2>/dev/null \
                        | grep "^${paquete}\." \
                        | awk '{print $2}' \
                        | sort -Vr | uniq | head -"$MAX_VERSIONS")
        versiones=$(printf '%s\n%s' "$versiones" "$versiones_extra" \
                    | grep -v "^$" | sort -Vr | uniq | head -"$MAX_VERSIONS")
    fi

    if [[ -z "$versiones" ]]; then
        _warn "No se encontraron versiones para '${paquete}' — omitiendo"
        return 0
    fi

    local total; total=$(echo "$versiones" | grep -c .)
    _ok "Versiones encontradas: ${total}"
    echo "$versiones" | head -5 | sed 's/^/    /'
    [[ $total -gt 5 ]] && echo "    ..."

    # Descargar cada RPM
    local descargados=0
    while IFS= read -r ver; do
        [[ -z "$ver" ]] && continue
        _proc "Descargando ${paquete}-${ver}..."

        if dnf download \
                --destdir "$destino" \
                "${paquete}-${ver}" &>/dev/null 2>&1; then
            # Encontrar el RPM recién descargado
            local rpm_file
            rpm_file=$(find "$destino" -name "*.rpm" -newer "$destino" \
                       2>/dev/null | tail -1)
            if [[ -n "$rpm_file" ]]; then
                _generar_sha256 "$rpm_file" > /dev/null
                (( descargados++ ))
                _ok "$(basename "$rpm_file")"
            fi
        else
            _warn "No se pudo descargar ${paquete}-${ver}"
        fi
        # Actualizar timestamp de referencia
        touch "$destino"
    done <<< "$versiones"

    _ok "${servicio} Linux: ${descargados} paquete(s) descargado(s)"
}

_descargar_linux() {
    echo ""
    _info "=== Descargando paquetes Linux (RPM) ==="
    echo ""

    _descargar_linux_paquete "httpd"  "Apache"
    _descargar_linux_paquete "nginx"  "Nginx"

    # Tomcat en Fedora 43 puede llamarse tomcat, tomcat10, tomcat11, etc.
    # Buscar el nombre correcto del paquete disponible
    local tomcat_pkg=""
    for _pkg in tomcat11 tomcat10 tomcat; do
        if dnf repoquery --arch "$(uname -m)" "$_pkg" &>/dev/null 2>&1 | grep -q .; then
            tomcat_pkg="$_pkg"
            break
        fi
        # repoquery puede no devolver nada si no existe — verificar con info
        if dnf info "$_pkg" &>/dev/null 2>&1; then
            tomcat_pkg="$_pkg"
            break
        fi
    done

    if [[ -n "$tomcat_pkg" ]]; then
        _info "Paquete Tomcat detectado: $tomcat_pkg"
        _descargar_linux_paquete "$tomcat_pkg" "Tomcat"
    else
        _warn "No se encontró paquete Tomcat en los repos — omitiendo"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# WINDOWS — Apache (ApacheLounge)
# Fuente oficial de binarios Apache para Windows con hashes SHA256 publicados
# ─────────────────────────────────────────────────────────────────────────────
_descargar_windows_apache() {
    local destino="${WIN_DIR}/Apache"
    mkdir -p "$destino"
    _sep
    _info "Windows — Apache (ApacheLounge VS18 Win64)"
    _sep

    _proc "Consultando versiones en ApacheLounge..."

    # Los ZIPs están en /download/VS18/ — requiere -L y User-Agent de navegador
    local pagina
    pagina=$(curl -sfL \
             -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
             --connect-timeout 15 \
             "https://www.apachelounge.com/download/VS18/" 2>/dev/null) || {
        _warn "No se pudo acceder a ApacheLounge — omitiendo Apache Windows"
        return 0
    }

    # Patrón real: httpd-2.4.66-260223-Win64-VS18.zip
    local urls
    urls=$(echo "$pagina" \
           | grep -oP 'href="[^"]*httpd-[0-9.]+-[0-9]+-Win64-VS[0-9]+\.zip"' \
           | grep -oP '"[^"]+"' | tr -d '"' \
           | sed 's|^/|https://www.apachelounge.com/|' \
           | sort -Vr | head -"$MAX_VERSIONS")

    if [[ -z "$urls" ]]; then
        _warn "No se encontraron binarios Apache Win64 en ApacheLounge"
        return 0
    fi

    local descargados=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        local nombre; nombre=$(basename "$url")
        local archivo="${destino}/${nombre}"

        if [[ -f "$archivo" ]]; then
            _info "${nombre} ya existe — omitiendo"
            (( descargados++ ))
            continue
        fi

        _proc "Descargando ${nombre}..."
        if curl -fL \
                -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
                --connect-timeout 60 \
                --progress-bar \
                -o "$archivo" "$url" 2>/dev/null && [[ -s "$archivo" ]]; then

            # Buscar .txt con checksums SHA256
            local checksum_url
            checksum_url=$(echo "$pagina" \
                | grep -oP "href=\"[^\"]*${nombre}[^\"]*\.txt\"" \
                | grep -oP '"[^"]+"' | tr -d '"' | head -1)
            if [[ -n "$checksum_url" ]]; then
                [[ "$checksum_url" != http* ]] && \
                    checksum_url="https://www.apachelounge.com${checksum_url}"
                local sha256_oficial
                sha256_oficial=$(curl -sf -A "Mozilla/5.0" "$checksum_url" 2>/dev/null \
                    | grep -i "sha256" | grep -oP '[a-fA-F0-9]{64}' | head -1)
                if [[ -n "$sha256_oficial" ]]; then
                    local sha256_local
                    sha256_local=$(sha256sum "$archivo" | awk '{print $1}')
                    if [[ "${sha256_local,,}" == "${sha256_oficial,,}" ]]; then
                        _ok "SHA256 verificado contra oficial"
                    else
                        _warn "SHA256 no coincide — guardando hash local"
                    fi
                fi
            fi
            _generar_sha256 "$archivo" > /dev/null
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
           | grep -oP 'href="[^"]*/nginx-[\d.]+\.zip"' \
           | grep -oP '"[^"]+"' | tr -d '"' \
           | sed 's|^/download/|https://nginx.org/download/|' \
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
    echo -e "${CYAN}  FTP Repo Builder — Repositorio local de paquetes HTTP${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    _info "Directorio de salida: ${WORK_DIR}"
    _info "Versiones por paquete: ${MAX_VERSIONS}"
    echo ""

    _verificar_deps
    echo ""

    _menu_seleccion
    echo ""

    # Crear estructura de directorios
    mkdir -p "${LINUX_DIR}/Apache" "${LINUX_DIR}/Nginx" "${LINUX_DIR}/Tomcat"
    mkdir -p "${WIN_DIR}/Apache"   "${WIN_DIR}/Nginx"   "${WIN_DIR}/Tomcat"
    _ok "Estructura creada en: ${WORK_DIR}/http/"
    echo ""

    # Descargar
    $DESCARGAR_LINUX   && _descargar_linux
    $DESCARGAR_WINDOWS && _descargar_windows

    _mostrar_resumen

    _sep
    _ok "Listo — sube la carpeta con FileZilla:"
    echo ""
    _info "  Origen  (local) : ${WORK_DIR}/http/"
    _info "  Destino (FTP)   : directorio personal del usuario FTP"
    echo ""
    _info "Estructura:"
    echo "    http/"
    echo "    ├── Linux/"
    echo "    │   ├── Apache/   (*.rpm + *.sha256)"
    echo "    │   ├── Nginx/    (*.rpm + *.sha256)"
    echo "    │   └── Tomcat/   (*.rpm + *.sha256)"
    echo "    └── Windows/"
    echo "        ├── Apache/   (*.zip + *.sha256)"
    echo "        ├── Nginx/    (*.zip + *.sha256)"
    echo "        └── Tomcat/   (*.exe + *.sha256)"
    echo ""
}

main "$@"