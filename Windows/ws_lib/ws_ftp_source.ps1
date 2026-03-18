# =============================================================================
# ws_lib/ws_ftp_source.ps1 — Instalación de servicios HTTP desde repositorio FTP
#
# Equivalente a ws_lib/ws_ftp_source.sh de Linux.
#
# Flujo:
#   1. Pedir IP, usuario, contraseña, directorio base del FTP
#   2. Detectar FTPS automáticamente
#   3. Seleccionar OS (Linux/Windows) y servicio
#   4. Listar versiones disponibles en http/<OS>/<Servicio>/
#   5. El usuario selecciona la versión
#   6. Descargar paquete + .sha256
#   7. Verificar integridad SHA256
#   8. Instalar (solo si OS=Windows — Linux se descarga pero no instala)
#
# Estructura esperada en el FTP:
#   <dir_base>/http/Linux/Apache/   → *.rpm  + *.sha256
#   <dir_base>/http/Linux/Nginx/    → *.rpm  + *.sha256
#   <dir_base>/http/Linux/Tomcat/   → *.rpm  + *.sha256
#   <dir_base>/http/Windows/Apache/ → *.zip  + *.sha256  (ApacheLounge)
#   <dir_base>/http/Windows/Nginx/  → *.zip  + *.sha256
#   <dir_base>/http/Windows/Tomcat/ → *.exe  + *.sha256
#
# Requiere: lib/ui.ps1, ws_lib/ws_utils.ps1
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Variables de sesión FTP (se rellenan en ftp_src_conectar)
# ─────────────────────────────────────────────────────────────────────────────
$script:FTP_SRC_HOST      = ""
$script:FTP_SRC_PORT      = 21
$script:FTP_SRC_USER      = ""
$script:FTP_SRC_PASS      = ""
$script:FTP_SRC_BASE_PATH = "/"
$script:FTP_SRC_SSL       = $false   # $true si el servidor acepta FTPS
$script:FTP_SRC_TMPDIR    = ""
$script:FTP_SRC_LAST_PORT = 0       # Puerto elegido en ftp_src_flujo_completo

# ─────────────────────────────────────────────────────────────────────────────
# _ftp_src_limpiar  (interna)
# Elimina el directorio temporal de descargas.
# ─────────────────────────────────────────────────────────────────────────────
function _ftp_src_limpiar {
    if ($script:FTP_SRC_TMPDIR -and (Test-Path $script:FTP_SRC_TMPDIR)) {
        Remove-Item $script:FTP_SRC_TMPDIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _ftp_src_request  (interna)
# Realiza una petición FTP usando .NET WebClient.
# Soporta FTP y FTPS (SSL explícito).
#
# $1 = URI completa  ftp://host:puerto/ruta
# $2 = archivo destino local (si $null solo lista)
# Retorna el contenido como string si $destino es $null,
#         $true/$false si $destino tiene valor.
# ─────────────────────────────────────────────────────────────────────────────
function _ftp_src_request {
    param([string]$Uri, [string]$Destino = $null)

    try {
        $req = [System.Net.FtpWebRequest]::Create($Uri)
        $req.Credentials = New-Object System.Net.NetworkCredential(
            $script:FTP_SRC_USER, $script:FTP_SRC_PASS)
        $req.EnableSsl        = $script:FTP_SRC_SSL
        $req.UseBinary        = $true
        $req.UsePassive       = $true
        $req.KeepAlive        = $false
        $req.Timeout          = 30000
        $req.ReadWriteTimeout = 60000

        # Ignorar errores de certificado self-signed
        if ($script:FTP_SRC_SSL) {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }

        if ($Destino) {
            $req.Method = [System.Net.WebRequestMethods+Ftp]::DownloadFile
            $resp   = $req.GetResponse()
            $stream = $resp.GetResponseStream()
            $fs     = [System.IO.File]::Create($Destino)
            $buf    = New-Object byte[] 8192
            do {
                $read = $stream.Read($buf, 0, $buf.Length)
                if ($read -gt 0) { $fs.Write($buf, 0, $read) }
            } while ($read -gt 0)
            $fs.Close()
            $stream.Close()
            $resp.Close()
            return $true
        } else {
            $req.Method = [System.Net.WebRequestMethods+Ftp]::ListDirectory
            $resp   = $req.GetResponse()
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $lista  = $reader.ReadToEnd()
            $reader.Close()
            $resp.Close()
            return $lista
        }
    } catch {
        return $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _ftp_src_uri  (interna)
# Construye la URI FTP completa para una ruta relativa.
# ─────────────────────────────────────────────────────────────────────────────
function _ftp_src_uri {
    param([string]$Ruta)
    $base = $script:FTP_SRC_BASE_PATH.TrimEnd('/')
    $r    = $Ruta.TrimStart('/')
    return "ftp://$($script:FTP_SRC_HOST):$($script:FTP_SRC_PORT)/$base/$r".Replace('//', '/').Replace('ftp:/', 'ftp://')
}

# ─────────────────────────────────────────────────────────────────────────────
# ftp_src_conectar  (pública)
# Solicita credenciales y verifica la conexión FTP/FTPS.
# ─────────────────────────────────────────────────────────────────────────────
function ftp_src_conectar {
    Write-Separator
    msg_info "Repositorio FTP — Credenciales"
    Write-Separator
    Write-Host ""

    msg_input "IP del servidor FTP: "
    $script:FTP_SRC_HOST = Read-Host
    if ([string]::IsNullOrWhiteSpace($script:FTP_SRC_HOST)) {
        msg_error "La IP no puede estar vacía"; return $false
    }

    msg_input "Puerto [21]: "
    $p = Read-Host
    $script:FTP_SRC_PORT = if ([string]::IsNullOrWhiteSpace($p)) { 21 } else { [int]$p }

    msg_input "Usuario: "
    $script:FTP_SRC_USER = Read-Host
    if ([string]::IsNullOrWhiteSpace($script:FTP_SRC_USER)) {
        msg_error "El usuario no puede estar vacío"; return $false
    }

    msg_input "Contraseña: "
    $script:FTP_SRC_PASS = Read-Host
    if ([string]::IsNullOrWhiteSpace($script:FTP_SRC_PASS)) {
        msg_error "La contraseña no puede estar vacía"; return $false
    }

    msg_input "Directorio base en el FTP [/]: "
    $d = Read-Host
    $bp = if ([string]::IsNullOrWhiteSpace($d)) { "/" } else { $d.Trim('/') }
    # Garantizar slash inicial, sin slash final (excepto raiz)
    if (-not $bp.StartsWith('/')) { $bp = '/' + $bp }
    $script:FTP_SRC_BASE_PATH = if ($bp -eq '/') { '/' } else { $bp.TrimEnd('/') }

    Write-Host ""
    msg_process "Verificando conexión..."

    # Orden: FTPS cert válido → FTPS cert autofirmado → FTP plano
    # El callback debe setearse ANTES de crear la conexión de prueba.
    $script:FTP_SRC_SSL = $true
    $lista = _ftp_src_request (_ftp_src_uri "")
    if ($null -ne $lista) {
        msg_success "Conexión FTPS establecida"
    } else {
        # Reintentar FTPS ignorando certificado autofirmado
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $lista = _ftp_src_request (_ftp_src_uri "")
        if ($null -ne $lista) {
            msg_success "Conexión FTPS establecida (certificado autofirmado aceptado)"
            msg_alert  "Certificado autofirmado — tráfico cifrado sin validación de identidad"
        } else {
            $script:FTP_SRC_SSL = $false
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
            $lista = _ftp_src_request (_ftp_src_uri "")
            if ($null -ne $lista) {
                msg_success "Conexión FTP establecida"
            } else {
                msg_error "No se pudo conectar a $($script:FTP_SRC_HOST):$($script:FTP_SRC_PORT)"
                msg_info  "Modos probados: FTPS, FTPS/cert-autofirmado, FTP plano"
                msg_info  "Verifique IP, puerto y credenciales"
                return $false
            }
        }
    }

    # Crear directorio temporal
    $script:FTP_SRC_TMPDIR = Join-Path $env:TEMP "ftp_src_$(Get-Random)"
    New-Item -ItemType Directory -Path $script:FTP_SRC_TMPDIR -Force | Out-Null

    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# _ftp_src_nombre_directorio  (interna)
# Mapea el nombre interno del servicio al nombre de directorio en el FTP.
# ─────────────────────────────────────────────────────────────────────────────
function _ftp_src_nombre_directorio {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "iis"    { return "Apache" }   # IIS usa los binarios de Apache en Windows
        "apache" { return "Apache" }
        "nginx"  { return "Nginx"  }
        "tomcat" { return "Tomcat" }
        default  { return $Servicio }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# _ftp_src_extensiones  (interna)
# Retorna las extensiones válidas de paquete para un OS dado.
# ─────────────────────────────────────────────────────────────────────────────
function _ftp_src_extensiones {
    param([string]$OS)
    switch ($OS) {
        "Linux"   { return @(".rpm") }
        "Windows" { return @(".zip", ".exe", ".msi") }
        default   { return @(".rpm", ".zip", ".exe", ".msi") }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ftp_src_listar_versiones  (pública)
# Lista los paquetes disponibles para un servicio y OS en el FTP.
# Excluye archivos .sha256.
#
# $1 = Servicio (apache|nginx|tomcat|iis)
# $2 = OS (Linux|Windows)
# Retorna array con nombres de archivo ordenados (más reciente primero).
# ─────────────────────────────────────────────────────────────────────────────
function ftp_src_listar_versiones {
    param([string]$Servicio, [string]$OS = "Windows")

    $dirServicio = _ftp_src_nombre_directorio $Servicio
    $ruta        = "http/$OS/$dirServicio/"
    $uri         = _ftp_src_uri $ruta

    msg_process "Listando versiones en http/$OS/$dirServicio/..."

    $listado = _ftp_src_request $uri
    if ($null -eq $listado) {
        msg_error "No se pudo listar: http/$OS/$dirServicio/"
        msg_info  "Verifique que el repositorio FTP está construido con ftp_repo_builder.sh"
        return @()
    }

    $exts    = _ftp_src_extensiones $OS
    $archivos = $listado -split "`n" |
                ForEach-Object { $_.Trim().Trim("`r") } |
                Where-Object {
                    $linea = $_
                    -not [string]::IsNullOrWhiteSpace($linea) -and
                    -not $linea.EndsWith(".sha256") -and
                    -not $linea.StartsWith('.') -and
                    ($exts | Where-Object { $linea.EndsWith($_) })
                } |
                Sort-Object { $_ } -Descending

    if (-not $archivos -or @($archivos).Count -eq 0) {
        msg_alert "No se encontraron paquetes en http/$OS/$dirServicio/"
        return @()
    }

    return @($archivos)
}

# ─────────────────────────────────────────────────────────────────────────────
# ftp_src_seleccionar_version  (pública)
# Muestra las versiones disponibles y permite seleccionar una.
#
# $1 = Servicio
# $2 = OS (Linux|Windows)
# $3 = [ref] variable destino para el nombre del archivo seleccionado
# ─────────────────────────────────────────────────────────────────────────────
function ftp_src_seleccionar_version {
    param([string]$Servicio, [string]$OS = "Windows", [ref]$OutArchivo)

    $versiones = ftp_src_listar_versiones $Servicio $OS
    if (@($versiones).Count -eq 0) { return $false }

    $total = @($versiones).Count

    Clear-Host
    Write-Separator
    msg_info "Versiones disponibles en FTP — $Servicio ($OS)"
    Write-Separator
    Write-Host ""
    Write-Host ("  {0,-5}  {1}" -f "NUM", "ARCHIVO")
    Write-Separator

    for ($i = 0; $i -lt $total; $i++) {
        $num     = $i + 1
        $archivo = @($versiones)[$i]
        if ($i -eq 0) {
            Write-Host ("  {0,-5}  {1}  " -f "$num)", $archivo) -NoNewline
            Write-Host "← más reciente" -ForegroundColor Green
        } else {
            Write-Host ("  {0,-5}  {1}" -f "$num)", $archivo)
        }
    }

    Write-Host ""

    $opcion = 0
    do {
        msg_input "Seleccione versión [1-$total]: "
        $entrada = Read-Host
        if ($entrada -match '^\d+$' -and [int]$entrada -ge 1 -and [int]$entrada -le $total) {
            $opcion = [int]$entrada
        } else {
            msg_error "Ingrese un número entre 1 y $total"
        }
    } while ($opcion -eq 0)

    $seleccionado = @($versiones)[$opcion - 1]
    $OutArchivo.Value = $seleccionado

    Write-Host ""
    msg_success "Versión seleccionada: $seleccionado"
    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# ftp_src_descargar_verificar  (pública)
# Descarga un paquete del FTP y verifica su SHA256.
#
# $1 = Servicio
# $2 = OS (Linux|Windows)
# $3 = Nombre del archivo a descargar
# $4 = [ref] variable destino para la ruta local del archivo
# Retorna $true si OK.
# ─────────────────────────────────────────────────────────────────────────────
function ftp_src_descargar_verificar {
    param([string]$Servicio, [string]$OS, [string]$Archivo, [ref]$OutRutaLocal)

    $dirServicio  = _ftp_src_nombre_directorio $Servicio
    $rutaFtp      = "http/$OS/$dirServicio/$Archivo"
    $rutaFtpHash  = "http/$OS/$dirServicio/$Archivo.sha256"
    $rutaLocal    = Join-Path $script:FTP_SRC_TMPDIR $Archivo
    $rutaLocalHash= "$rutaLocal.sha256"

    Write-Separator
    msg_info "Descargando desde repositorio FTP"
    Write-Separator
    Write-Host ""
    msg_info "Servidor : $($script:FTP_SRC_HOST):$($script:FTP_SRC_PORT)"
    msg_info "Archivo  : $Archivo"
    msg_info "OS       : $OS"
    Write-Host ""

    # ── Descargar paquete ─────────────────────────────────────────────────────
    msg_process "Descargando $Archivo..."
    $ok = _ftp_src_request (_ftp_src_uri $rutaFtp) $rutaLocal
    if (-not $ok -or -not (Test-Path $rutaLocal) -or (Get-Item $rutaLocal).Length -eq 0) {
        msg_error "No se pudo descargar: $Archivo"
        msg_info  "Ruta FTP: $rutaFtp"
        return $false
    }
    $sizeMB = '{0:N1}' -f ((Get-Item $rutaLocal).Length / 1MB)
    msg_success "Descarga completada: ${sizeMB} MB"

    # ── Descargar .sha256 ─────────────────────────────────────────────────────
    msg_process "Descargando hash de integridad..."
    $okHash = _ftp_src_request (_ftp_src_uri $rutaFtpHash) $rutaLocalHash
    if (-not $okHash -or -not (Test-Path $rutaLocalHash) -or (Get-Item $rutaLocalHash).Length -eq 0) {
        msg_alert "No se encontró .sha256 en el FTP — continuando sin verificación"
        $OutRutaLocal.Value = $rutaLocal
        return $true
    }
    msg_success "Hash descargado"

    # ── Verificar integridad ──────────────────────────────────────────────────
    msg_process "Verificando integridad SHA256..."

    $hashEsperado = (Get-Content $rutaLocalHash -Raw).Trim() -split '\s+' | Select-Object -First 1
    $hashReal     = (Get-FileHash -Path $rutaLocal -Algorithm SHA256).Hash.ToLower()
    $hashEsperado = $hashEsperado.ToLower()

    if ($hashReal -eq $hashEsperado) {
        msg_success "Integridad verificada — SHA256 coincide"
        msg_info    "  $($hashReal.Substring(0,16))...$($hashReal.Substring($hashReal.Length-8))"
    } else {
        msg_error "¡INTEGRIDAD COMPROMETIDA! SHA256 NO coincide"
        msg_info  "  Esperado : $($hashEsperado.Substring(0,32))..."
        msg_info  "  Real     : $($hashReal.Substring(0,32))..."
        msg_error "El archivo puede estar corrupto o alterado"
        Remove-Item $rutaLocal     -Force -ErrorAction SilentlyContinue
        Remove-Item $rutaLocalHash -Force -ErrorAction SilentlyContinue
        return $false
    }

    $OutRutaLocal.Value = $rutaLocal
    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# ftp_src_instalar_windows  (pública)
# Instala un paquete Windows descargado del FTP.
# El método varía según el servicio y la extensión del archivo.
#
# $1 = Servicio (apache|nginx|tomcat|iis)
# $2 = Ruta local del archivo descargado
# $3 = Puerto de escucha elegido por el usuario
# ─────────────────────────────────────────────────────────────────────────────
function ftp_src_instalar_windows {
    param([string]$Servicio, [string]$RutaLocal, [int]$Puerto)

    $archivo = Split-Path $RutaLocal -Leaf
    Write-Separator
    msg_info "Instalando $archivo (desde FTP)"
    Write-Separator
    Write-Host ""

    switch ($Servicio.ToLower()) {

        "apache" {
            # ZIP de ApacheLounge — mismo flujo que http_instalar_apache
            if (-not $archivo.EndsWith(".zip")) {
                msg_error "Se esperaba un .zip para Apache, se recibió: $archivo"
                return $false
            }

            msg_process "Extrayendo Apache..."
            $apacheDestino = "C:\Apache24"
            if (Test-Path $apacheDestino) {
                Rename-Item $apacheDestino `
                    "${apacheDestino}_bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')" `
                    -ErrorAction SilentlyContinue
            }

            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $tmpExtract = Join-Path $script:FTP_SRC_TMPDIR "apache_extract"
                [System.IO.Compression.ZipFile]::ExtractToDirectory($RutaLocal, $tmpExtract)

                $apacheFolder = Get-ChildItem $tmpExtract -Directory |
                                Where-Object { $_.Name -match 'Apache' } |
                                Select-Object -First 1
                if (-not $apacheFolder) {
                    msg_error "No se encontró carpeta Apache en el ZIP"
                    return $false
                }
                Copy-Item $apacheFolder.FullName $apacheDestino -Recurse -Force
                msg_success "Apache extraído en: $apacheDestino"
            } catch {
                msg_error "Error al extraer ZIP: $_"
                return $false
            }

            # Configurar httpd.conf
            $Script:HTTP_CONF_APACHE = "$apacheDestino\conf\httpd.conf"
            $Script:HTTP_DIR_APACHE  = "$apacheDestino\htdocs"
            $httpdExe                = "$apacheDestino\bin\httpd.exe"

            if (Test-Path $Script:HTTP_CONF_APACHE) {
                $srvrootFwd = $apacheDestino -replace '\\', '/'
                $bytes      = [System.IO.File]::ReadAllBytes($Script:HTTP_CONF_APACHE)
                $bom        = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
                $contenido  = if ($bom) {
                    [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
                } else { [System.Text.Encoding]::UTF8.GetString($bytes) }

                $contenido = $contenido -replace 'Define SRVROOT ".*"', "Define SRVROOT `"$srvrootFwd`""
                $contenido = $contenido -replace 'Listen\s+\d+',         "Listen $Puerto"
                $contenido = $contenido -replace 'ServerName\s+\S+:\d+', "ServerName localhost:$Puerto"

                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($Script:HTTP_CONF_APACHE, $contenido, $utf8NoBom)
                msg_success "httpd.conf configurado — Puerto=$Puerto"
            }

            # Registrar e iniciar servicio
            $svcAnterior = Get-Service -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -match '^Apache|^httpd' } |
                           Select-Object -First 1
            if ($svcAnterior) {
                Stop-Service $svcAnterior.Name -Force -ErrorAction SilentlyContinue
                & $httpdExe -k uninstall -n $svcAnterior.Name 2>$null
                Start-Sleep -Seconds 1
            }
            & $httpdExe -k install -n "Apache2.4" 2>&1 | ForEach-Object { Write-Host "    $_" }
            $Script:HTTP_WINSVC_APACHE = "Apache2.4"
            Set-Service "Apache2.4" -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service "Apache2.4" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2

            if (check_service_active "Apache2.4") {
                msg_success "Apache2.4 iniciado y activo"
                return $true
            } else {
                msg_error "Apache no levantó — revise el Visor de Eventos"
                return $false
            }
        }

        "nginx" {
            if (-not $archivo.EndsWith(".zip")) {
                msg_error "Se esperaba un .zip para Nginx, se recibió: $archivo"
                return $false
            }

            msg_process "Extrayendo Nginx..."
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($RutaLocal, "C:\tools")
                msg_success "Nginx extraído en C:\tools"
            } catch {
                msg_error "Error al extraer ZIP: $_"
                return $false
            }

            # Localizar nginx.exe y nginx.conf
            $nginxExe = Get-ChildItem "C:\tools" -Recurse -Filter nginx.exe `
                        -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $nginxExe) { msg_error "nginx.exe no encontrado tras extracción"; return $false }

            $nginxDir = Split-Path $nginxExe.FullName
            $Script:HTTP_CONF_NGINX = Join-Path $nginxDir "conf\nginx.conf"
            $Script:HTTP_DIR_NGINX  = Join-Path $nginxDir "html"

            if (Test-Path $Script:HTTP_CONF_NGINX) {
                $bytes     = [System.IO.File]::ReadAllBytes($Script:HTTP_CONF_NGINX)
                $contenido = [System.Text.Encoding]::UTF8.GetString($bytes)
                $contenido = $contenido -replace 'listen\s+\d+;', "listen $Puerto;"
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($Script:HTTP_CONF_NGINX, $contenido, $utf8NoBom)
                msg_success "nginx.conf configurado — Puerto=$Puerto"
            }

            # Registrar con NSSM
            $nssm = Get-Command nssm -ErrorAction SilentlyContinue
            if (-not $nssm) {
                msg_alert "Instalando NSSM via choco..."
                & choco install nssm -y 2>&1 | Out-Null
                $nssm = Get-Command nssm -ErrorAction SilentlyContinue
            }
            if ($nssm) {
                & nssm install nginx $nginxExe.FullName 2>&1 | Out-Null
                & nssm set nginx AppDirectory $nginxDir 2>&1 | Out-Null
                msg_success "Nginx registrado como servicio via NSSM"
            }

            $Script:HTTP_WINSVC_NGINX = "nginx"
            Start-Service "nginx" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2

            if (check_service_active "nginx") {
                msg_success "Nginx iniciado y activo"
                return $true
            } else {
                msg_error "Nginx no levantó"
                return $false
            }
        }

        "tomcat" {
            if (-not ($archivo.EndsWith(".exe") -or $archivo.EndsWith(".msi"))) {
                msg_error "Se esperaba un .exe/.msi para Tomcat, se recibió: $archivo"
                return $false
            }

            msg_process "Ejecutando instalador de Tomcat (instalación silenciosa)..."
            msg_info "El instalador puede solicitar confirmación — responda según necesite"
            Write-Host ""

            # Instalar en modo silencioso
            if ($archivo.EndsWith(".exe")) {
                $proc = Start-Process $RutaLocal `
                    -ArgumentList "/S", "/D=C:\Tomcat" `
                    -Wait -PassThru -ErrorAction SilentlyContinue
            } else {
                $proc = Start-Process msiexec.exe `
                    -ArgumentList "/i", "`"$RutaLocal`"", "/quiet", "/norestart" `
                    -Wait -PassThru -ErrorAction SilentlyContinue
            }

            Start-Sleep -Seconds 3

            # Detectar servicio Tomcat registrado
            $svcTomcat = Get-Service -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -match '^Tomcat' } |
                         Select-Object -First 1

            if ($svcTomcat) {
                $Script:HTTP_WINSVC_TOMCAT = $svcTomcat.Name

                # Configurar puerto en server.xml
                $serverXml = Get-ChildItem "C:\ProgramData" -Recurse -Filter server.xml `
                             -ErrorAction SilentlyContinue |
                             Where-Object { $_.FullName -match 'conf' } |
                             Select-Object -First 1
                if ($serverXml) {
                    $Script:HTTP_CONF_TOMCAT = $serverXml.FullName
                    try {
                        [xml]$xml = Get-Content $serverXml.FullName
                        $conn = $xml.Server.Service.Connector |
                                Where-Object { $_.protocol -match 'HTTP' } |
                                Select-Object -First 1
                        if ($conn) {
                            $conn.SetAttribute("port", "$Puerto")
                            $xml.Save($serverXml.FullName)
                            msg_success "server.xml configurado — Puerto=$Puerto"
                        }
                    } catch { msg_alert "No se pudo configurar server.xml: $_" }
                }

                Start-Service $svcTomcat.Name -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3

                if (check_service_active $svcTomcat.Name) {
                    msg_success "Tomcat iniciado y activo"
                    return $true
                } else {
                    msg_error "Tomcat no levantó"
                    return $false
                }
            } else {
                msg_alert "Servicio Tomcat no detectado tras instalación"
                msg_info  "Puede requerir configuración manual"
                return $false
            }
        }

        "iis" {
            msg_info "IIS se instala via DISM — no requiere paquete del FTP"
            msg_info "Los archivos de IIS en el repositorio FTP son para referencia"
            msg_info "Use la opción de instalación normal de ws_manager.ps1 para IIS"
            return $false
        }

        default {
            msg_error "Servicio no reconocido: $Servicio"
            return $false
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ftp_src_flujo_completo  (pública)
# Orquesta el flujo completo desde FTP para Windows:
#   conectar → seleccionar OS → seleccionar versión → descargar → verificar → instalar
#
# $1 = Servicio (apache|nginx|tomcat|iis)
# $2 = Puerto de escucha
# $3 = [ref] variable destino para la versión instalada
# ─────────────────────────────────────────────────────────────────────────────
function ftp_src_flujo_completo {
    param([string]$Servicio, [ref]$OutVersion)

    # ── Conectar ──────────────────────────────────────────────────────────────
    if (-not (ftp_src_conectar)) { return $false }
    Write-Host ""

    # ── Seleccionar OS ────────────────────────────────────────────────────────
    Write-Separator
    msg_info "Sistema Operativo del paquete a descargar"
    Write-Separator
    Write-Host ""
    Write-Host "  1) Windows  — instala el paquete en este servidor"
    Write-Host "  2) Linux    — solo descarga (no instala en Windows)"
    Write-Host ""
    $osOpcion = ""
    do {
        msg_input "OS [1/2]: "
        $osOpcion = Read-Host
        if ($osOpcion -ne "1" -and $osOpcion -ne "2") {
            msg_error "Ingrese 1 o 2"
            $osOpcion = ""
        }
    } while ([string]::IsNullOrEmpty($osOpcion))

    $osElegido = if ($osOpcion -eq "1") { "Windows" } else { "Linux" }
    Write-Host ""

    # ── Seleccionar versión ───────────────────────────────────────────────────
    $archivoSel = ""
    if (-not (ftp_src_seleccionar_version $Servicio $osElegido ([ref]$archivoSel))) {
        _ftp_src_limpiar
        return $false
    }
    Write-Host ""

    # ── Descargar y verificar ─────────────────────────────────────────────────
    $rutaLocal = ""
    if (-not (ftp_src_descargar_verificar $Servicio $osElegido $archivoSel ([ref]$rutaLocal))) {
        _ftp_src_limpiar
        return $false
    }
    Write-Host ""

    # ── Seleccionar puerto (Paso 3) — antes de instalar para configurar los archivos
    $Puerto = http_seleccionar_puerto $Servicio "Paso 3 de 4 — Puerto de escucha"
    $script:FTP_SRC_LAST_PORT = $Puerto   # expuesto para ws_install.ps1
    Write-Host ""

    # ── Instalar (solo Windows) ───────────────────────────────────────────────
    if ($osElegido -eq "Windows") {
        if (-not (ftp_src_instalar_windows $Servicio $rutaLocal $Puerto)) {
            _ftp_src_limpiar
            return $false
        }
        # Extraer versión del nombre del archivo
        if ($archivoSel -match '[\d]+\.[\d]+\.[\d]+') {
            $OutVersion.Value = $Matches[0]
        } else {
            $OutVersion.Value = "desde-FTP"
        }
    } else {
        # Linux — informar dónde quedó el archivo
        $destFinal = Join-Path ([Environment]::GetFolderPath('Desktop')) $archivoSel
        Copy-Item $rutaLocal $destFinal -Force -ErrorAction SilentlyContinue
        msg_success "Archivo Linux guardado en: $destFinal"
        msg_info  "Para instalar en Linux: transfiera el archivo al servidor Linux"
        msg_info  "  e instale con: sudo dnf localinstall $archivoSel"
        $OutVersion.Value = "descargado-Linux"
    }

    _ftp_src_limpiar
    return $true
}