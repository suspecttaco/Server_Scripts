#!/bin/bash
# =============================================================================
# ws_lib/ws_security_audit.sh — Auditoría de seguridad HTTP — Fedora Server
#
# Independiente: funciona solo o dot-sourced desde ws_manager.sh
# Si se ejecuta solo auto-carga lib/ui.sh, lib/utils.sh, ws_utils.sh, ws_validators.sh
#
# Pruebas (10 categorías):
#   1.  Contexto de ejecución (local vs SSH) e IPs del servidor
#   2.  Servicios HTTP instalados y activos (rpm + systemd + puerto)
#   3.  Security Headers (X-Frame-Options, X-Content-Type, X-XSS, Referrer-Policy)
#   4.  Fuga de versión en headers Server / X-Powered-By / Via
#   5.  Métodos HTTP peligrosos (TRACE/XST, TRACK, DELETE, PUT, CONNECT)
#   6.  Coherencia: puerto configurado vs puerto en escucha
#   7.  Firewall firewall-cmd (puertos del servicio y puertos default sin uso)
#   8.  Usuario dedicado: existencia, nologin, permisos webroot, acceso al FS
#   9.  Acceso y comportamiento desde IP remota (binding + headers + TRACE)
#  10.  Resumen por servicio y puntuación global de seguridad
#
# Uso:
#   sudo bash ws_security_audit.sh
#   sudo bash ws_security_audit.sh --servicio httpd
#   sudo bash ws_security_audit.sh --servicio nginx
#   sudo bash ws_security_audit.sh --servicio tomcat
#   sudo bash ws_security_audit.sh --solo-resumen
#
# Requiere: bash 4+, curl, ss, rpm, systemctl, firewall-cmd
# =============================================================================


# ─────────────────────────────────────────────────────────────────────────────
#   ARGUMENTOS
# ─────────────────────────────────────────────────────────────────────────────
_AUD_SERVICIO=""
_AUD_SOLO_RESUMEN=0

for _arg in "$@"; do
    case "$_arg" in
        --servicio=*)   _AUD_SERVICIO="${_arg#--servicio=}" ;;
        --solo-resumen) _AUD_SOLO_RESUMEN=1 ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
#   CARGA DE MÓDULOS (si este script se ejecuta de forma independiente)
#   El orden respeta la jerarquía de dependencias del proyecto:
#     utils.sh → utilsHTTP.sh → validatorsHTTP.sh
# ─────────────────────────────────────────────────────────────────────────────
_AUDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f msg_info &>/dev/null; then
    for _f in "../lib/ui.sh" "../lib/utils.sh" "ws_utils.sh" "ws_validators.sh"; do
        [[ -f ${_AUDIT_DIR}/${_f} ]] && source "${_AUDIT_DIR}/${_f}"
    done
fi

# ─────────────────────────────────────────────────────────────────────────────
#   COLORES — fallback si utils.sh no pudo cargarse
# ─────────────────────────────────────────────────────────────────────────────
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BLUE="${BLUE:-\033[0;34m}"
CYAN="${CYAN:-\033[0;36m}"
GRAY="${GRAY:-\033[0;90m}"
NC="${NC:-\033[0m}"

# ─────────────────────────────────────────────────────────────────────────────
#   CONSTANTES — fallback si utilsHTTP.sh no pudo cargarse
#   Los valores coinciden exactamente con utilsHTTP.sh del proyecto
# ─────────────────────────────────────────────────────────────────────────────
_AUD_SVC_APACHE="${HTTP_SERVICIO_APACHE:-httpd}"
_AUD_SVC_NGINX="${HTTP_SERVICIO_NGINX:-nginx}"
_AUD_SVC_TOMCAT="${HTTP_SERVICIO_TOMCAT:-tomcat}"

_AUD_WEBROOT_APACHE="${HTTP_WEBROOT_APACHE:-/var/www/html}"
_AUD_WEBROOT_NGINX="${HTTP_WEBROOT_NGINX:-/usr/share/nginx/html}"

_AUD_CONF_APACHE="${HTTP_CONF_APACHE:-/etc/httpd/conf/httpd.conf}"
_AUD_CONF_NGINX="${HTTP_CONF_NGINX:-/etc/nginx/nginx.conf}"

_AUD_USR_APACHE="${HTTP_USUARIO_APACHE:-apache}"
_AUD_USR_NGINX="${HTTP_USUARIO_NGINX:-nginx}"
_AUD_USR_TOMCAT="${HTTP_USUARIO_TOMCAT:-tomcat}"

# Puertos reservados (igual que HTTP_PUERTOS_RESERVADOS de utilsHTTP.sh)
readonly _AUD_PUERTOS_RESERVADOS=(22 25 53 3306 5432 6379 27017)

# ─────────────────────────────────────────────────────────────────────────────
#   CATÁLOGO DE SERVICIOS
#   Formato: "nombre_systemd:nombre_display:puerto_default"
#   Usado en la prueba 2 para iterar los tres servicios.
# ─────────────────────────────────────────────────────────────────────────────
readonly _AUD_CATALOGO=(
    "httpd:Apache (httpd):80"
    "nginx:Nginx:80"
    "tomcat:Tomcat:8080"
)

# ─────────────────────────────────────────────────────────────────────────────
#   ESTADO GLOBAL DE AUDITORÍA
#   Contadores reiniciados por _aud_reset() antes de cada servicio.
# ─────────────────────────────────────────────────────────────────────────────
_AUD_PASS=0
_AUD_FAIL=0
_AUD_WARN=0
_AUD_TOTAL=0
_AUD_LOG=()          # Entradas "[PASS]|[FAIL]|[WARN] mensaje || fix"

_aud_reset() {
    _AUD_PASS=0; _AUD_FAIL=0; _AUD_WARN=0; _AUD_TOTAL=0
    _AUD_LOG=()
}

# ─────────────────────────────────────────────────────────────────────────────
#   HELPERS DE SALIDA
# ─────────────────────────────────────────────────────────────────────────────
_pass() {
    echo -e "    ${GREEN}[PASS]${NC} $1"
    (( _AUD_PASS++  )); (( _AUD_TOTAL++ ))
    _AUD_LOG+=("[PASS] $1")
}

_fail() {
    echo -e "    ${RED}[FAIL]${NC} $1"
    [[ -n "${2:-}" ]] && echo -e "           ${GRAY}Fix: $2${NC}"
    (( _AUD_FAIL++  )); (( _AUD_TOTAL++ ))
    _AUD_LOG+=("[FAIL] $1${2:+ || $2}")
}

_warn() {
    echo -e "    ${YELLOW}[WARN]${NC} $1"
    [[ -n "${2:-}" ]] && echo -e "           ${GRAY}Fix: $2${NC}"
    (( _AUD_WARN++  )); (( _AUD_TOTAL++ ))
    _AUD_LOG+=("[WARN] $1${2:+ || $2}")
}

_info() {
    echo -e "    ${CYAN}[INFO]${NC} $1"
}

_sep() {
    # Imprime una cabecera de sección numerada.
    # Suprimida si --solo-resumen está activo.
    (( _AUD_SOLO_RESUMEN )) && return
    echo ""
    echo -e "  ${BLUE}┌──────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${BLUE}│  $2. $1${NC}"
    echo -e "  ${BLUE}└──────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
#   HELPER: puerto activo de un servicio vía ss -tlnp
#
#   Usa el mismo patrón que _http_obtener_puerto_activo() en FunctionsHTTP-A.sh:
#     ss -tlnp  →  grep el nombre del proceso entre comillas  →  awk $4 (Local Address)
#   Ejemplo de línea ss:
#     LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:(("httpd",pid=1234,fd=4))
# ─────────────────────────────────────────────────────────────────────────────
_aud_puerto_activo() {
    local svc="$1"   # nombre systemd: httpd | nginx | tomcat

    local puerto
    puerto=$(sudo ss -tlnp 2>/dev/null \
             | grep "\"${svc}\"" \
             | awk '{print $4}' \
             | grep -oP ':\K[0-9]+' \
             | head -1)

    # Fallback para Tomcat: el proceso visible en ss es "java", no "tomcat"
    if [[ -z "$puerto" && "$svc" == "tomcat" ]]; then
        local pid
        pid=$(sudo systemctl show tomcat --property=MainPID --value 2>/dev/null)
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            puerto=$(sudo ss -tlnp 2>/dev/null \
                     | grep "pid=${pid}," \
                     | awk '{print $4}' \
                     | grep -oP ':\K[0-9]+' \
                     | head -1)
        fi
    fi

    echo "$puerto"
}

# ─────────────────────────────────────────────────────────────────────────────
#   HELPER: puerto del archivo de configuración
#   Reutiliza exactamente la lógica de _http_leer_puerto_config() en C.sh
# ─────────────────────────────────────────────────────────────────────────────
_aud_puerto_config() {
    local svc="$1"
    local puerto=""

    case "$svc" in
        httpd)
            [[ -f "$_AUD_CONF_APACHE" ]] && \
            puerto=$(sudo grep -E "^Listen\s+[0-9]+" "$_AUD_CONF_APACHE" 2>/dev/null \
                     | awk '{print $2}' | grep -oP '[0-9]+$' | head -1)
            ;;
        nginx)
            [[ -f "$_AUD_CONF_NGINX" ]] && \
            puerto=$(sudo grep -E "^\s+listen\s+[0-9]+" "$_AUD_CONF_NGINX" 2>/dev/null \
                     | grep -oP '\d+' | head -1)
            ;;
        tomcat)
            local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
            local server_xml="${catalina}/conf/server.xml"
            [[ -f "$server_xml" ]] && \
            puerto=$(sudo grep -oP 'Connector port="\K[0-9]+(?=" protocol="HTTP)' \
                     "$server_xml" 2>/dev/null | head -1)
            ;;
    esac

    echo "$puerto"
}

# ─────────────────────────────────────────────────────────────────────────────
#   HELPER: usuario dedicado del servicio
#   Usa las mismas constantes que http_get_usuario_servicio() en utilsHTTP.sh
# ─────────────────────────────────────────────────────────────────────────────
_aud_usuario() {
    case "$1" in
        httpd)  echo "$_AUD_USR_APACHE" ;;
        nginx)  echo "$_AUD_USR_NGINX"  ;;
        tomcat) echo "$_AUD_USR_TOMCAT" ;;
        *)      echo "nobody" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
#   HELPER: webroot del servicio
#   Usa http_get_webroot() si está disponible; si no, copia su lógica.
# ─────────────────────────────────────────────────────────────────────────────
_aud_webroot() {
    if declare -f http_get_webroot &>/dev/null; then
        http_get_webroot "$1"
        return
    fi
    case "$1" in
        httpd)  echo "$_AUD_WEBROOT_APACHE" ;;
        nginx)  echo "$_AUD_WEBROOT_NGINX"  ;;
        tomcat)
            local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
            echo "${catalina}/webapps/ROOT"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
#   PRUEBA 1 — Servicios HTTP instalados y activos
#
#   Construye _AUD_SERVICIOS_ACTIVOS: array de "svc:nombre:puerto"
#   para que el bucle principal sepa qué auditar.
# ─────────────────────────────────────────────────────────────────────────────
_aud_servicios() {
    _sep "Servicios HTTP Instalados y Activos" "2"

    _AUD_SERVICIOS_ACTIVOS=()   # array global: "svc:nombre:puerto"

    local entrada
    for entrada in "${_AUD_CATALOGO[@]}"; do
        local svc="${entrada%%:*}"
        local resto="${entrada#*:}"
        local nombre="${resto%:*}"

        # ── Instalado? (rpm -q, igual que http_verificar_estado en A.sh) ──
        local paquete
        if declare -f http_nombre_paquete &>/dev/null; then
            paquete=$(http_nombre_paquete "$svc")
        else
            paquete="$svc"
        fi

        if ! rpm -q "$paquete" &>/dev/null; then
            _info "${nombre} — no instalado"
            continue
        fi

        local version_rpm
        version_rpm=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$paquete" 2>/dev/null)

        # ── Activo? (systemd) ─────────────────────────────────────────────
        if ! sudo systemctl is-active --quiet "$svc" 2>/dev/null; then
            local estado
            estado=$(sudo systemctl is-active "$svc" 2>/dev/null)
            _warn "${nombre} — instalado (${version_rpm}) pero INACTIVO (${estado})" \
                  "sudo systemctl start ${svc}"
            continue
        fi

        # ── Puerto en escucha ─────────────────────────────────────────────
        local puerto
        puerto=$(_aud_puerto_activo "$svc")

        _AUD_SERVICIOS_ACTIVOS+=("${svc}:${nombre}:${puerto:-0}")

        if [[ -n "$puerto" ]]; then
            _pass "${nombre} — ACTIVO [${version_rpm}]  puerto ${puerto}/tcp"
        else
            _warn "${nombre} — ACTIVO [${version_rpm}]  sin puerto detectado"
        fi
    done

    if [[ ${#_AUD_SERVICIOS_ACTIVOS[@]} -eq 0 ]]; then
        _warn "Ningún servicio HTTP activo — no hay nada que auditar"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#   PRUEBA 2 — Security Headers
#
#   Headers requeridos por la rúbrica: los mismos que aplica
#   _http_seguridad_apache() / _http_seguridad_nginx() en FunctionsHTTP-C.sh
# ─────────────────────────────────────────────────────────────────────────────
_aud_security_headers() {
    local svc="$1" nombre="$2" puerto="$3"
    _sep "Security Headers — ${nombre}" "3"

    if [[ -z "$puerto" || "$puerto" == "0" ]]; then
        _warn "Puerto no detectado — prueba omitida"
        return
    fi

    local url="http://localhost:${puerto}"
    _info "Consultando: ${url}"
    echo ""

    local resp
    resp=$(curl -sI --max-time 6 "$url" 2>&1)
    if [[ $? -ne 0 ]]; then
        _fail "Sin respuesta HTTP en ${url}" \
              "Verificar que el servicio está activo: sudo systemctl status ${svc}"
        return
    fi

    # Headers requeridos + valor esperado (cadena que debe aparecer en el valor)
    # Orden y valores coinciden con lo que escribe _http_seguridad_apache/nginx en C.sh
    local -a hdrs_req=(
        "X-Frame-Options:SAMEORIGIN:Previene Clickjacking"
        "X-Content-Type-Options:nosniff:Evita MIME sniffing"
        "X-XSS-Protection:1; mode=block:Protección básica XSS"
        "Referrer-Policy::Controla datos del referer"
    )

    local linea
    for linea in "${hdrs_req[@]}"; do
        local hdr="${linea%%:*}"
        local resto_l="${linea#*:}"
        local esperado="${resto_l%%:*}"
        local desc="${resto_l##*:}"

        local valor
        valor=$(echo "$resp" | grep -i "^${hdr}:" | cut -d: -f2- | tr -d '\r' | xargs)

        if [[ -n "$valor" ]]; then
            if [[ -n "$esperado" && "$valor" != *"$esperado"* ]]; then
                _warn "${hdr}: '${valor}' (se esperaba contener: '${esperado}')"
            else
                _pass "${hdr}: ${valor}"
            fi
        else
            _fail "${hdr}: AUSENTE — ${desc}" \
                  "Grupo C → opción 2 del gestor HTTP"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#   PRUEBA 3 — Fuga de versión en headers
#
#   Verifica Server, X-Powered-By y Via.
#   Alineado con _http_mon_verificar_headers_seguridad() en FunctionsHTTP-E.sh
# ─────────────────────────────────────────────────────────────────────────────
_aud_fuga_version() {
    local svc="$1" nombre="$2" puerto="$3"
    _sep "Fuga de Versión en Headers — ${nombre}" "4"

    if [[ -z "$puerto" || "$puerto" == "0" ]]; then
        _warn "Puerto no detectado — prueba omitida"
        return
    fi

    local resp
    resp=$(curl -sI --max-time 6 "http://localhost:${puerto}" 2>&1)
    [[ $? -ne 0 ]] && { _fail "Sin respuesta HTTP"; return; }

    # ── Header Server ─────────────────────────────────────────────────────
    # Con ServerTokens Prod (Apache) o server_tokens off (Nginx) no debe
    # aparecer versión numérica. Con ServerTokens Full sí aparece: riesgo.
    local srv
    srv=$(echo "$resp" | grep -i "^Server:" | cut -d: -f2- | tr -d '\r' | xargs)

    if [[ -n "$srv" ]]; then
        if echo "$srv" | grep -qE "[0-9]+\.[0-9]+"; then
            _fail "Server revela versión exacta: '${srv}'" \
                  "Apache: ServerTokens Prod en security.conf | Nginx: server_tokens off | Grupo C → opción 2"
        elif echo "$srv" | grep -qiE "(apache|nginx|tomcat|httpd)"; then
            _warn "Server revela tecnología sin versión: '${srv}'" \
                  "Óptimo: enmascarar o eliminar el header Server"
        else
            _pass "Server no revela versión ni tecnología: '${srv}'"
        fi
    else
        _pass "Header Server ausente (configuración óptima)"
    fi

    # ── X-Powered-By ──────────────────────────────────────────────────────
    local xpb
    xpb=$(echo "$resp" | grep -i "^X-Powered-By:" | cut -d: -f2- | tr -d '\r' | xargs)
    if [[ -n "$xpb" ]]; then
        _fail "X-Powered-By presente: '${xpb}'" \
              "Header unset X-Powered-By en security.conf"
    else
        _pass "X-Powered-By ausente (correcto)"
    fi

    # ── Via ───────────────────────────────────────────────────────────────
    local via
    via=$(echo "$resp" | grep -i "^Via:" | cut -d: -f2- | tr -d '\r' | xargs)
    if [[ -n "$via" ]]; then
        _warn "Header Via presente — puede revelar proxies internos: '${via}'" \
              "Eliminar si no es necesario para la arquitectura"
    else
        _pass "Header Via ausente"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#   PRUEBA 4 — Métodos HTTP peligrosos
#
#   Verifica TRACE, TRACK, DELETE, PUT, CONNECT.
#   La lista y los bloques de remediación son los mismos que gestiona
#   http_restringir_metodos() en FunctionsHTTP-C.sh
# ─────────────────────────────────────────────────────────────────────────────
_aud_metodos_http() {
    local svc="$1" nombre="$2" puerto="$3"
    _sep "Métodos HTTP Peligrosos — ${nombre}" "5"

    if [[ -z "$puerto" || "$puerto" == "0" ]]; then
        _warn "Puerto no detectado — prueba omitida"
        return
    fi

    local url="http://localhost:${puerto}"

    # Formato: "METODO:descripción del riesgo"
    local -a metodos=(
        "TRACE:Cross-Site Tracing (XST)"
        "TRACK:Variante de TRACE"
        "DELETE:Eliminación arbitraria de recursos"
        "PUT:Escritura arbitraria de archivos"
        "CONNECT:Tunelado de tráfico / SSRF proxy"
    )

    local entrada
    for entrada in "${metodos[@]}"; do
        local met="${entrada%%:*}"
        local desc="${entrada##*:}"

        local codigo
        codigo=$(curl -s -o /dev/null -w "%{http_code}" \
                      -X "$met" --max-time 6 "$url" 2>/dev/null)

        case "$codigo" in
            405|501|403|400)
                _pass "${met} bloqueado — HTTP ${codigo}"
                ;;
            200)
                _fail "${met} PERMITIDO — HTTP ${codigo} (${desc})" \
                      "Grupo C → opción 3 del gestor HTTP (restringir métodos)"
                ;;
            000)
                _warn "${met} — timeout o conexión rechazada (sin código HTTP)"
                ;;
            *)
                _warn "${met} devuelve HTTP ${codigo} — verificar manualmente (${desc})"
                ;;
        esac
    done

    # ── XST: TRACE con cuerpo — verificar eco ────────────────────────────
    # Un servidor vulnerable a XST devuelve el cuerpo de la petición en la
    # respuesta de TRACE, permitiendo robar cookies via JavaScript.
    echo ""
    _info "Verificando Cross-Site Tracing (XST) con cuerpo en TRACE..."
    local xst_token="xst-probe-${RANDOM}${RANDOM}"
    local xst_resp
    xst_resp=$(curl -s -X TRACE --max-time 6 -d "$xst_token" "$url" 2>/dev/null)

    if echo "$xst_resp" | grep -qF "$xst_token"; then
        _fail "TRACE hace eco del cuerpo — vulnerable a XST" \
              "TraceEnable Off en security.conf (Apache) | Grupo C → opción 2"
    else
        _pass "TRACE no devuelve eco del cuerpo — no vulnerable a XST"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#   PRUEBA 5 — Coherencia: puerto configurado vs puerto activo
# ─────────────────────────────────────────────────────────────────────────────
_aud_coherencia_puerto() {
    local svc="$1" nombre="$2" puerto_activo="$3"
    _sep "Puerto Configurado vs Puerto en Escucha — ${nombre}" "6"

    local puerto_conf
    puerto_conf=$(_aud_puerto_config "$svc")

    _info "Puerto en archivo de config : ${puerto_conf:-no detectado}"
    _info "Puerto activo en escucha    : ${puerto_activo:-no detectado}"
    echo ""

    # ── Coherencia entre config y escucha ─────────────────────────────────
    if [[ -n "$puerto_conf" && -n "$puerto_activo" && "$puerto_activo" != "0" ]]; then
        if [[ "$puerto_conf" == "$puerto_activo" ]]; then
            _pass "Config y escucha coinciden en puerto ${puerto_activo}/tcp"
        else
            _fail "Discrepancia: config=${puerto_conf}/tcp  vs  escucha=${puerto_activo}/tcp" \
                  "sudo systemctl restart ${svc}"
        fi
    elif [[ -z "$puerto_activo" || "$puerto_activo" == "0" ]]; then
        _fail "Servicio no está en escucha en ningún puerto"
    else
        _warn "No se pudo leer el archivo de config — solo se verificó el puerto activo"
    fi

    # ── Puerto reservado ──────────────────────────────────────────────────
    if [[ -n "$puerto_activo" && "$puerto_activo" != "0" ]]; then
        local p reservado=0
        for p in "${_AUD_PUERTOS_RESERVADOS[@]}"; do
            [[ "$puerto_activo" == "$p" ]] && { reservado=1; break; }
        done
        if (( reservado )); then
            _fail "Puerto ${puerto_activo} está en la lista de puertos reservados del sistema" \
                  "Usar un puerto diferente (ver HTTP_PUERTOS_RESERVADOS en ws_utils.sh)"
        else
            _pass "Puerto ${puerto_activo} no colisiona con servicios reservados"
        fi
    fi

    # ── Binding: accesible desde red o solo loopback ──────────────────────
    if [[ -n "$puerto_activo" && "$puerto_activo" != "0" ]]; then
        local binding
        binding=$(sudo ss -tlnp 2>/dev/null \
                  | grep ":${puerto_activo} " \
                  | awk '{print $4}' | head -1)

        if echo "$binding" | grep -qE "^0\.0\.0\.0:|^\*:|^\[::\]:"; then
            _pass "Binding en ${binding} — accesible desde toda la red"
        elif echo "$binding" | grep -q "127.0.0.1"; then
            _warn "Binding solo en 127.0.0.1 — no accesible desde red externa" \
                  "Ajustar la directiva Listen / listen en el archivo de configuración"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#   PRUEBA 6 — Firewall (firewall-cmd)
# ─────────────────────────────────────────────────────────────────────────────
_aud_firewall() {
    local svc="$1" nombre="$2" puerto="$3"
    _sep "Firewall (firewall-cmd) — ${nombre}" "7"

    # ── firewalld activo ──────────────────────────────────────────────────
    if ! sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        _fail "firewalld INACTIVO — el servidor está completamente expuesto" \
              "sudo systemctl enable --now firewalld"
        return
    fi
    _pass "firewalld activo"
    echo ""

    if [[ -z "$puerto" || "$puerto" == "0" ]]; then
        _warn "Puerto no detectado — verificación de reglas omitida"
        return
    fi

    # ── Regla para el puerto del servicio ─────────────────────────────────
    local tiene_regla=0

    # Primero: como puerto explícito (--list-ports)
    if sudo firewall-cmd --list-ports 2>/dev/null | grep -q "${puerto}/tcp"; then
        tiene_regla=1
        _pass "Regla de entrada para ${puerto}/tcp encontrada en firewall-cmd"
    fi

    # Segundo: puerto 80 puede estar abierto vía servicio "http"
    if (( ! tiene_regla )) && [[ "$puerto" == "80" ]]; then
        if sudo firewall-cmd --list-services 2>/dev/null | grep -qw "http"; then
            tiene_regla=1
            _pass "Puerto 80/tcp abierto vía servicio 'http' en firewall-cmd"
        fi
    fi

    if (( ! tiene_regla )); then
        _fail "Puerto ${puerto}/tcp sin regla de entrada en firewall-cmd" \
              "sudo firewall-cmd --permanent --add-port=${puerto}/tcp && sudo firewall-cmd --reload"
    fi

    # ── Puerto DEFAULT abierto sin estar en uso ───────────────────────────
    # Si el servicio usa un puerto distinto al default, el default no debe
    # seguir abierto en el firewall (regla innecesaria = superficie de ataque).
    local puerto_default
    case "$svc" in
        tomcat) puerto_default=8080 ;;
        *)      puerto_default=80   ;;
    esac

    if [[ "$puerto" != "$puerto_default" ]]; then
        local default_abierto=0
        sudo firewall-cmd --list-ports 2>/dev/null \
            | grep -q "${puerto_default}/tcp" && default_abierto=1
        # Puerto 80 también puede estar via servicio "http"
        if [[ "$puerto_default" == "80" ]]; then
            sudo firewall-cmd --list-services 2>/dev/null \
                | grep -qw "http" && default_abierto=1
        fi

        if (( default_abierto )); then
            _fail "Puerto default ${puerto_default}/tcp abierto sin estar en uso" \
                  "sudo firewall-cmd --permanent --remove-port=${puerto_default}/tcp && sudo firewall-cmd --reload"
        else
            _pass "Puerto default ${puerto_default}/tcp sin regla innecesaria"
        fi
    fi

    # ── Zona activa ───────────────────────────────────────────────────────
    echo ""
    local zona
    zona=$(sudo firewall-cmd --get-active-zones 2>/dev/null \
           | grep -v "interfaces\|sources" | head -1)
    [[ -n "$zona" ]] && _info "Zona activa: ${zona}"
}

# ─────────────────────────────────────────────────────────────────────────────
#   PRUEBA 7 — Usuario dedicado y permisos del webroot
#
#   Verifica los mismos puntos que http_verificar_usuario_servicio() en A.sh
#   y que http_crear_usuario_dedicado() en B.sh:
#     - Existencia del usuario
#     - Shell /sbin/nologin o /bin/false
#     - No miembro de wheel
#     - Propietario del webroot
#     - Acceso a directorios sensibles del sistema
# ─────────────────────────────────────────────────────────────────────────────
_aud_usuario_webroot() {
    local svc="$1" nombre="$2"
    _sep "Usuario Dedicado y Permisos del Webroot — ${nombre}" "8"

    local usuario webroot
    usuario=$(_aud_usuario "$svc")
    webroot=$(_aud_webroot "$svc")

    _info "Usuario del servicio : ${usuario}"
    _info "Webroot              : ${webroot}"
    echo ""

    # ── 1. Existencia del usuario ─────────────────────────────────────────
    if ! id "$usuario" &>/dev/null; then
        _fail "Usuario '${usuario}' NO existe en el sistema" \
              "Instalar el servicio desde Grupo B del gestor HTTP"
        return   # Sin usuario, el resto de la prueba no tiene sentido
    fi

    local uid shell home
    uid=$(id -u "$usuario" 2>/dev/null)
    shell=$(getent passwd "$usuario" | cut -d: -f7)
    home=$(getent passwd "$usuario" | cut -d: -f6)

    _pass "Usuario '${usuario}' existe (UID: ${uid}  Home: ${home})"

    # ── 2. Sin shell interactiva ──────────────────────────────────────────
    # Los paquetes de Fedora ya crean el usuario con /sbin/nologin.
    # http_crear_usuario_dedicado() lo corrige si es diferente.
    if [[ "$shell" == "/sbin/nologin" || "$shell" == "/bin/false" ]]; then
        _pass "Shell de '${usuario}': ${shell} (sin login interactivo)"
    else
        _warn "Shell de '${usuario}': ${shell} — permite login interactivo" \
              "sudo usermod -s /sbin/nologin ${usuario}"
    fi

    # ── 3. No debe pertenecer a wheel ─────────────────────────────────────
    if groups "$usuario" 2>/dev/null | grep -qE "\bwheel\b"; then
        _fail "Usuario '${usuario}' pertenece a wheel — exceso de privilegios" \
              "sudo gpasswd -d ${usuario} wheel"
    else
        _pass "Usuario '${usuario}' no pertenece a wheel (mínimo privilegio)"
    fi

    # ── 4. Estado de contraseña ───────────────────────────────────────────
    local pass_estado
    pass_estado=$(sudo passwd -S "$usuario" 2>/dev/null | awk '{print $2}')
    case "$pass_estado" in
        L|LK) _pass "Cuenta '${usuario}' bloqueada — sin contraseña activa" ;;
        NP)   _pass "Cuenta '${usuario}' sin contraseña establecida" ;;
        *)    _warn "Cuenta '${usuario}' puede tener contraseña activa (estado: ${pass_estado})" \
                    "sudo passwd -l ${usuario}" ;;
    esac

    echo ""

    # ── 5. Propietario y permisos del webroot ─────────────────────────────
    if [[ ! -d "$webroot" ]]; then
        _warn "Webroot '${webroot}' no existe todavía"
    else
        local propietario perms
        propietario=$(stat -c '%U' "$webroot" 2>/dev/null)
        perms=$(stat -c '%a' "$webroot" 2>/dev/null)
        _info "Webroot propietario: ${propietario}  permisos: ${perms}"

        if [[ "$propietario" == "$usuario" || "$propietario" == "root" ]]; then
            _pass "Propietario del webroot correcto (${propietario})"
        else
            _warn "Webroot es de '${propietario}' — se esperaba '${usuario}' o 'root'" \
                  "sudo chown ${usuario}: ${webroot}"
        fi

        # Lectura: el usuario debe poder leer el webroot
        if sudo -u "$usuario" test -r "$webroot" 2>/dev/null; then
            _pass "Usuario '${usuario}' tiene lectura sobre el webroot"
        else
            _warn "No se pudo confirmar lectura de '${usuario}' sobre ${webroot}" \
                  "sudo chmod o+r ${webroot}"
        fi

        # Escritura: el usuario NO debe poder escribir en el webroot
        if sudo -u "$usuario" test -w "$webroot" 2>/dev/null; then
            _warn "Usuario '${usuario}' tiene ESCRITURA sobre el webroot — no recomendado" \
                  "sudo chmod o-w ${webroot}"
        else
            _pass "Usuario '${usuario}' sin escritura sobre el webroot (mínimo privilegio)"
        fi
    fi

    echo ""

    # ── 6. Acceso a directorios sensibles ─────────────────────────────────
    # Misma lista que http_verificar_usuario_servicio() en FunctionsHTTP-A.sh
    _info "Verificando acceso a rutas sensibles del sistema..."
    echo ""

    local -a dirs_sensibles=("/root" "/home" "/etc/shadow" "/etc/sudoers")
    local d
    for d in "${dirs_sensibles[@]}"; do
        [[ ! -e "$d" ]] && continue
        if sudo -u "$usuario" test -r "$d" 2>/dev/null; then
            _fail "Usuario '${usuario}' puede leer: ${d}" \
                  "sudo chmod o-r ${d}  (revisar ACLs con getfacl)"
        else
            _pass "Sin acceso a: ${d}"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#   PRUEBA 8 — Acceso y comportamiento desde IP remota
#
#   Repite las pruebas 3 (headers), 4 (Server) y 5 (TRACE) pero usando
#   la IP real del servidor en lugar de localhost.
#   Detecta configuraciones que solo aplican headers en loopback.
# ─────────────────────────────────────────────────────────────────────────────
_aud_acceso_remoto() {
    local svc="$1" nombre="$2" puerto="$3"
    _sep "Acceso y Comportamiento desde IP Remota — ${nombre}" "9"

    if [[ -z "$puerto" || "$puerto" == "0" ]]; then
        _warn "Puerto no detectado — prueba omitida"
        return
    fi

    local ip_local="${_CTX_IP_LOCAL}"
    _info "Probando vía IP de red: http://${ip_local}:${puerto}"
    echo ""

    local resp_ip
    resp_ip=$(curl -sI --max-time 6 "http://${ip_local}:${puerto}" 2>&1)

    if [[ $? -eq 0 ]]; then
        _pass "Servicio accesible vía IP ${ip_local}  puerto ${puerto}/tcp"

        # Security headers desde la IP real
        local -a hdrs_check=(
            "X-Frame-Options"
            "X-Content-Type-Options"
            "X-XSS-Protection"
        )
        local hdr
        for hdr in "${hdrs_check[@]}"; do
            local val
            val=$(echo "$resp_ip" | grep -i "^${hdr}:" | cut -d: -f2- | tr -d '\r' | xargs)
            if [[ -n "$val" ]]; then
                _pass "Vía IP — ${hdr}: ${val}"
            else
                _fail "Vía IP — ${hdr}: AUSENTE" \
                      "Verificar que la config no limita headers a <VirtualHost 127.0.0.1>"
            fi
        done

        # Fuga de versión desde IP
        local srv_val
        srv_val=$(echo "$resp_ip" | grep -i "^Server:" | cut -d: -f2- | tr -d '\r' | xargs)
        if [[ -n "$srv_val" ]] && echo "$srv_val" | grep -qE "[0-9]+\.[0-9]+"; then
            _fail "Vía IP — Server revela versión: '${srv_val}'" \
                  "La supresión de versión debe aplicarse a nivel global, no de VirtualHost"
        else
            _pass "Vía IP — Server no revela versión"
        fi

        # TRACE desde IP
        local c_trace
        c_trace=$(curl -s -o /dev/null -w "%{http_code}" \
                       -X TRACE --max-time 6 \
                       "http://${ip_local}:${puerto}" 2>/dev/null)
        case "$c_trace" in
            405|501|403|400) _pass "Vía IP — TRACE bloqueado (HTTP ${c_trace})" ;;
            200) _fail "Vía IP — TRACE PERMITIDO desde red (HTTP ${c_trace})" \
                       "TraceEnable Off / restricción de métodos debe aplicarse globalmente" ;;
            *) _warn "Vía IP — TRACE devuelve HTTP ${c_trace}" ;;
        esac

    else
        _fail "Servicio NO accesible vía IP ${ip_local}  puerto ${puerto}" \
              "Verificar binding (debe ser 0.0.0.0) y reglas de firewall-cmd"
        echo ""
        _info "Bindings actuales en ${puerto}:"
        sudo ss -tlnp 2>/dev/null \
            | grep ":${puerto} " \
            | awk '{printf "        %s\n", $4}'
    fi

    # Comandos para verificación manual desde el cliente
    echo ""
    if (( _CTX_ES_SSH )) && [[ -n "$_CTX_IP_SSH" ]]; then
        _info "Sesión SSH activa desde ${_CTX_IP_SSH} — ejecuta desde tu máquina cliente:"
    else
        _info "Para verificar desde un cliente remoto:"
    fi
    echo ""
    echo -e "    ${CYAN}curl -I http://${ip_local}:${puerto}${NC}"
    echo -e "    ${CYAN}curl -X TRACE  http://${ip_local}:${puerto}${NC}"
    echo -e "    ${CYAN}curl -X DELETE http://${ip_local}:${puerto}${NC}"
    echo -e "    ${CYAN}curl -sI http://${ip_local}:${puerto} | grep -i server${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
#   RESUMEN POR SERVICIO (prueba 10)
#   Imprime el cuadro de puntuación y devuelve el score como stdout
#   para que el caller pueda construir el score global.
# ─────────────────────────────────────────────────────────────────────────────
_aud_resumen() {
    local nombre_svc="$1"
    local p=$_AUD_PASS f=$_AUD_FAIL w=$_AUD_WARN t=$_AUD_TOTAL

    local score=0
    (( t > 0 )) && score=$(( (p * 100) / t ))

    local nivel color_score
    if   (( score >= 85 )); then nivel="SEGURO";    color_score="$GREEN"
    elif (( score >= 65 )); then nivel="ACEPTABLE"; color_score="$CYAN"
    elif (( score >= 45 )); then nivel="MEJORABLE"; color_score="$YELLOW"
    else                        nivel="CRITICO";    color_score="$RED"
    fi

    # Todo el output visual va a /dev/tty para que $() solo capture el número.
    # Si no hay /dev/tty (no interactivo), redirigir a stderr como fallback.
    local _tty
    { _tty=/dev/tty; } 2>/dev/null || _tty=/dev/stderr

    {
        echo ""
        separator
        printf  "  ${BLUE}║${NC}  Resumen: %-46s${BLUE}║${NC}\n" "$nombre_svc"
        separator
        printf  "  ${BLUE}║${NC}  ${GREEN}[PASS]${NC} %-3s  ${RED}[FAIL]${NC} %-3s  ${YELLOW}[WARN]${NC} %-3s  Total: %-6s   ${BLUE}║${NC}\n" \
                "$p" "$f" "$w" "$t"
        printf  "  ${BLUE}║${NC}  Puntuacion: ${color_score}%s%%${NC} — %-38s${BLUE}║${NC}\n" \
                "$score" "$nivel"
        separator
        echo ""

        if (( f > 0 )); then
            echo -e "  ${RED}Problemas críticos:${NC}"
            local entrada
            for entrada in "${_AUD_LOG[@]}"; do
                [[ "$entrada" == \[FAIL\]* ]] || continue
                local msg="${entrada#\[FAIL\] }"
                echo -e "    ${RED}·${NC} ${msg%% || *}"
            done
            echo ""
        fi

        if (( w > 0 )); then
            echo -e "  ${YELLOW}Advertencias:${NC}"
            for entrada in "${_AUD_LOG[@]}"; do
                [[ "$entrada" == \[WARN\]* ]] || continue
                local msg="${entrada#\[WARN\] }"
                echo -e "    ${YELLOW}·${NC} ${msg%% || *}"
            done
            echo ""
        fi
    } > "$_tty"

    echo "$score"   # único stdout: el número que captura $(_aud_resumen ...)
}

# ─────────────────────────────────────────────────────────────────────────────
#   FUNCIÓN PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────
_aud_main() {
    clear

    draw_header "AUDITORIA DE SEGURIDAD HTTP"
    # ── Prueba 1: contexto ────────────────────────────────────────────────
    _aud_reset
    #_aud_contexto

    # ── Prueba 2: inventario de servicios activos ─────────────────────────
    _aud_servicios

    if [[ ${#_AUD_SERVICIOS_ACTIVOS[@]} -eq 0 ]]; then
        echo ""
        echo -e "  ${YELLOW}No hay servicios HTTP activos para auditar.${NC}"
        echo ""
        read -rp "  Presiona Enter para continuar..."
        return
    fi

    # ── Selección de servicio(s) ──────────────────────────────────────────
    local -a seleccionados=()

    if [[ -n "$_AUD_SERVICIO" ]]; then
        # Modo no interactivo: --servicio=<nombre>
        local entrada
        for entrada in "${_AUD_SERVICIOS_ACTIVOS[@]}"; do
            [[ "${entrada%%:*}" == "$_AUD_SERVICIO" ]] && \
            seleccionados+=("$entrada")
        done
        if [[ ${#seleccionados[@]} -eq 0 ]]; then
            echo -e "  ${YELLOW}Servicio '${_AUD_SERVICIO}' no activo — auditando todos.${NC}"
            seleccionados=("${_AUD_SERVICIOS_ACTIVOS[@]}")
        fi
    else
        # Modo interactivo: menú de selección
        echo ""
        echo -e "  ${BLUE}Servicios disponibles para auditar:${NC}"
        echo ""
        local i=0 entrada
        for entrada in "${_AUD_SERVICIOS_ACTIVOS[@]}"; do
            local nombre="${entrada#*:}"; nombre="${nombre%:*}"
            local prt="${entrada##*:}"
            printf "    ${BLUE}%d)${NC} %-22s puerto %s/tcp\n" \
                   $(( i + 1 )) "$nombre" "$prt"
            (( i++ ))
        done
        local op_max=$(( ${#_AUD_SERVICIOS_ACTIVOS[@]} + 1 ))
        printf "    ${BLUE}%d)${NC} Auditar TODOS los servicios activos\n" "$op_max"
        echo ""

        local opcion
        while true; do
            read -rp "  ${CYAN}[INPUT]${NC} Seleccione [1-${op_max}]: " opcion
            [[ "$opcion" =~ ^[0-9]+$ ]] && \
            (( opcion >= 1 && opcion <= op_max )) && break
            echo -e "  ${RED}[ERROR]${NC} Ingrese un número entre 1 y ${op_max}"
        done

        if (( opcion == op_max )); then
            seleccionados=("${_AUD_SERVICIOS_ACTIVOS[@]}")
        else
            seleccionados=("${_AUD_SERVICIOS_ACTIVOS[$(( opcion - 1 ))]}")
        fi
    fi

    # ── Ejecutar las 8 pruebas para cada servicio seleccionado ────────────
    declare -A _scores   # nombre_servicio → score

    local entrada
    for entrada in "${seleccionados[@]}"; do
        local svc="${entrada%%:*}"
        local resto="${entrada#*:}"
        local nombre="${resto%:*}"
        local puerto="${resto##*:}"

        echo ""
        separator
        echo -e "  ${CYAN}  AUDITANDO: ${nombre} — puerto ${puerto}/tcp${NC}"
        separator

        _aud_reset

        _aud_security_headers  "$svc" "$nombre" "$puerto"   # prueba 3
        _aud_fuga_version       "$svc" "$nombre" "$puerto"   # prueba 4
        _aud_metodos_http       "$svc" "$nombre" "$puerto"   # prueba 5
        _aud_coherencia_puerto  "$svc" "$nombre" "$puerto"   # prueba 6
        _aud_firewall           "$svc" "$nombre" "$puerto"   # prueba 7
        _aud_usuario_webroot    "$svc" "$nombre"             # prueba 8
        _aud_acceso_remoto      "$svc" "$nombre" "$puerto"   # prueba 9

        _scores["$nombre"]=$(_aud_resumen "$nombre")         # prueba 10
    done

    # ── Puntuación global (si se auditaron varios servicios) ──────────────
    if (( ${#seleccionados[@]} > 1 )); then
        local suma=0 count=0 k
        for k in "${!_scores[@]}"; do
            (( suma += _scores[$k] ))
            (( count++ ))
        done
        local prom=$(( suma / count ))

        local col_prom
        if   (( prom >= 85 )); then col_prom="$GREEN"
        elif (( prom >= 65 )); then col_prom="$CYAN"
        elif (( prom >= 45 )); then col_prom="$YELLOW"
        else                        col_prom="$RED"
        fi

        echo ""
        separator
        echo -e "  ${BLUE}  PUNTUACION GLOBAL DE SEGURIDAD${NC}"
        separator
        for k in "${!_scores[@]}"; do
            local c
            if   (( _scores[$k] >= 85 )); then c="$GREEN"
            elif (( _scores[$k] >= 65 )); then c="$CYAN"
            elif (( _scores[$k] >= 45 )); then c="$YELLOW"
            else                              c="$RED"
            fi
            printf "    %-24s ${c}%s%%${NC}\n" "$k" "${_scores[$k]}"
        done
        echo ""
        echo -e "    Promedio general         : ${col_prom}${prom}%${NC}"
        separator
        echo ""
        echo -e "  ${CYAN}Referencia:${NC} OWASP Secure Headers · Practica 6 Rubrica"
        echo -e "  ${CYAN}Correccion:${NC} Grupo C del gestor HTTP (opciones 2 y 3)"
        echo ""
    fi

    read -rp "  Presiona Enter para continuar..."
}