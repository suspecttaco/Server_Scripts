#!/bin/bash
# =============================================================================
# ssl_lib/ssl_certs.sh — Generación y gestión de certificados self-signed
#
# Todos los campos del certificado son ingresados por el usuario.
# No hay valores hardcodeados.
#
# Requiere: openssl, source lib/ui.sh
# =============================================================================

# -----------------------------------------------------------------------------
# _ssl_verificar_openssl  (interna)
# Verifica que openssl esté instalado; intenta instalarlo si no.
# -----------------------------------------------------------------------------
_ssl_verificar_openssl() {
    if command -v openssl &>/dev/null; then
        return 0
    fi
    msg_alert "openssl no encontrado — instalando..."
    if sudo dnf install -y openssl &>/dev/null; then
        msg_success "openssl instalado"
        return 0
    fi
    msg_error "No se pudo instalar openssl"
    return 1
}

# -----------------------------------------------------------------------------
# _ssl_crear_directorio  (interna)
# Crea el directorio destino con permisos restrictivos (root:root 700).
# -----------------------------------------------------------------------------
_ssl_crear_directorio() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        msg_info "Directorio ya existe: $dir"
        return 0
    fi
    if sudo mkdir -p "$dir"; then
        sudo chown root:root "$dir"
        # 755: el directorio base y los subdirectorios son legibles por root.
        # Cada módulo (nginx, tomcat) ajusta los permisos de su subdirectorio
        # y archivos para el usuario del servicio correspondiente.
        sudo chmod 755 "$dir"
        msg_success "Directorio creado: $dir  (755 root:root)"
        return 0
    fi
    msg_error "No se pudo crear: $dir"
    return 1
}

# -----------------------------------------------------------------------------
# _ssl_pedir_campo  (interna)
# Solicita un campo del certificado con prompt, descripción y validación básica.
# $1 = nombre de variable destino
# $2 = etiqueta de campo (ej: "Common Name (CN)")
# $3 = descripción / ejemplo
# $4 = longitud máxima (default 64)
# $5 = "nonempty" si el campo es obligatorio
# -----------------------------------------------------------------------------
_ssl_pedir_campo() {
    local __var="$1"
    local etiqueta="$2"
    local descripcion="$3"
    local maxlen="${4:-64}"
    local obligatorio="${5:-nonempty}"

    while true; do
        echo ""
        msg_info "${etiqueta}"
        [[ -n "$descripcion" ]] && echo "    ${descripcion}"
        msg_input "→ "; read -r valor

        # Validar obligatorio
        if [[ "$obligatorio" == "nonempty" && -z "$valor" ]]; then
            msg_error "Este campo no puede estar vacío"
            continue
        fi

        # Longitud máxima
        if (( ${#valor} > maxlen )); then
            msg_error "Máximo ${maxlen} caracteres (ingresaste ${#valor})"
            continue
        fi

        # Caracteres problemáticos para openssl -subj
        if echo "$valor" | grep -qP '[/\\"]'; then
            msg_error "No se permiten los caracteres: / \\ \""
            continue
        fi

        printf -v "$__var" "%s" "$valor"
        return 0
    done
}

# -----------------------------------------------------------------------------
# _ssl_pedir_pais  (interna)
# El campo Country (C) debe ser exactamente 2 letras ISO 3166-1.
# -----------------------------------------------------------------------------
_ssl_pedir_pais() {
    local __var="$1"
    while true; do
        echo ""
        msg_info "País (C)"
        echo "    Código ISO 3166-1 de 2 letras  (ej: MX, US, ES)"
        msg_input "→ "; read -r pais
        pais="${pais^^}"  # forzar mayúsculas
        if [[ "$pais" =~ ^[A-Z]{2}$ ]]; then
            printf -v "$__var" "%s" "$pais"
            return 0
        fi
        msg_error "El país debe ser exactamente 2 letras (ej: MX)"
    done
}

# -----------------------------------------------------------------------------
# _ssl_pedir_dias  (interna)
# Solicita la validez del certificado en días.
# -----------------------------------------------------------------------------
_ssl_pedir_dias() {
    local __var="$1"
    while true; do
        echo ""
        msg_info "Validez del certificado en días"
        echo "    Mínimo: 1   Máximo: 3650   Recomendado para pruebas: 365"
        msg_input "→ [${SSL_CERT_DAYS_DEFAULT}]: "; read -r dias
        [[ -z "$dias" ]] && dias="$SSL_CERT_DAYS_DEFAULT"
        if [[ "$dias" =~ ^[0-9]+$ ]] && (( dias >= 1 && dias <= 3650 )); then
            printf -v "$__var" "%s" "$dias"
            return 0
        fi
        msg_error "Valor inválido. Debe ser un entero entre 1 y 3650"
    done
}

# -----------------------------------------------------------------------------
# ssl_recopilar_datos_certificado
#
# Solicita al usuario TODOS los campos del certificado X.509.
# Rellena las variables globales SSL_CERT_CN, SSL_CERT_O, SSL_CERT_OU,
# SSL_CERT_C, SSL_CERT_ST, SSL_CERT_L, SSL_CERT_DAYS.
#
# Uso: ssl_recopilar_datos_certificado "Apache"
# -----------------------------------------------------------------------------
ssl_recopilar_datos_certificado() {
    local nombre_servicio="${1:-Servicio}"

    separator
    msg_info "Datos del certificado SSL/TLS — ${nombre_servicio}"
    msg_info "Todos los campos son obligatorios salvo que se indique (Enter = dejar vacío)"
    separator

    _ssl_pedir_campo SSL_CERT_CN \
        "Common Name (CN)" \
        "Nombre del servidor o dominio. Ej: www.reprobados.com  |  192.168.1.10" \
        64 "nonempty"

    _ssl_pedir_campo SSL_CERT_O \
        "Organización (O)" \
        "Nombre completo de la empresa u organización. Ej: Universidad Autonoma" \
        64 "nonempty"

    _ssl_pedir_campo SSL_CERT_OU \
        "Unidad Organizacional (OU)" \
        "Departamento o área. Ej: Redes y Telecomunicaciones" \
        64 "nonempty"

    _ssl_pedir_pais SSL_CERT_C

    _ssl_pedir_campo SSL_CERT_ST \
        "Estado / Provincia (ST)" \
        "Nombre completo del estado. Ej: Sinaloa" \
        128 "nonempty"

    _ssl_pedir_campo SSL_CERT_L \
        "Localidad / Ciudad (L)" \
        "Ciudad o municipio. Ej: Los Mochis" \
        128 "nonempty"

    _ssl_pedir_dias SSL_CERT_DAYS

    # Construir el string -subj para openssl
    # Se escapa cada campo con sed para proteger caracteres especiales de shell
    SSL_CERT_SUBJ="/C=${SSL_CERT_C}/ST=${SSL_CERT_ST}/L=${SSL_CERT_L}/O=${SSL_CERT_O}/OU=${SSL_CERT_OU}/CN=${SSL_CERT_CN}"

    separator
    msg_info "Resumen del certificado a generar:"
    echo ""
    printf "    CN  (Common Name)        : %s\n" "$SSL_CERT_CN"
    printf "    O   (Organización)       : %s\n" "$SSL_CERT_O"
    printf "    OU  (Unidad Org.)        : %s\n" "$SSL_CERT_OU"
    printf "    C   (País)               : %s\n" "$SSL_CERT_C"
    printf "    ST  (Estado)             : %s\n" "$SSL_CERT_ST"
    printf "    L   (Ciudad)             : %s\n" "$SSL_CERT_L"
    printf "    Validez                  : %s días\n" "$SSL_CERT_DAYS"
    echo ""

    export SSL_CERT_CN SSL_CERT_O SSL_CERT_OU SSL_CERT_C SSL_CERT_ST SSL_CERT_L
    export SSL_CERT_DAYS SSL_CERT_SUBJ
}

# -----------------------------------------------------------------------------
# ssl_generar_certificado
#
# Genera el par clave/certificado self-signed en el directorio indicado.
# Hace backup si ya existe un certificado previo.
#
# $1 = directorio destino         (ej: /etc/ssl/reprobados/apache)
# $2 = nombre del servicio        (ej: Apache)  — para logs
#
# Pre-condición: ssl_recopilar_datos_certificado ya fue llamado
#                (variables SSL_CERT_* deben estar en el entorno)
# -----------------------------------------------------------------------------
ssl_generar_certificado() {
    local dir_destino="$1"
    local nombre_servicio="${2:-Servicio}"

    # Validar que tenemos todos los datos del certificado
    if [[ -z "${SSL_CERT_CN:-}" || -z "${SSL_CERT_SUBJ:-}" ]]; then
        msg_error "Datos del certificado incompletos. Llame primero a ssl_recopilar_datos_certificado"
        return 1
    fi

    _ssl_verificar_openssl || return 1
    _ssl_crear_directorio "$dir_destino" || return 1

    local cert_path="${dir_destino}/${SSL_CERT_FILE}"
    local key_path="${dir_destino}/${SSL_KEY_FILE}"
    local csr_path="${dir_destino}/${SSL_CSR_FILE}"
    local ts; ts=$(date +%Y%m%d_%H%M%S)

    # Backup atómico si ya existen certificados previos
    if [[ -f "$cert_path" || -f "$key_path" ]]; then
        msg_alert "Certificados previos detectados — creando backup..."
        local bak_dir="${dir_destino}/bak_${ts}"
        sudo mkdir -p "$bak_dir"
        [[ -f "$cert_path" ]] && sudo mv "$cert_path" "${bak_dir}/${SSL_CERT_FILE}"
        [[ -f "$key_path"  ]] && sudo mv "$key_path"  "${bak_dir}/${SSL_KEY_FILE}"
        [[ -f "$csr_path"  ]] && sudo mv "$csr_path"  "${bak_dir}/${SSL_CSR_FILE}"
        msg_success "Backup guardado en: ${bak_dir}"
    fi

    msg_process "Generando clave privada RSA 2048 bits..."

    # Paso 1: Generar clave privada sin passphrase (requerido para servicios no interactivos)
    if ! sudo openssl genrsa \
            -out "$key_path" \
            2048 2>/dev/null; then
        msg_error "Error al generar la clave privada"
        return 1
    fi
    sudo chmod 600 "$key_path"
    sudo chown root:root "$key_path"
    msg_success "Clave privada: ${key_path}  (600 root:root)"

    msg_process "Generando CSR..."

    # Paso 2: CSR (retenido para evidencia aunque no se envíe a una CA)
    if ! sudo openssl req \
            -new \
            -key "$key_path" \
            -out "$csr_path" \
            -subj "$SSL_CERT_SUBJ" 2>/dev/null; then
        msg_error "Error al generar el CSR"
        return 1
    fi
    sudo chmod 644 "$csr_path"
    msg_success "CSR: ${csr_path}"

    msg_process "Generando certificado self-signed (${SSL_CERT_DAYS} días)..."

    # Paso 3: Certificado self-signed
    # -x509         : generar certificado directamente (no CSR para CA)
    # -nodes        : sin cifrado de la clave (necesario para arranque automático)
    # -sha256       : firma con SHA-256
    # -extensions v3_ca : añadir extensiones básicas X.509 v3
    # subjectAltName: requerido por browsers modernos además del CN
    local san_value
    # Si el CN es una IP, usar IP SAN; si es un nombre, usar DNS SAN
    if echo "$SSL_CERT_CN" | grep -qP '^\d{1,3}(\.\d{1,3}){3}$'; then
        san_value="IP:${SSL_CERT_CN}"
    else
        san_value="DNS:${SSL_CERT_CN}"
    fi

    if ! sudo openssl req \
            -x509 \
            -nodes \
            -days "$SSL_CERT_DAYS" \
            -newkey rsa:2048 \
            -keyout "$key_path" \
            -out "$cert_path" \
            -subj "$SSL_CERT_SUBJ" \
            -addext "subjectAltName=${san_value}" \
            -addext "basicConstraints=CA:FALSE" \
            -addext "keyUsage=digitalSignature,keyEncipherment" \
            -addext "extendedKeyUsage=serverAuth" \
            -sha256 2>/dev/null; then
        msg_error "Error al generar el certificado"
        return 1
    fi

    sudo chmod 644 "$cert_path"
    sudo chown root:root "$cert_path"
    msg_success "Certificado: ${cert_path}"

    # Verificación inmediata del certificado generado
    echo ""
    msg_info "Verificación del certificado generado:"
    sudo openssl x509 -in "$cert_path" -noout \
        -subject -issuer -dates -fingerprint 2>/dev/null \
        | sed 's/^/    /'

    echo ""
    msg_success "Certificado SSL/TLS generado exitosamente para: ${nombre_servicio}"
    return 0
}

# -----------------------------------------------------------------------------
# ssl_verificar_certificado_existente
#
# Verifica si ya existe un certificado válido (no expirado) en el directorio.
# Retorna 0 si existe y es válido, 1 en otro caso.
# Opcionalmente imprime información.
#
# $1 = directorio del servicio
# $2 = "verbose" para mostrar información
# -----------------------------------------------------------------------------
ssl_verificar_certificado_existente() {
    local dir="$1"
    local modo="${2:-silent}"
    local cert_path="${dir}/${SSL_CERT_FILE}"

    [[ ! -f "$cert_path" ]] && return 1

    # Verificar que no ha expirado
    if ! sudo openssl x509 -in "$cert_path" -noout -checkend 0 2>/dev/null; then
        [[ "$modo" == "verbose" ]] && msg_alert "Certificado expirado en: ${cert_path}"
        return 1
    fi

    if [[ "$modo" == "verbose" ]]; then
        msg_success "Certificado válido encontrado:"
        sudo openssl x509 -in "$cert_path" -noout \
            -subject -dates 2>/dev/null | sed 's/^/    /'
    fi

    return 0
}

# -----------------------------------------------------------------------------
# ssl_mostrar_certificado
#
# Muestra información completa de un certificado instalado.
# $1 = directorio del servicio  (ej: /etc/ssl/reprobados/apache)
# -----------------------------------------------------------------------------
ssl_mostrar_certificado() {
    local dir="$1"
    local nombre="${2:-Servicio}"
    local cert_path="${dir}/${SSL_CERT_FILE}"

    separator
    msg_info "Información del certificado — ${nombre}"
    separator

    if [[ ! -f "$cert_path" ]]; then
        msg_alert "No existe certificado en: ${dir}"
        return 1
    fi

    sudo openssl x509 -in "$cert_path" -noout -text 2>/dev/null \
        | grep -E "(Subject:|Issuer:|Not Before|Not After|Signature Algorithm|Public-Key|DNS:|IP Address:)" \
        | sed 's/^/    /'

    echo ""
    local dias_restantes
    dias_restantes=$(sudo openssl x509 -in "$cert_path" -noout \
        -enddate 2>/dev/null | cut -d= -f2)
    printf "    Expira    : %s\n" "$dias_restantes"

    if sudo openssl x509 -in "$cert_path" -noout -checkend 0 2>/dev/null; then
        msg_success "Certificado: VÁLIDO"
    else
        msg_error "Certificado: EXPIRADO"
    fi
}

export -f ssl_recopilar_datos_certificado
export -f ssl_generar_certificado
export -f ssl_verificar_certificado_existente
export -f ssl_mostrar_certificado
export -f _ssl_verificar_openssl
export -f _ssl_crear_directorio
export -f _ssl_pedir_campo
export -f _ssl_pedir_pais
export -f _ssl_pedir_dias