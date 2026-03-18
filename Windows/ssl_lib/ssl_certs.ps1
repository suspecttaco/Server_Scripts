# =============================================================================
# ssl_lib/ssl_certs.ps1 — Generación interactiva de certificados self-signed
#
# Estrategia:
#   1. New-SelfSignedCertificate → Certificate Store (Cert:\LocalMachine\My)
#   2. Export-PfxCertificate     → archivo .pfx con contraseña
#   3. openssl pkcs12            → extrae .crt y .key del PFX
#      (Apache y Nginx necesitan archivos PEM; Tomcat usa el PFX directamente;
#       IIS usa el thumbprint del Store directamente)
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# ssl_recopilar_datos_certificado
# Solicita interactivamente los datos del certificado.
# Rellena las variables globales $script:SSL_CERT_*.
# ─────────────────────────────────────────────────────────────────────────────
function ssl_recopilar_datos_certificado {
    param([string]$Servicio)

    Write-Separator
    msg_info "Datos del certificado SSL/TLS — ${Servicio}"
    Write-Separator
    Write-Host ""
    msg_info "Los datos ingresados se usarán en el Subject del certificado."
    msg_info "Enter = usar el valor entre corchetes."
    Write-Host ""

    # CN — Common Name (dominio o IP)
    while ($true) {
        msg_input "CN - Nombre común / dominio (ej: reprobados.com): "
        $cn = Read-Host
        if ([string]::IsNullOrWhiteSpace($cn)) {
            msg_error "El CN no puede estar vacío"
            continue
        }
        $script:SSL_CERT_CN = $cn.Trim()
        break
    }

    # Organización
    msg_input "O  - Organización [Reprobados]: "
    $org = Read-Host
    $script:SSL_CERT_ORG = if ([string]::IsNullOrWhiteSpace($org)) { "Reprobados" } else { $org.Trim() }

    # Unidad organizacional
    msg_input "OU - Unidad organizacional [TI]: "
    $ou = Read-Host
    $script:SSL_CERT_OU = if ([string]::IsNullOrWhiteSpace($ou)) { "TI" } else { $ou.Trim() }

    # País (2 letras)
    while ($true) {
        msg_input "C  - País (2 letras, ej: MX) [MX]: "
        $c = Read-Host
        if ([string]::IsNullOrWhiteSpace($c)) { $c = "MX" }
        if ($c.Length -ne 2) { msg_error "El código de país debe tener exactamente 2 letras"; continue }
        $script:SSL_CERT_COUNTRY = $c.ToUpper()
        break
    }

    # Estado
    msg_input "ST - Estado / Provincia [Sinaloa]: "
    $st = Read-Host
    $script:SSL_CERT_STATE = if ([string]::IsNullOrWhiteSpace($st)) { "Sinaloa" } else { $st.Trim() }

    # Ciudad
    msg_input "L  - Ciudad / Localidad [Los Mochis]: "
    $l = Read-Host
    $script:SSL_CERT_CITY = if ([string]::IsNullOrWhiteSpace($l)) { "Los Mochis" } else { $l.Trim() }

    # Días de validez
    while ($true) {
        msg_input "Días de validez [365]: "
        $d = Read-Host
        if ([string]::IsNullOrWhiteSpace($d)) { $d = "365" }
        if ($d -notmatch '^\d+$' -or [int]$d -lt 1 -or [int]$d -gt 3650) {
            msg_error "Ingrese un número entre 1 y 3650"
            continue
        }
        $script:SSL_CERT_DAYS = [int]$d
        break
    }

    Write-Host ""
    msg_info "Resumen del certificado:"
    Write-Host "    CN  : $($script:SSL_CERT_CN)"
    Write-Host "    O   : $($script:SSL_CERT_ORG)"
    Write-Host "    OU  : $($script:SSL_CERT_OU)"
    Write-Host "    C   : $($script:SSL_CERT_COUNTRY)"
    Write-Host "    ST  : $($script:SSL_CERT_STATE)"
    Write-Host "    L   : $($script:SSL_CERT_CITY)"
    Write-Host "    Días: $($script:SSL_CERT_DAYS)"
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_pedir_pfx_password
# Pide la contraseña para el PFX con confirmación.
# ─────────────────────────────────────────────────────────────────────────────
function ssl_pedir_pfx_password {
    while ($true) {
        Write-Host ""
        msg_info "Contraseña para el archivo PFX (mínimo 6 caracteres)"
        msg_input "Contraseña: "
        $p1 = Read-Host -AsSecureString
        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        if ($plain1.Length -lt 6) { msg_error "Mínimo 6 caracteres"; continue }

        msg_input "Confirmar : "
        $p2 = Read-Host -AsSecureString
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                  [Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))

        if ($plain1 -ne $plain2) { msg_error "Las contraseñas no coinciden"; continue }

        $script:SSL_PFX_PASS = $plain1
        return $p1   # Devuelve SecureString para Export-PfxCertificate
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ssl_generar_certificado
# Genera el certificado en el Store y exporta a los formatos necesarios.
#
# $1 = directorio destino (ej: C:\SSL\reprobados\apache)
# $2 = nombre del servicio (display)
# $3 = $true si necesita PEM (.crt + .key); $false si solo PFX
#
# Retorna $true si OK. Rellena $script:SSL_THUMBPRINT.
# ─────────────────────────────────────────────────────────────────────────────
function ssl_generar_certificado {
    param([string]$Directorio, [string]$Servicio, [bool]$NecesitaPEM = $true)

    # Crear directorio con permisos explícitos (evita Permission denied de openssl)
    if (-not (Test-Path $Directorio)) {
        New-Item -ItemType Directory -Path $Directorio -Force | Out-Null
    }
    # Garantizar FullControl usando SID S-1-5-32-544 (Administrators)
    # El SID es universal — no depende del idioma del SO
    try {
        $adminSid  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
        $aclDir    = Get-Acl $Directorio
        # Para directorios sí se usan ContainerInherit,ObjectInherit
        $inherit   = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
        $propagate = [System.Security.AccessControl.PropagationFlags]::None
        $allow     = [System.Security.AccessControl.AccessControlType]::Allow
        $ruleAdmin  = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $adminSid, "FullControl", $inherit, $propagate, $allow)
        $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $systemSid, "FullControl", $inherit, $propagate, $allow)
        $aclDir.SetAccessRule($ruleAdmin)
        $aclDir.SetAccessRule($ruleSystem)
        # NETWORK SERVICE necesita listar el directorio para leer la KEY
        $netSvcSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-20")
        $ruleNetSvc = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $netSvcSid,
            [System.Security.AccessControl.FileSystemRights]"ReadAndExecute,ListDirectory",
            [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
            [System.Security.AccessControl.PropagationFlags]"None",
            [System.Security.AccessControl.AccessControlType]"Allow")
        $aclDir.AddAccessRule($ruleNetSvc)
        Set-Acl -Path $Directorio -AclObject $aclDir -ErrorAction Stop
        msg_success "Directorio SSL listo: $Directorio"
    } catch {
        msg_alert "Permisos no ajustados en $Directorio (no critico): $_"
    }

    $pfxPath  = Join-Path $Directorio $script:SSL_PFX_FILE
    $certPath = Join-Path $Directorio $script:SSL_CERT_FILE
    $keyPath  = Join-Path $Directorio $script:SSL_KEY_FILE

    # ── Paso 1: New-SelfSignedCertificate ─────────────────────────────────
    msg_process "Generando certificado self-signed en Certificate Store..."

    $fechaExp = (Get-Date).AddDays($script:SSL_CERT_DAYS)

    # Construir Subject con todos los campos
    $subject = "CN=$($script:SSL_CERT_CN), " +
               "O=$($script:SSL_CERT_ORG), " +
               "OU=$($script:SSL_CERT_OU), " +
               "C=$($script:SSL_CERT_COUNTRY), " +
               "ST=$($script:SSL_CERT_STATE), " +
               "L=$($script:SSL_CERT_CITY)"

    # Determinar si el CN es IP o DNS para el SAN
    $sanType = if ($script:SSL_CERT_CN -match '^\d{1,3}(\.\d{1,3}){3}$') {
        "IPAddress"
    } else {
        "DnsName"
    }

    try {
        $cert = New-SelfSignedCertificate `
            -Subject $subject `
            -DnsName $script:SSL_CERT_CN `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -HashAlgorithm SHA256 `
            -NotAfter $fechaExp `
            -KeyUsage DigitalSignature, KeyEncipherment `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1") `
            -ErrorAction Stop

        $script:SSL_THUMBPRINT = $cert.Thumbprint
        msg_success "Certificado generado — Thumbprint: $($script:SSL_THUMBPRINT.Substring(0,16))..."
    }
    catch {
        msg_error "Error al generar certificado: $($_.Exception.Message)"
        return $false
    }

    # ── Paso 2: Exportar a PFX ────────────────────────────────────────────
    msg_process "Exportando a PFX..."

    $secPass = ssl_pedir_pfx_password

    try {
        Export-PfxCertificate `
            -Cert "Cert:\LocalMachine\My\$($script:SSL_THUMBPRINT)" `
            -FilePath $pfxPath `
            -Password $secPass `
            -Force `
            -ErrorAction Stop | Out-Null
        msg_success "PFX exportado: $pfxPath"
    }
    catch {
        msg_error "Error al exportar PFX: $($_.Exception.Message)"
        return $false
    }

    # ── Paso 3: Extraer CRT + KEY del PFX con openssl (si necesita PEM) ──
    if ($NecesitaPEM) {
        msg_process "Extrayendo CRT y KEY del PFX con openssl..."

        if (-not (ssl_verificar_openssl)) { return $false }

        # Extraer certificado (.crt)
        if (Test-Path $certPath) { Remove-Item $certPath -Force -ErrorAction SilentlyContinue }
        $rc = & openssl pkcs12 `
            -in  "`"$pfxPath`"" `
            -out "`"$certPath`"" `
            -nokeys `
            -passin "pass:$($script:SSL_PFX_PASS)" `
            -passout "pass:" 2>&1
        if ($LASTEXITCODE -ne 0) {
            msg_error "Error al extraer .crt del PFX"
            Write-Host "    $rc"
            return $false
        }
        msg_success "CRT extraído: $certPath"

        # Extraer clave privada (.key) sin cifrado adicional
        if (Test-Path $keyPath) { Remove-Item $keyPath -Force -ErrorAction SilentlyContinue }
        $rc = & openssl pkcs12 `
            -in  "`"$pfxPath`"" `
            -out "`"$keyPath`"" `
            -nocerts `
            -nodes `
            -passin "pass:$($script:SSL_PFX_PASS)" 2>&1
        if ($LASTEXITCODE -ne 0) {
            msg_error "Error al extraer .key del PFX"
            Write-Host "    $rc"
            return $false
        }
        msg_success "KEY extraída: $keyPath"

        # Asegurar que solo SYSTEM y Administrators leen la KEY
        # Permisos KEY — para archivos InheritanceFlags debe ser None
        # Se da lectura a SYSTEM y Administrators (SIDs universales)
        # Nginx lee el archivo como proceso del sistema
        try {
            $keySidAdmin  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
            $keySidSystem = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
            $keyAcl = Get-Acl $keyPath
            $keyAcl.SetAccessRuleProtection($true, $false)
            # InheritanceFlags.None y PropagationFlags.None para archivos
            $keyNone      = [System.Security.AccessControl.InheritanceFlags]::None
            $keyPropNone  = [System.Security.AccessControl.PropagationFlags]::None
            $keyAllow     = [System.Security.AccessControl.AccessControlType]::Allow
            $keyRuleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $keySidSystem, "FullControl", $keyNone, $keyPropNone, $keyAllow)
            $keyRuleAdmin  = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $keySidAdmin, "FullControl", $keyNone, $keyPropNone, $keyAllow)
            $keyAcl.AddAccessRule($keyRuleSystem)
            $keyAcl.AddAccessRule($keyRuleAdmin)
            # NETWORK SERVICE (S-1-5-20) y LOCAL SERVICE (S-1-5-19)
            # necesitan leer la KEY — nginx y servicios web corren como estos usuarios
            $keyReadRights = [System.Security.AccessControl.FileSystemRights]"Read,ReadAndExecute"
            $keyNoInherit  = [System.Security.AccessControl.InheritanceFlags]"None"
            foreach ($svcSid in @("S-1-5-20", "S-1-5-19")) {
                $sid = New-Object System.Security.Principal.SecurityIdentifier($svcSid)
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sid, $keyReadRights, $keyNoInherit, $keyPropagate, $keyAllow)
                $keyAcl.AddAccessRule($rule)
            }
            Set-Acl -Path $keyPath -AclObject $keyAcl -ErrorAction SilentlyContinue
            msg_success "Permisos aplicados en KEY (SYSTEM + Administrators + NETWORK/LOCAL SERVICE)"
        } catch {
            msg_alert "Permisos KEY no ajustados (no critico): $_"
        }
    }

    Write-Host ""
    msg_success "Certificado generado para ${Servicio}:"
    Write-Host "    Thumbprint : $($script:SSL_THUMBPRINT)"
    Write-Host "    PFX        : $pfxPath"
    if ($NecesitaPEM) {
        Write-Host "    CRT        : $certPath"
        Write-Host "    KEY        : $keyPath"
    }
    Write-Host "    Válido     : $($script:SSL_CERT_DAYS) días hasta $(($fechaExp).ToString('yyyy-MM-dd'))"

    return $true
}