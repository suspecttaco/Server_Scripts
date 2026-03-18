# =============================================================================
# ssl_lib/ssl_nginx.ps1 — SSL/TLS para Nginx en Windows
#
# Estrategia: python3 (si disponible) o manipulación de texto PowerShell
# para insertar el bloque HTTPS dentro de http{} y agregar return 301
# en el server block HTTP. Idempotente con marca ssl_manager.
# Redirect usa $host para funcionar con cualquier IP/interfaz.
# =============================================================================

$script:_SSL_NGINX_MARCA = "# === ssl_manager: SSL block ==="

function _ssl_nginx_leer_puerto_http {
    if (Test-Path $script:HTTP_CONF_NGINX) {
        $linea = Get-Content $script:HTTP_CONF_NGINX |
                 Where-Object { $_ -match '^\s+listen\s+\d+;' } |
                 Select-Object -First 1
        if ($linea -match 'listen\s+(\d+)') { return [int]$Matches[1] }
    }
    return 80
}

function _ssl_nginx_leer_puerto_https {
    if (Test-Path $script:HTTP_CONF_NGINX) {
        $lines = Get-Content $script:HTTP_CONF_NGINX
        $enBloque = $false
        foreach ($l in $lines) {
            if ($l -match [regex]::Escape($script:_SSL_NGINX_MARCA)) { $enBloque = $true; continue }
            if ($enBloque -and $l -match 'listen\s+(\d+)\s+ssl') { return [int]$Matches[1] }
        }
    }
    return 443
}

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_nginx_aplicar_python  (interna)
# Usa python3 para modificar nginx.conf de forma idempotente.
# Si python3 no está disponible, usa PowerShell puro como fallback.
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_nginx_aplicar_python {
    param([int]$HttpPort, [int]$HttpsPort)

    $certPath   = (Join-Path $script:SSL_DIR_NGINX $script:SSL_CERT_FILE) -replace '\\', '/'
    $keyPath    = (Join-Path $script:SSL_DIR_NGINX $script:SSL_KEY_FILE)  -replace '\\', '/'
    $serverName = $script:SSL_CERT_CN
    $webroot    = $script:HTTP_DIR_NGINX -replace '\\', '/'
    $marca      = $script:_SSL_NGINX_MARCA
    $confFile   = $script:HTTP_CONF_NGINX

    # Backup
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item $confFile "${confFile}.bak_${ts}" -Force
    msg_success "Backup: ${confFile}.bak_${ts}"

    $tmpFile = [System.IO.Path]::GetTempFileName() + ".conf"
    Copy-Item $confFile $tmpFile -Force

    # Intentar con python3
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }

    if ($python) {
        $pyScript = @'
import sys, re

conf_file   = sys.argv[1]
http_port   = sys.argv[2]
https_port  = sys.argv[3]
cert_path   = sys.argv[4]
key_path    = sys.argv[5]
server_name = sys.argv[6]
webroot     = sys.argv[7]
marca       = sys.argv[8]

with open(conf_file, encoding='utf-8') as f:
    content = f.read()

# 1. Eliminar bloques SSL anteriores
marca_esc = re.escape(marca)
content = re.sub(r'\n?\s*' + marca_esc + r'.*?' + marca_esc, '', content, flags=re.DOTALL)

# 2. Eliminar return 301 anterior del server block HTTP
def remove_redirect(text, port):
    result = []; i = 0
    while i < len(text):
        m = re.search(r'\bserver\s*\{', text[i:])
        if not m: result.append(text[i:]); break
        result.append(text[i:i+m.end()]); i += m.end()
        depth = 1; start = i
        while i < len(text) and depth > 0:
            if text[i] == '{': depth += 1
            elif text[i] == '}': depth -= 1
            i += 1
        block = text[start:i-1]
        if re.search(r'listen\s+' + re.escape(port) + r'[;\s]', block):
            block = re.sub(r'\n\s*return 301[^\n]*', '', block)
        result.append(block + '}')
    return ''.join(result)

content = remove_redirect(content, http_port)

# 3. Agregar return 301 — usa \$host (variable Nginx, no Python)
redirect = f'        return 301 https://\$host:{https_port}\$request_uri;'

def add_redirect(text, port, redirect):
    result = []; i = 0; modified = False
    while i < len(text):
        m = re.search(r'\bserver\s*\{', text[i:])
        if not m: result.append(text[i:]); break
        result.append(text[i:i+m.end()]); i += m.end()
        depth = 1; start = i
        while i < len(text) and depth > 0:
            if text[i] == '{': depth += 1
            elif text[i] == '}': depth -= 1
            i += 1
        block = text[start:i-1]
        if re.search(r'listen\s+' + re.escape(port) + r'[;\s]', block) and not modified:
            loc = re.search(r'\blocation\s*[/\w]', block)
            if loc: block = block[:loc.start()] + redirect + '\n\n        ' + block[loc.start():]
            else:   block = block.rstrip() + '\n' + redirect + '\n    '
            modified = True
        result.append(block + '}')
    return ''.join(result)

content = add_redirect(content, http_port, redirect)

# 4. Bloque HTTPS
ssl_block = f"""
    {marca}
    server {{
        listen {https_port} ssl;
        listen [::]:{https_port} ssl;
        server_name {server_name};
        root        {webroot};
        index       index.html index.htm;

        ssl_certificate     {cert_path};
        ssl_certificate_key {key_path};

        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5:!RC4:!DES:!3DES;
        ssl_prefer_server_ciphers on;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;

        server_tokens off;

        location / {{
            try_files \$uri \$uri/ =404;
        }}
    }}
    {marca}
"""

m_http = re.search(r'\bhttp\s*\{', content)
if not m_http: print('ERROR: no se encontro bloque http{}'); sys.exit(1)
depth = 1; pos = m_http.end()
while pos < len(content) and depth > 0:
    if content[pos] == '{': depth += 1
    elif content[pos] == '}': depth -= 1
    pos += 1
content = content[:pos-1] + ssl_block + content[pos-1:]

with open(conf_file, 'w', encoding='utf-8') as f:
    f.write(content)
print('OK')
'@
        $pyFile = [System.IO.Path]::GetTempFileName() + ".py"
        [System.IO.File]::WriteAllText($pyFile, $pyScript, [System.Text.Encoding]::UTF8)

        $result = & $python.Source $pyFile $tmpFile `
                  "$HttpPort" "$HttpsPort" `
                  $certPath $keyPath `
                  $serverName $webroot $marca 2>&1

        Remove-Item $pyFile -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -ne 0) {
            msg_error "Error en python: $result"
            Copy-Item "${confFile}.bak_${ts}" $confFile -Force
            Remove-Item $tmpFile -ErrorAction SilentlyContinue
            return $false
        }
    } else {
        msg_alert "python3 no disponible — usando PowerShell para modificar nginx.conf"
        # Fallback PowerShell — rutas con barras hacia adelante para nginx
        $certPathFwd = $certPath  -replace '\\\\', '/'
        $keyPathFwd  = $keyPath   -replace '\\\\', '/'
        $webrootFwd  = $webroot   -replace '\\\\', '/'
        # Las rutas de PS tienen \ simple que hay que convertir a /
        $certPathFwd = $certPathFwd -replace '\\', '/'
        $keyPathFwd  = $keyPathFwd  -replace '\\', '/'
        $webrootFwd  = $webrootFwd  -replace '\\', '/'

        $rawContent = [System.IO.File]::ReadAllText($tmpFile, [System.Text.Encoding]::UTF8)

        # Eliminar bloque SSL anterior (idempotencia)
        $marcaEsc  = [regex]::Escape($marca)
        $rawContent = [regex]::Replace($rawContent, '(?s)' + $marcaEsc + '.*?' + $marcaEsc, '')

        # Eliminar return 301 anterior
        $rawContent = [regex]::Replace($rawContent, '\n\s*return 301[^\n]*', '')

        # Agregar return 301 antes del primer location /
        $redirect    = "        return 301 https://`$host:${HttpsPort}`$request_uri;"
        $rawContent  = [regex]::Replace($rawContent,
            '(\n        location\s*/\s*\{)',
            "`n$redirect`n`n`$1")

        # Construir bloque HTTPS con rutas de barras hacia adelante
        $sslBlock = @"

    $marca
    server {
        listen $HttpsPort ssl;
        listen [::]:$HttpsPort ssl;
        server_name $serverName;
        root        $webrootFwd;
        index       index.html index.htm;

        ssl_certificate     $certPathFwd;
        ssl_certificate_key $keyPathFwd;

        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5:!RC4;
        ssl_prefer_server_ciphers on;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;

        server_tokens off;

        location / {
            try_files `$uri `$uri/ =404;
        }
    }
    $marca
"@
        # Insertar antes del cierre de http{} — último }
        $lastBrace = $rawContent.LastIndexOf("}")
        if ($lastBrace -gt 0) {
            $rawContent = $rawContent.Substring(0, $lastBrace) + $sslBlock + "`n}"
        } else {
            $rawContent += $sslBlock
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($tmpFile, $rawContent, $utf8NoBom)
    }

    # Copiar resultado al archivo real
    Copy-Item $tmpFile $confFile -Force
    Remove-Item $tmpFile -ErrorAction SilentlyContinue
    return $true
}

function _ssl_nginx_verificar_sintaxis {
    msg_process "Verificando sintaxis Nginx..."
    $nginxExe = Get-ChildItem "C:\tools" -Recurse -Filter nginx.exe `
                -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nginxExe) {
        msg_alert "nginx.exe no encontrado — sintaxis no verificada"
        return $true
    }
    $nginxDir = Split-Path $nginxExe.FullName
    $out = & cmd /c "cd /d `"$nginxDir`" && `"$($nginxExe.FullName)`" -t 2>&1"
    if ($out -match "syntax is ok") {
        msg_success "Sintaxis: OK"
        return $true
    }
    msg_error "Error de sintaxis:"
    $out | ForEach-Object { Write-Host "    $_" }
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_configurar_nginx  (pública)
# ─────────────────────────────────────────────────────────────────────────────
function ssl_configurar_nginx {
    Write-Separator
    msg_info "Configuración SSL/TLS — Nginx (Windows)"
    Write-Separator
    Write-Host ""

    if (-not (Test-Path $script:HTTP_CONF_NGINX)) {
        msg_error "Nginx no está instalado o nginx.conf no encontrado"
        return
    }

    $httpPort = _ssl_nginx_leer_puerto_http

    msg_info "PASO 1/6 — Datos del certificado"
    ssl_recopilar_datos_certificado "Nginx"
    Write-Host ""

    msg_info "PASO 2/6 — Puerto HTTPS"
    $httpsPort = 0
    ssl_seleccionar_puerto_https "Nginx" $httpPort ([ref]$httpsPort)
    Write-Host ""

    msg_input "¿Confirmar configuración SSL para Nginx? [S/N]: "
    $conf = Read-Host
    if ($conf -notmatch '^[SsYy]') { msg_info "Cancelado"; return }
    Write-Host ""

    msg_info "PASO 3/6 — Generar certificado (CRT + KEY)"
    if (-not (ssl_generar_certificado $script:SSL_DIR_NGINX "Nginx" $true)) { return }
    Write-Host ""

    msg_info "PASO 4/6 — Modificar nginx.conf"
    if (-not (_ssl_nginx_aplicar_python $httpPort $httpsPort)) { return }
    Write-Host ""

    msg_info "PASO 5/6 — Verificar sintaxis"
    if (-not (_ssl_nginx_verificar_sintaxis)) {
        msg_error "Rollback: restaurando nginx.conf"
        $bak = Get-ChildItem "$($script:HTTP_CONF_NGINX).bak_*" `
               -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        if ($bak) { Copy-Item $bak.FullName $script:HTTP_CONF_NGINX -Force }
        return
    }
    Write-Host ""

    msg_info "PASO 6/6 — Reiniciar Nginx"
    if (-not (http_reiniciar_servicio "nginx")) {
        msg_error "Nginx no levantó"
        return
    }
    Start-Sleep -Seconds 2

    ssl_abrir_firewall $httpsPort "Nginx"

    $resp = curl.exe -sk -o NUL -w "%{http_code}" `
            "https://localhost:${httpsPort}" 2>$null
    if ($resp -match '^(200|301|302|400|404)$') {
        msg_success "HTTPS responde: HTTP $resp"
    } else {
        msg_alert "HTTPS devolvió $resp"
    }

    Write-Separator
    msg_success "SSL/TLS configurado en Nginx"
    Write-Separator
    Write-Host "    HTTP  :${httpPort}  → redirect HTTPS"
    Write-Host "    HTTPS :${httpsPort}  (activo)"
    Write-Host ""

    $script:_SSL_LAST_HTTP_PORT  = $httpPort
    $script:_SSL_LAST_HTTPS_PORT = $httpsPort
}

function ssl_nginx_actualizar_puertos {
    param([int]$HttpPort, [int]$HttpsPort)
    msg_info "Actualizando puertos Nginx SSL: HTTP=${HttpPort} HTTPS=${HttpsPort}"

    # Leer CN del certificado si no está en memoria
    if ([string]::IsNullOrEmpty($script:SSL_CERT_CN)) {
        $certPath = Join-Path $script:SSL_DIR_NGINX $script:SSL_CERT_FILE
        if (Test-Path $certPath) {
            $subj = & openssl x509 -in "`"$certPath`"" -noout -subject 2>$null
            if ($subj -match 'CN\s*=\s*([^,/]+)') { $script:SSL_CERT_CN = $Matches[1].Trim() }
        }
    }
    if ([string]::IsNullOrEmpty($script:SSL_CERT_CN)) { $script:SSL_CERT_CN = "_" }

    # Leer rutas de cert/key si no están en memoria
    if ([string]::IsNullOrEmpty($script:SSL_DIR_NGINX)) {
        $script:SSL_DIR_NGINX = "C:\SSL
eprobados
ginx"
    }

    if (-not (_ssl_nginx_aplicar_python $HttpPort $HttpsPort)) { return }
    if (-not (_ssl_nginx_verificar_sintaxis)) {
        # Rollback
        $bak = Get-ChildItem "$($script:HTTP_CONF_NGINX).bak_*" `
               -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        if ($bak) { Copy-Item $bak.FullName $script:HTTP_CONF_NGINX -Force }
        return
    }
    # NO reiniciar aquí — ws_config.ps1 hace el restart único en PASO 4
    ssl_abrir_firewall $HttpsPort "Nginx"
    msg_success "Puertos Nginx SSL actualizados: HTTP=${HttpPort} HTTPS=${HttpsPort}"
    msg_info  "Pendiente restart — se ejecutara en PASO 4"
}

function ssl_desactivar_nginx {
    msg_alert "Desactivando SSL en Nginx..."
    $bak = Get-ChildItem "$($script:HTTP_CONF_NGINX).bak_*" `
           -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($bak) {
        Copy-Item $bak.FullName $script:HTTP_CONF_NGINX -Force
        msg_success "nginx.conf restaurado desde: $($bak.Name)"
    }
    _ssl_nginx_verificar_sintaxis | Out-Null
    http_reiniciar_servicio "nginx" | Out-Null
    msg_success "Nginx reiniciado sin SSL"
}