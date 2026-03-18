# =============================================================================
# ssl_lib/ssl_tomcat.ps1 — SSL/TLS para Tomcat en Windows
#
# Estrategia: Tomcat usa PKCS12 directamente.
# New-SelfSignedCertificate → Export-PfxCertificate → server.xml via python/PS
# Redirect HTTP→HTTPS via CONFIDENTIAL en web.xml (Jakarta EE nativo).
# =============================================================================

function _ssl_tomcat_leer_puerto_http {
    if (Test-Path $script:HTTP_CONF_TOMCAT) {
        try {
            [xml]$xml = Get-Content $script:HTTP_CONF_TOMCAT
            $conn = $xml.Server.Service.Connector |
                    Where-Object { $_.protocol -match 'HTTP' -and $_.SSLEnabled -ne 'true' } |
                    Select-Object -First 1
            if ($conn) { return [int]$conn.port }
        } catch {}
    }
    return 8080
}

function _ssl_tomcat_leer_puerto_https {
    if (Test-Path $script:HTTP_CONF_TOMCAT) {
        try {
            [xml]$xml = Get-Content $script:HTTP_CONF_TOMCAT
            $conn = $xml.Server.Service.Connector |
                    Where-Object { $_.SSLEnabled -eq 'true' } |
                    Select-Object -First 1
            if ($conn) { return [int]$conn.port }
        } catch {}
    }
    return 8443
}

function _ssl_tomcat_detectar_webroot {
    $candidatos = @(
        "C:\ProgramData\Tomcat9\webapps\ROOT",
        "C:\ProgramData\Tomcat10\webapps\ROOT",
        "C:\tools\tomcat\webapps\ROOT"
    )
    foreach ($c in $candidatos) {
        if (Test-Path $c) { return $c }
    }
    return Split-Path $script:HTTP_CONF_TOMCAT | Split-Path | Join-Path -ChildPath "webapps\ROOT"
}

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_tomcat_modificar_server_xml  (interna)
# Inserta/actualiza el Connector HTTPS en server.xml via python o PS.
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_tomcat_modificar_server_xml {
    param([int]$HttpsPort, [string]$PfxPath, [string]$PfxPass)

    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item $script:HTTP_CONF_TOMCAT "${script:HTTP_CONF_TOMCAT}.bak_${ts}" -Force
    msg_success "Backup: ${script:HTTP_CONF_TOMCAT}.bak_${ts}"

    $tmpXml = [System.IO.Path]::GetTempFileName() + ".xml"
    Copy-Item $script:HTTP_CONF_TOMCAT $tmpXml -Force

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }

    if ($python) {
        $pyScript = @"
import sys, re

xml_path   = sys.argv[1]
https_port = sys.argv[2]
keystore   = sys.argv[3]
ks_pass    = sys.argv[4]

with open(xml_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Eliminar Connector HTTPS anterior
content = re.sub(
    r'\s*<!-- ssl_manager: HTTPS Connector -->.*?<!-- /ssl_manager -->',
    '', content, flags=re.DOTALL)

# Actualizar redirectPort en Connector HTTP
content = re.sub(r'(redirectPort=")[0-9]+(")', rf'\g<1>{https_port}\g<2>', content)

# Normalizar separadores de ruta
keystore_norm = keystore.replace('\\\\', '/')

connector = (
    '\n    <!-- ssl_manager: HTTPS Connector -->'
    f'\n    <Connector port="{https_port}"'
    '\n               protocol="org.apache.coyote.http11.Http11NioProtocol"'
    '\n               SSLEnabled="true"'
    '\n               maxThreads="150"'
    '\n               scheme="https"'
    '\n               secure="true">'
    '\n        <SSLHostConfig protocols="TLSv1.2+TLSv1.3">'
    f'\n            <Certificate certificateKeystoreFile="{keystore_norm}"'
    f'\n                         certificateKeystorePassword="{ks_pass}"'
    '\n                         certificateKeystoreType="PKCS12"'
    '\n                         type="RSA" />'
    '\n        </SSLHostConfig>'
    '\n    </Connector>'
    '\n    <!-- /ssl_manager -->'
)

if '</Service>' not in content:
    print('ERROR: no se encontro </Service>')
    sys.exit(1)

content = content.replace('</Service>', connector + '\n  </Service>', 1)

with open(xml_path, 'w', encoding='utf-8') as f:
    f.write(content)
print('OK')
"@
        $pyFile = [System.IO.Path]::GetTempFileName() + ".py"
        [System.IO.File]::WriteAllText($pyFile, $pyScript, [System.Text.Encoding]::UTF8)

        $result = & $python.Source $pyFile $tmpXml `
                  "$HttpsPort" "$PfxPath" "$PfxPass" 2>&1

        Remove-Item $pyFile -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -ne 0) {
            msg_error "Error en python: $result"
            Copy-Item "${script:HTTP_CONF_TOMCAT}.bak_${ts}" $script:HTTP_CONF_TOMCAT -Force
            Remove-Item $tmpXml -ErrorAction SilentlyContinue
            return $false
        }
    } else {
        # Fallback PowerShell puro
        try {
            [xml]$xml = Get-Content $tmpXml

            # Actualizar redirectPort
            foreach ($c in $xml.Server.Service.Connector) {
                if ($c.protocol -match 'HTTP' -and $c.SSLEnabled -ne 'true') {
                    $c.SetAttribute("redirectPort", "$HttpsPort")
                }
            }

            # Eliminar Connector HTTPS anterior
            $prevConns = $xml.Server.Service.Connector |
                         Where-Object { $_.SSLEnabled -eq 'true' }
            foreach ($pc in $prevConns) {
                $pc.ParentNode.RemoveChild($pc) | Out-Null
            }

            # Crear nuevo Connector HTTPS
            $conn = $xml.CreateElement("Connector")
            $conn.SetAttribute("port",        "$HttpsPort")
            $conn.SetAttribute("protocol",    "org.apache.coyote.http11.Http11NioProtocol")
            $conn.SetAttribute("SSLEnabled",  "true")
            $conn.SetAttribute("maxThreads",  "150")
            $conn.SetAttribute("scheme",      "https")
            $conn.SetAttribute("secure",      "true")

            $sslHostCfg = $xml.CreateElement("SSLHostConfig")
            $sslHostCfg.SetAttribute("protocols", "TLSv1.2+TLSv1.3")

            $certElem = $xml.CreateElement("Certificate")
            $pfxNorm  = $PfxPath -replace '\\', '/'
            $certElem.SetAttribute("certificateKeystoreFile",     $pfxNorm)
            $certElem.SetAttribute("certificateKeystorePassword", $PfxPass)
            $certElem.SetAttribute("certificateKeystoreType",     "PKCS12")
            $certElem.SetAttribute("type",                        "RSA")

            $sslHostCfg.AppendChild($certElem) | Out-Null
            $conn.AppendChild($sslHostCfg)     | Out-Null
            $xml.Server.Service.AppendChild($conn) | Out-Null

            $xml.Save($tmpXml)
        } catch {
            msg_error "Error PS al modificar server.xml: $($_.Exception.Message)"
            Copy-Item "${script:HTTP_CONF_TOMCAT}.bak_${ts}" $script:HTTP_CONF_TOMCAT -Force
            Remove-Item $tmpXml -ErrorAction SilentlyContinue
            return $false
        }
    }

    Copy-Item $tmpXml $script:HTTP_CONF_TOMCAT -Force
    Remove-Item $tmpXml -ErrorAction SilentlyContinue
    msg_success "Connector HTTPS en server.xml (puerto $HttpsPort)"
    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_tomcat_configurar_webxml  (interna)
# Agrega CONFIDENTIAL en web.xml para redirect HTTP→HTTPS.
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_tomcat_configurar_webxml {
    $webroot = _ssl_tomcat_detectar_webroot
    $webXml  = Join-Path $webroot "WEB-INF\web.xml"

    msg_process "Configurando redirect CONFIDENTIAL en web.xml..."

    if (-not (Test-Path $webXml)) {
        $webInfDir = Join-Path $webroot "WEB-INF"
        if (-not (Test-Path $webInfDir)) { New-Item -ItemType Directory -Path $webInfDir -Force | Out-Null }
        @'
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="https://jakarta.ee/xml/ns/jakartaee"
         version="6.0">
</web-app>
'@ | Set-Content $webXml -Encoding UTF8
    }

    if (Select-String -Path $webXml -Pattern "ssl_manager: redirect" -Quiet) {
        msg_info "Redirect CONFIDENTIAL ya configurado"
        return $true
    }

    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item $webXml "${webXml}.bak_${ts}" -Force

    $block = @"

  <!-- ssl_manager: redirect HTTP→HTTPS -->
  <security-constraint>
    <web-resource-collection>
      <web-resource-name>Redirect HTTP to HTTPS</web-resource-name>
      <url-pattern>/*</url-pattern>
    </web-resource-collection>
    <user-data-constraint>
      <transport-guarantee>CONFIDENTIAL</transport-guarantee>
    </user-data-constraint>
  </security-constraint>
  <!-- /ssl_manager: redirect -->
"@

    $content = Get-Content $webXml -Raw
    $content = $content -replace '</web-app>', "$block</web-app>"

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($webXml, $content, $utf8NoBom)
    msg_success "Redirect CONFIDENTIAL en web.xml"
    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# _ssl_tomcat_reiniciar_esperar  (interna)
# ─────────────────────────────────────────────────────────────────────────────
function _ssl_tomcat_reiniciar_esperar {
    param([int]$HttpsPort)
    msg_process "Reiniciando Tomcat (puede tardar hasta 30s)..."
    Stop-Service $script:HTTP_WINSVC_TOMCAT -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service $script:HTTP_WINSVC_TOMCAT -ErrorAction SilentlyContinue

    $listo = $false
    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 2
        $escucha = Get-NetTCPConnection -LocalPort $HttpsPort -State Listen `
                   -ErrorAction SilentlyContinue
        if ($escucha) { $listo = $true; break }
        Write-Host "    Intento $i/15 — puerto $HttpsPort aún no disponible..."
    }

    if ($listo) { msg_success "Tomcat activo — puerto $HttpsPort listo" }
    else        { msg_alert  "Tomcat arrancó pero $HttpsPort no responde aún" }
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_configurar_tomcat  (pública)
# ─────────────────────────────────────────────────────────────────────────────
function ssl_configurar_tomcat {
    Write-Separator
    msg_info "Configuración SSL/TLS — Tomcat (Windows)"
    Write-Separator
    Write-Host ""

    if (-not (Test-Path $script:HTTP_CONF_TOMCAT)) {
        msg_error "Tomcat no está instalado o server.xml no encontrado"
        return
    }

    $httpPort = _ssl_tomcat_leer_puerto_http

    msg_info "PASO 1/7 — Datos del certificado"
    ssl_recopilar_datos_certificado "Tomcat"
    Write-Host ""

    msg_info "PASO 2/7 — Puerto HTTPS"
    $httpsPort = 0
    ssl_seleccionar_puerto_https "Tomcat" $httpPort ([ref]$httpsPort)
    Write-Host ""

    msg_input "¿Confirmar configuración SSL para Tomcat? [S/N]: "
    $conf = Read-Host
    if ($conf -notmatch '^[SsYy]') { msg_info "Cancelado"; return }
    Write-Host ""

    msg_info "PASO 3/7 — Generar certificado (PFX)"
    # Tomcat usa PFX directamente — no necesita PEM
    if (-not (ssl_generar_certificado $script:SSL_DIR_TOMCAT "Tomcat" $false)) { return }
    Write-Host ""

    $pfxPath = Join-Path $script:SSL_DIR_TOMCAT $script:SSL_PFX_FILE

    msg_info "PASO 4/7 — Modificar server.xml"
    if (-not (_ssl_tomcat_modificar_server_xml $httpsPort $pfxPath $script:SSL_PFX_PASS)) { return }
    Write-Host ""

    msg_info "PASO 5/7 — Configurar redirect en web.xml"
    _ssl_tomcat_configurar_webxml | Out-Null
    Write-Host ""

    msg_info "PASO 6/7 — Abrir firewall"
    ssl_abrir_firewall $httpsPort "Tomcat"
    Write-Host ""

    msg_info "PASO 7/7 — Reiniciar Tomcat"
    _ssl_tomcat_reiniciar_esperar $httpsPort

    Write-Separator
    msg_success "SSL/TLS configurado en Tomcat"
    Write-Separator
    Write-Host "    PFX     : $pfxPath"
    Write-Host "    HTTP  :${httpPort}  → redirect HTTPS (web.xml CONFIDENTIAL)"
    Write-Host "    HTTPS :${httpsPort}  (activo)"
    Write-Host ""

    $script:_SSL_LAST_HTTP_PORT  = $httpPort
    $script:_SSL_LAST_HTTPS_PORT = $httpsPort
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_tomcat_actualizar_puertos  (pública)
# Regenera PFX y actualiza server.xml con nuevos puertos.
# ─────────────────────────────────────────────────────────────────────────────
function ssl_tomcat_actualizar_puertos {
    param([int]$HttpsPort)
    msg_info "Actualizando puerto HTTPS Tomcat → ${HttpsPort}/tcp"

    # Inicializar SSL_DIR_TOMCAT si no está en memoria
    if ([string]::IsNullOrEmpty($script:SSL_DIR_TOMCAT)) {
        $script:SSL_DIR_TOMCAT = "C:\SSL
eprobados	omcat"
    }

    $pfxPath = Join-Path $script:SSL_DIR_TOMCAT $script:SSL_PFX_FILE

    # Verificar que existe el PFX (no el CRT — Tomcat usa PFX)
    if (-not (Test-Path $pfxPath)) {
        # Buscar PFX en rutas alternativas
        $altPaths = @(
            "C:\SSL
eprobados	omcat
eprobados.pfx",
            "$env:ProgramData\SSL	omcat
eprobados.pfx"
        )
        foreach ($p in $altPaths) {
            if (Test-Path $p) { $pfxPath = $p; break }
        }
        if (-not (Test-Path $pfxPath)) {
            msg_error "PFX no encontrado en: $pfxPath"
            msg_info  "Configure SSL desde cero: ssl_manager.ps1 → Configurar SSL → Tomcat"
            return
        }
    }

    # Pedir nueva contraseña para el PFX regenerado
    msg_info "Ingrese la nueva contraseña para el PFX:"
    ssl_pedir_pfx_password | Out-Null

    # Re-exportar PFX desde el Store si el thumbprint está disponible
    if (-not [string]::IsNullOrEmpty($script:SSL_THUMBPRINT)) {
        $cert = Get-Item "Cert:\LocalMachine\My\$($script:SSL_THUMBPRINT)" `
                -ErrorAction SilentlyContinue
        if ($cert) {
            $secPass = ConvertTo-SecureString $script:SSL_PFX_PASS -AsPlainText -Force
            Export-PfxCertificate -Cert $cert -FilePath $pfxPath `
                -Password $secPass -Force -ErrorAction SilentlyContinue | Out-Null
            msg_success "PFX regenerado desde Store"
        } else {
            msg_alert "Thumbprint no en Store — usando PFX existente con nueva contraseña"
        }
    } else {
        msg_alert "Thumbprint no en memoria — usando PFX existente"
    }

    if (-not (_ssl_tomcat_modificar_server_xml $HttpsPort $pfxPath $script:SSL_PFX_PASS)) { return }
    ssl_abrir_firewall $HttpsPort "Tomcat"
    # NO reiniciar aquí — ws_config.ps1 hace el restart único en PASO 4
    msg_success "Puerto HTTPS Tomcat actualizado: ${HttpsPort}/tcp"
    msg_info  "Pendiente restart — se ejecutara en PASO 4"
}

function ssl_desactivar_tomcat {
    msg_alert "Desactivando SSL en Tomcat..."
    $bak = Get-ChildItem "$($script:HTTP_CONF_TOMCAT).bak_*" `
           -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($bak) {
        Copy-Item $bak.FullName $script:HTTP_CONF_TOMCAT -Force
        msg_success "server.xml restaurado"
    }

    $webroot = _ssl_tomcat_detectar_webroot
    $webXmlBak = Get-ChildItem (Join-Path $webroot "WEB-INF\web.xml.bak_*") `
                 -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($webXmlBak) {
        Copy-Item $webXmlBak.FullName (Join-Path $webroot "WEB-INF\web.xml") -Force
        msg_success "web.xml restaurado"
    }

    Restart-Service $script:HTTP_WINSVC_TOMCAT -Force -ErrorAction SilentlyContinue
    msg_success "Tomcat reiniciado sin SSL"
}