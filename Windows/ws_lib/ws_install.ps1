#
# FunctionsHTTP-B.ps1
# Grupo B — Instalación de servicios HTTP
#
# Equivalente a FunctionsHTTP-B.sh de la práctica Linux.
# Flujo encadenado:
#   Selección → Versiones (choco) → Puerto → Instalación → Config → Firewall
#
# Servicios: IIS (DISM), Apache Win64 (choco), Nginx (choco), Tomcat (choco)
#
# Funciones públicas:
#   http_seleccionar_servicio()     — Menú de selección (4 servicios)
#   http_consultar_versiones()      — Versiones disponibles vía choco
#   http_seleccionar_version()      — Muestra versiones y captura elección
#   http_seleccionar_puerto()       — Captura y valida puerto de escucha
#   http_crear_usuario_dedicado()   — Usuario local sin login interactivo
#   http_crear_index()              — index.html personalizado por servicio
#   http_instalar_iis()             — Instalación via DISM + WebAdministration
#   http_instalar_apache()          — Instalación via choco
#   http_instalar_nginx()           — Instalación via choco
#   http_instalar_tomcat()          — Instalación via choco + Java
#   http_menu_instalar()            — Orquestador del flujo completo
#
# Requiere: utils.ps1, utilsHTTP.ps1, validatorsHTTP.ps1, FunctionsHTTP-A.ps1
#

#Requires -Version 5.1

#
# _http_seleccionar_servicio_instalado  (interna)
#
# Muestra solo los servicios ya instalados para las operaciones de
# configuración (Grupos C, D, E). Devuelve el nombre interno.
# Equivalente a _http_seleccionar_servicio_instalado de FunctionsHTTP-C.sh
#
function _http_seleccionar_servicio_instalado {
    $servicios = @(
        @{ Nombre = "IIS"; Interno = "iis"; WinSvc = $Script:HTTP_WINSVC_IIS }
        @{ Nombre = "Apache (httpd)"; Interno = "apache"; WinSvc = $Script:HTTP_WINSVC_APACHE }
        @{ Nombre = "Nginx"; Interno = "nginx"; WinSvc = $Script:HTTP_WINSVC_NGINX }
        @{ Nombre = "Tomcat"; Interno = "tomcat"; WinSvc = $Script:HTTP_WINSVC_TOMCAT }
    )

    # Filtrar solo los instalados y activos
    $instalados = @()
    foreach ($svc in $servicios) {
        $winSvcObj = Get-Service -Name $svc.WinSvc -ErrorAction SilentlyContinue
        if ($null -ne $winSvcObj) {
            $puerto = if ($winSvcObj.Status -eq 'Running') {
                _http_obtener_puerto_activo $svc.WinSvc
            }
            else { 0 }
            $chocoInfo = if ($svc.Interno -ne "iis") {
                choco list --local $svc.Interno 2>$null |
                Where-Object { $_ -match "^$($svc.Interno)\s" } |
                ForEach-Object { ($_ -split '\s+')[1] }
            }
            else { "instalado" }
            $estado = $winSvcObj.Status
            $instalados += @{ Svc = $svc; Version = $chocoInfo; Puerto = $puerto; Estado = $estado }
        }
    }

    if ($instalados.Count -eq 0) {
        msg_error "No hay servicios HTTP instalados y activos"
        msg_info  "Use la opcion 2) del menu principal para instalar un servicio"
        return ""
    }

    msg_info "Servicios HTTP instalados:"
    for ($i = 0; $i -lt $instalados.Count; $i++) {
        $item = $instalados[$i]
        $verStr = if ($item.Version -and $item.Version -ne "instalado") { "v$($item.Version)" } elseif ($item.Version -eq "instalado") { "(instalado)" } else { "" }
        $estadoStr = if ($item.Estado -eq 'Running') { "${GREEN}activo${NC}" } else { "${YELLOW}$($item.Estado)${NC}" }
        Write-Host ("  ${BLUE}{0})${NC} {1,-20} {2,-15} {3}" -f ($i + 1), $item.Svc.Nombre, $verStr, $estadoStr)
    }
    Write-Host ""

    $opcion = ""
    do {
        msg_input "Seleccione el servicio [1-$($instalados.Count)]"
        $opcion = Read-Host
    } while (-not (http_validar_opcion_menu $opcion $instalados.Count))

    return $instalados[[int]$opcion - 1].Svc.Interno
}

#
# _http_obtener_version_local  (interna)
#
# Devuelve la versión instalada de un servicio de forma fiable.
# choco list --local-only falla con Apache porque lo registra como "Apache"
# (mayúscula) y no como "apache-httpd". Como fallback lee el exe directamente.
#
function _http_obtener_version_local {
    param([string]$Servicio)

    if ($Servicio -eq "iis") {
        $v = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
              -ErrorAction SilentlyContinue).VersionString
        if ($v) { return $v } else { return "instalado" }
    }

    $ver = $null

    switch ($Servicio) {

        "nginx" {
            # Fuente 1: nombre del directorio — nginx-1.17.2 -> "1.17.2"
            # HTTP_CONF_NGINX ya tiene la ruta real detectada al arrancar
            $confNginx = $Script:HTTP_CONF_NGINX
            if ($confNginx -and (Test-Path -LiteralPath $confNginx)) {
                $nginxDir = Split-Path (Split-Path $confNginx)
                if ((Split-Path $nginxDir -Leaf) -imatch "nginx[\-_]([\d\.]+)") {
                    $ver = $Matches[1]
                }
            }
            # Fuente 2: directorios nginx-X.Y.Z en C:\tools
            if (-not $ver -and (Test-Path "C:\tools")) {
                $d = Get-ChildItem "C:\tools" -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -imatch "^nginx[\-_][\d]" } |
                    Sort-Object Name -Descending | Select-Object -First 1
                if ($d -and $d.Name -imatch "nginx[\-_]([\d\.]+)") { $ver = $Matches[1] }
            }
            # Fuente 3: ProgramData\chocolatey\lib\nginx\tools
            if (-not $ver) {
                $cnt = "$env:ProgramData\chocolatey\lib\nginx\tools"
                if (Test-Path $cnt) {
                    $d = Get-ChildItem $cnt -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -imatch "^nginx[\-_][\d]" } |
                        Sort-Object Name -Descending | Select-Object -First 1
                    if ($d -and $d.Name -imatch "nginx[\-_]([\d\.]+)") { $ver = $Matches[1] }
                }
            }
        }

        "tomcat" {
            # Fuente 1: directorio apache-tomcat-X.Y.Z en chocolatey\lib\tomcat\tools
            $ctTools = "$env:ProgramData\chocolatey\lib\tomcat\tools"
            if (Test-Path $ctTools) {
                $d = Get-ChildItem $ctTools -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -imatch "^apache-tomcat" } |
                    Sort-Object Name -Descending | Select-Object -First 1
                if ($d -and $d.Name -imatch "apache-tomcat-([\d\.]+)") { $ver = $Matches[1] }
            }
            # Fuente 2: MANIFEST.MF de catalina.jar (Implementation-Version)
            if (-not $ver) {
                $catFound = Get-ChildItem "$env:ProgramData\chocolatey\lib\tomcat" `
                    -Filter catalina.jar -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 1 | ForEach-Object { $_.FullName }
                if (-not $catFound) {
                    foreach ($p in @("C:\ProgramData\Tomcat9\lib\catalina.jar","C:\ProgramData\Tomcat10\lib\catalina.jar")) {
                        if (Test-Path -LiteralPath $p) { $catFound = $p; break }
                    }
                }
                if ($catFound) {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                    try {
                        $zip   = [System.IO.Compression.ZipFile]::OpenRead($catFound)
                        $entry = $zip.Entries | Where-Object { $_.FullName -match "MANIFEST.MF" } | Select-Object -First 1
                        if ($entry) {
                            $reader = New-Object System.IO.StreamReader($entry.Open())
                            $mf = $reader.ReadToEnd(); $reader.Close()
                            if ($mf -match "Implementation-Version:\s*([\d\.]+)") { $ver = $Matches[1] }
                        }
                        $zip.Dispose()
                    } catch { }
                }
            }
            # Fuente 3: FileVersion del exe (algunas versiones si lo populan)
            if (-not $ver) {
                foreach ($exe in @("C:\ProgramData\Tomcat9\bin\tomcat9.exe","C:\ProgramData\Tomcat10\bin\tomcat10.exe")) {
                    if (Test-Path -LiteralPath $exe) {
                        $fv = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
                        if ($fv -and $fv.Trim()) { $ver = $fv.Trim(); break }
                    }
                }
            }
        }

        "apache" {
            foreach ($exe in @(
                "$env:USERPROFILE\AppData\Roaming\Apache24\bin\httpd.exe",
                "$env:USERPROFILE\AppData\Roaming\Apache2.4\bin\httpd.exe",
                "C:\Apache24\bin\httpd.exe",
                "C:\tools\httpd\bin\httpd.exe"
            )) {
                if (Test-Path -LiteralPath $exe) {
                    $fv = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
                    if ($fv -and $fv.Trim()) { $ver = $fv.Trim(); break }
                }
            }
        }
    }

    # Fallback final: choco list (usando ruta absoluta por si no esta en PATH)
    if (-not $ver) {
        $chocoExe = if (Get-Command choco -ErrorAction SilentlyContinue) { "choco" }
                    else { "$env:ProgramData\chocolatey\bin\choco.exe" }
        $paquete = http_nombre_paquete $Servicio
        $ver = & $chocoExe list --local-only $paquete 2>$null |
            Where-Object { $_ -imatch "^$([regex]::Escape($paquete))\s" } |
            ForEach-Object { ($_ -split "\s+")[1].Trim() } |
            Select-Object -First 1
        if (-not $ver) {
            $ver = & $chocoExe list --local-only 2>$null |
                Where-Object { $_ -imatch "^$([regex]::Escape($Servicio))\s" } |
                ForEach-Object { ($_ -split "\s+")[1].Trim() } |
                Select-Object -First 1
        }
    }

    if ($ver) { return $ver } else { return "instalado" }
}

#
# http_seleccionar_servicio
#
# Menú de los cuatro servicios disponibles.
# Equivalente a http_seleccionar_servicio de FunctionsHTTP-B.sh
# Devuelve: nombre interno del servicio, "reinstalar:<svc>", "cancelar", etc.
#
function http_seleccionar_servicio {
    Clear-Host
    http_draw_servicio_header "Selector de Servicio" "Paso 1 de 4"

    msg_info "Servicios HTTP disponibles en Windows Server 2022:"
    Write-Host ""
    Write-Host "  ${BLUE}1)${NC} IIS (Internet Information Services)"
    Write-Host "      Servidor web nativo de Windows. Administrado con WebAdministration."
    Write-Host "      Instalacion via DISM  |  Usuario: IUSR  |  Puerto default: 80"
    Write-Host ""
    Write-Host "  ${BLUE}2)${NC} Apache HTTP Server (httpd)"
    Write-Host "      Servidor web clasico. Instalado via Chocolatey."
    Write-Host "      Paquete choco: apache-httpd  |  Usuario: apacheuser  |  Puerto default: 80"
    Write-Host ""
    Write-Host "  ${BLUE}3)${NC} Nginx"
    Write-Host "      Servidor web / proxy inverso. Instalado via Chocolatey."
    Write-Host "      Paquete choco: nginx  |  Usuario: nginxuser  |  Puerto default: 80"
    Write-Host ""
    Write-Host "  ${BLUE}4)${NC} Tomcat"
    Write-Host "      Servidor de aplicaciones Java. Requiere JDK instalado."
    Write-Host "      Paquete choco: tomcat  |  Puerto default: 8080"
    Write-Host ""

    $opcion = ""
    do {
        msg_input "Seleccione el servicio [1-4]"
        $opcion = Read-Host
        if (-not (http_validar_opcion_menu $opcion 4)) {
            Write-Host ""
            $opcion = ""
        }
    } while ([string]::IsNullOrEmpty($opcion))

    $nombreServicio = switch ($opcion) {
        "1" { "iis" }
        "2" { "apache" }
        "3" { "nginx" }
        "4" { "tomcat" }
    }

    # Edge case: ya instalado — ofrecer reinstalar o reconfigurar
    $winsvc = http_nombre_winsvc $nombreServicio
    if (check_service_active $winsvc) {
        $chocoVer = _http_obtener_version_local $nombreServicio

        Write-Host ""
        msg_alert "El servicio '$nombreServicio' ya esta instalado (v${chocoVer})"
        Write-Host ""
        Write-Host "  Opciones:"
        Write-Host "    1) Reinstalar (desinstala primero y vuelve a instalar)"
        Write-Host "    2) Solo reconfigurar (omite instalacion)"
        Write-Host "    3) Cancelar"
        Write-Host ""

        msg_input "Seleccione [1-3]"
        $opReinstalar = Read-Host
        switch ($opReinstalar) {
            "1" { return "reinstalar:$nombreServicio" }
            "2" { return "reconfigurar:$nombreServicio" }
            default { return "cancelar" }
        }
    }

    return $nombreServicio
}

#
# http_consultar_versiones
#
# Consulta versiones disponibles del servicio vía Chocolatey.
# Equivalente a http_consultar_versiones de FunctionsHTTP-B.sh
#
# Uso: $versiones = http_consultar_versiones "nginx"
# Devuelve array de versiones disponibles
#
function http_consultar_versiones {
    param([string]$Servicio)

    $paquete = http_nombre_paquete $Servicio

    if ($Servicio -eq "iis") {
        # IIS no tiene versiones seleccionables via choco — usa la del sistema
        $iisVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
                  -ErrorAction SilentlyContinue).VersionString
        return @("sistema ($iisVer)")
    }

    msg_info "Consultando versiones disponibles de $paquete en Chocolatey..."
    Write-Host ""

    # ── Estrategia 1: choco search --exact --all-versions ─────────────────
    # --exact  : solo el paquete con ese nombre, sin coincidencias parciales
    # --all-versions : lista TODAS las versiones del repo, no solo la latest
    # 2>$null  : suprimir warnings de choco (ej: certificados, deprecaciones)
    $salidaRaw = choco search $paquete --exact --all-versions 2>$null

    # Fallback: choco list (Chocolatey < 2.0 usaba list en lugar de search)
    if (-not $salidaRaw -or $salidaRaw.Count -eq 0) {
        $salidaRaw = choco list $paquete --exact --all-versions 2>$null
    }

    # Extraer solo líneas que empiecen con el nombre del paquete seguido de
    # un espacio y un dígito (descarta headers, footers y paquetes parciales)
    $paqueteEsc = [regex]::Escape($paquete)
    $versiones = $salidaRaw |
        Where-Object { $_ -imatch "^${paqueteEsc}\s+\d" } |
        ForEach-Object { ($_ -split '\s+')[1].Trim() } |
        Where-Object { $_ -match '^\d' }

    # ── Ordenar de forma robusta ───────────────────────────────────────────
    # [version] solo acepta hasta 4 segmentos numéricos. Si el string tiene
    # un sufijo no numérico (ej: "1.28.0.1-chocolatey") el cast falla y la
    # pipeline devuelve vacío. Usamos un helper que nunca lanza excepciones.
    $versiones = $versiones | Sort-Object -Descending {
        # Tomar solo la parte numérica antes de cualquier guion o letra
        $parteNum = ($_ -split '[^0-9.]')[0].TrimEnd('.')
        $segmentos = $parteNum -split '\.' | ForEach-Object {
            $n = 0
            if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 }
        }
        # Construir valor de comparación: rellenar hasta 4 segmentos con 0
        while ($segmentos.Count -lt 4) { $segmentos = @($segmentos) + @(0) }
        # Número de 16 dígitos que preserva el orden semántico
        '{0:D5}{1:D5}{2:D5}{3:D5}' -f $segmentos[0], $segmentos[1], $segmentos[2], $segmentos[3]
    }

    if (-not $versiones -or @($versiones).Count -eq 0) {
        msg_alert "No se encontraron versiones en el repositorio — usando 'latest'"
        msg_info   "Verifique: choco search $paquete --exact --all-versions"
        return @("latest")
    }

    # ── Incluir versión instalada localmente si no está en la lista ────────
    # Garantiza que el usuario siempre pueda ver qué tiene instalado aunque
    # esa versión ya no esté en el repositorio activo.
    $verInstalada = choco list --local-only $paquete 2>$null |
        Where-Object { $_ -imatch "^${paqueteEsc}\s" } |
        ForEach-Object { ($_ -split '\s+')[1].Trim() } |
        Select-Object -First 1

    $versionesArr = @($versiones)
    if ($verInstalada -and $versionesArr -notcontains $verInstalada) {
        $versionesArr = @($verInstalada) + $versionesArr
    }

    msg_success "Se encontraron $($versionesArr.Count) version(es) disponible(s)"
    return $versionesArr
}

#
# http_seleccionar_version
#
# Presenta el listado de versiones y captura la elección del usuario.
# Equivalente a http_seleccionar_version de FunctionsHTTP-B.sh
#
# Uso: $version = http_seleccionar_version "nginx" $versiones
#
function http_seleccionar_version {
    param([string]$Servicio, [string[]]$Versiones)

    http_draw_servicio_header $Servicio "Paso 2 de 4 — Seleccion de version"

    $total = $Versiones.Count

    msg_info "Versiones disponibles para ${Servicio} (orden: mas reciente primero):"
    Write-Host ""
    Write-Host ("  {0,-5}  {1,-28}  {2}" -f "NUM", "VERSION", "ETIQUETA")
    Write-Separator

    for ($i = 0; $i -lt $total; $i++) {
        # Etiquetas equivalentes a http_seleccionar_version de FunctionsHTTP-B.sh
        $etiqueta = if ($total -eq 1) {
            "${GREEN}Latest${NC} / ${BLUE}Stable${NC}"
        } elseif ($i -eq 0) {
            "${GREEN}Latest${NC}   — mas reciente, desarrollo activo"
        } elseif ($i -eq 1 -and $total -ge 3) {
            "${CYAN}Reciente${NC}  — un ciclo anterior, probada"
        } elseif ($i -eq $total - 1) {
            "${BLUE}Stable${NC}   — mayor tiempo en produccion"
        } else {
            "${GRAY}Anterior${NC}  — $i version(es) atras"
        }
        Write-Host -NoNewline ("  {0,-5}  {1,-28}  " -f "$($i+1))", $Versiones[$i])
        Write-Host $etiqueta
    }
    Write-Host ""
    msg_info "Latest  = version mas reciente disponible en repositorios"
    msg_info "Reciente= un ciclo de release atras, ampliamente probada"
    msg_info "Stable  = version mas antigua disponible, maxima estabilidad"
    Write-Host ""

    $idx = ""
    do {
        msg_input "Seleccione version [1-${total}] (Enter = 1 Latest)"
        $idx = Read-Host
        if ([string]::IsNullOrWhiteSpace($idx)) { $idx = "1" }
    } while (-not (http_validar_indice_version $idx $total))

    $versionElegida = $Versiones[[int]$idx - 1]
    msg_success "Version seleccionada: $versionElegida"
    return $versionElegida
}

#
# http_seleccionar_puerto
#
# Captura y valida el puerto de escucha del servicio.
# Equivalente a http_seleccionar_puerto de FunctionsHTTP-B.sh
#
function http_seleccionar_puerto {
    param([string]$Servicio, [string]$PasoLabel = "Paso 3 de 4 — Puerto de escucha")

    http_draw_servicio_header $Servicio $PasoLabel

    $puertoDefault = switch ($Servicio) {
        "iis" { $Script:HTTP_PUERTO_DEFAULT_IIS }
        "apache" { $Script:HTTP_PUERTO_DEFAULT_APACHE }
        "nginx" { $Script:HTTP_PUERTO_DEFAULT_NGINX }
        "tomcat" { $Script:HTTP_PUERTO_DEFAULT_TOMCAT }
        default { 8080 }
    }

    msg_info "Puerto default para ${Servicio}: ${puertoDefault}/tcp"
    msg_info "Se recomienda usar un puerto >= 1024 fuera del rango reservado"
    Write-Host ""

    $puerto = 0
    do {
        msg_input "Puerto de escucha [Enter = $puertoDefault]"
        $entrada = Read-Host
        if ([string]::IsNullOrWhiteSpace($entrada)) { $entrada = "$puertoDefault" }
        if (http_validar_puerto $entrada) {
            $puerto = [int]$entrada
        }
        Write-Host ""
    } while ($puerto -eq 0)

    msg_success "Puerto seleccionado: ${puerto}/tcp"
    return $puerto
}

#
# http_crear_usuario_dedicado
#
# Crea un usuario local de Windows sin capacidad de login interactivo.
# Equivalente a http_crear_usuario_dedicado de FunctionsHTTP-B.sh
#
# En Windows: usuario local con PasswordNeverExpires, sin LoginScript,
# y sin permisos de "Log on locally" vía politica local (secedit).
#
function http_crear_usuario_dedicado {
    param([string]$Usuario, [string]$Webroot)

    msg_info "Configurando usuario dedicado: $Usuario"
    Write-Host ""

    # IIS usa IUSR — cuenta gestionada por Windows
    if ($Usuario -eq "IUSR") {
        msg_info  "IIS usa la cuenta integrada IUSR — no requiere creacion manual"
        msg_success "Cuenta IUSR disponible automaticamente"
        return $true
    }

    # Verificar si ya existe
    $existe = Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue
    if ($null -ne $existe) {
        msg_info "El usuario '$Usuario' ya existe"
    }
    else {
        # Crear usuario local sin contraseña interactiva
        # Crear usuario con contrasena compleja aleatoria (cumple politica de complejidad)
        # Luego se deshabilita la cuenta para que no pueda hacer login interactivo.
        # -NoPassword no esta disponible en todas las builds de PS 5.1.
        $chars = 'abcdefghijklmnopqrstuvwxyz'
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $bytes = [byte[]]::new(16)
        $rng.GetBytes($bytes)
        # Contrasena: 4 segmentos aseguran mayuscula + minuscula + digito + simbolo
        $passStr = 'Svc!' + [Convert]::ToBase64String($bytes).Substring(0, 12) + '9'
        $pass = ConvertTo-SecureString $passStr -AsPlainText -Force
        try {
            New-LocalUser -Name $Usuario `
                -Password $pass `
                -PasswordNeverExpires `
                -UserMayNotChangePassword `
                -Description "Usuario dedicado para servicio HTTP $Usuario" `
                -ErrorAction Stop | Out-Null
            # Deshabilitar la cuenta: no puede hacer login aunque tenga contrasena
            Disable-LocalUser -Name $Usuario -ErrorAction SilentlyContinue
            msg_success "Usuario '$Usuario' creado y deshabilitado (equivale a nologin)"
        }
        catch {
            msg_error "Error al crear usuario: $($_.Exception.Message)"
            return $false
        }
    }

    # Denegar login interactivo vía política local
    # Equivalente a /sbin/nologin en Linux
    # Usamos secedit para denegar "Log on locally" a este usuario
    msg_info "Restringiendo acceso interactivo para '$Usuario'..."
    $infContent = @"
[Unicode]
Unicode=yes
[Privilege Rights]
SeDenyInteractiveLogonRight = *$Usuario
SeDenyRemoteInteractiveLogonRight = *$Usuario
SeDenyNetworkLogonRight = *$Usuario
[Version]
signature="`$CHICAGO`$"
Revision=1
"@
    $infPath = "$env:TEMP\restrict_$Usuario.inf"
    $infContent | Out-File -FilePath $infPath -Encoding Unicode
    secedit /configure /db secedit.sdb /cfg $infPath /quiet 2>$null
    Remove-Item $infPath -ErrorAction SilentlyContinue
    msg_success "Login interactivo denegado para '$Usuario' (equivale a /sbin/nologin)"

    # Asignar permisos sobre el webroot
    if ([string]::IsNullOrWhiteSpace($Webroot)) { return $true }

    if (-not (Test-Path $Webroot -PathType Container)) {
        New-Item -ItemType Directory -Path $Webroot -Force | Out-Null
        msg_success "Webroot creado: $Webroot"
    }

    # Dar permisos de lectura/ejecución sobre el webroot
    $acl = Get-Acl $Webroot
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Usuario, "ReadAndExecute,ListDirectory",
        "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Webroot -AclObject $acl -ErrorAction SilentlyContinue
    msg_success "Permisos ReadAndExecute asignados a '$Usuario' en $Webroot"
    return $true
}

#
# http_crear_index
#
# Genera el index.html personalizado con información del despliegue.
# Equivalente a http_crear_index de FunctionsHTTP-B.sh
#
function http_crear_index {
    param([string]$Servicio, [string]$Version, [int]$Puerto, [int]$PuertoHttps = 0)

    $webroot = http_get_webroot $Servicio
    $usuario = http_get_usuario_servicio $Servicio
    $fecha   = Get-Date -Format "yyyy-MM-dd HH:mm"

    $nombreDisplay = switch ($Servicio) {
        "iis"    { "IIS (Internet Information Services)" }
        "apache" { "Apache HTTP Server" }
        "nginx"  { "Nginx" }
        "tomcat" { "Apache Tomcat" }
        default  { $Servicio }
    }

    # Filas de puerto — una o dos según si SSL está activo
    $filasPuerto = if ($PuertoHttps -gt 0) {
        "        <tr><td>Puerto HTTP</td>  <td>${Puerto}/tcp &rarr; redirect HTTPS</td></tr>`n" +
        "        <tr><td>Puerto HTTPS</td> <td style=`"color:#2a7;font-weight:bold`">${PuertoHttps}/tcp (SSL activo)</td></tr>"
    } else {
        "        <tr><td>Puerto</td> <td>${Puerto}/tcp</td></tr>"
    }

    msg_info "Generando index.html en $webroot..."

    if (-not (Test-Path $webroot -PathType Container)) {
        New-Item -ItemType Directory -Path $webroot -Force | Out-Null
    }

$html = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>$nombreDisplay</title>
</head>
<body>
    <h1>$nombreDisplay</h1>
    <table>
        <tr><td>Version</td> <td>$Version</td></tr>
        $filasPuerto
        <tr><td>Webroot</td> <td>$webroot</td></tr>
        <tr><td>Usuario</td> <td>$usuario</td></tr>
        <tr><td>Fecha</td>   <td>$fecha</td></tr>
    </table>
</body>
</html>
"@

    $html | Out-File -FilePath "$webroot\index.html" -Encoding UTF8 -Force
    msg_success "index.html generado en $webroot"
}

#
# _http_configurar_firewall_inicial  (interna)
#
# Abre el puerto del servicio en Windows Firewall y cierra el default
# si se eligió un puerto distinto.
# Equivalente a _http_configurar_firewall_inicial de FunctionsHTTP-B.sh
#
function _http_configurar_firewall_inicial {
    param([string]$Servicio, [int]$Puerto)

    msg_info "Configurando Windows Firewall para puerto ${Puerto}/tcp..."
    Write-Host ""

    $nombreRegla = "HTTP_${Servicio}_${Puerto}"

    # Verificar si la regla ya existe
    $reglaExistente = Get-NetFirewallRule -DisplayName $nombreRegla `
        -ErrorAction SilentlyContinue
    if ($null -eq $reglaExistente) {
        New-NetFirewallRule -DisplayName $nombreRegla `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $Puerto `
            -Action Allow `
            -ErrorAction Stop | Out-Null
        msg_success "Regla '$nombreRegla' creada — puerto ${Puerto}/tcp abierto"
    }
    else {
        msg_info "Regla para puerto ${Puerto}/tcp ya existia"
    }

    # Cerrar el puerto default si se usó uno distinto
    $puertoDefault = switch ($Servicio) {
        "iis" { $Script:HTTP_PUERTO_DEFAULT_IIS }
        "apache" { $Script:HTTP_PUERTO_DEFAULT_APACHE }
        "nginx" { $Script:HTTP_PUERTO_DEFAULT_NGINX }
        "tomcat" { $Script:HTTP_PUERTO_DEFAULT_TOMCAT }
    }

    if ($Puerto -ne $puertoDefault) {
        $reglaDefault = Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq 'True' } |
        ForEach-Object {
            $pf = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            if ($pf -and $pf.LocalPort -eq "$puertoDefault") { $_ }
        } | Select-Object -First 1

        if ($reglaDefault) {
            Remove-NetFirewallRule -Name $reglaDefault.Name -ErrorAction SilentlyContinue
            msg_success "Regla del puerto default ${puertoDefault}/tcp eliminada"
        }
    }

    return $true
}

#
# http_instalar_iis
#
# Instala IIS via DISM/WindowsFeature con los módulos necesarios.
# Configura el puerto de escucha via WebAdministration.
#
function http_instalar_iis {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "IIS" "Paso 4 de 4 — Instalacion"

    # Paso 1: Instalar feature de Windows
    draw_line
    msg_info "PASO 1/5 — Instalacion de IIS via DISM"
    draw_line
    Import-Module ServerManager -ErrorAction SilentlyContinue
    $features = @("Web-Server", "Web-Common-Http", "Web-Static-Content",
        "Web-Default-Doc", "Web-Http-Logging", "Web-Security",
        "Web-Filtering", "Web-Performance", "Web-Stat-Compression",
        "Web-Mgmt-Tools", "Web-Scripting-Tools")

    foreach ($feat in $features) {
        $result = Install-WindowsFeature -Name $feat -ErrorAction SilentlyContinue >$null 2>&1
        if ($result.Success) {
            Write-Host "  ${GREEN}[OK]${NC}  Feature instalada: $feat"
        }
    }

    # Paso 2: Usuario dedicado
    Write-Host ""
    draw_line
    msg_info "PASO 2/5 — Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado $Script:HTTP_USUARIO_IIS $Script:HTTP_DIR_IIS

    # Paso 3: Cargar módulo WebAdministration
    Write-Host ""
    draw_line
    msg_info "PASO 3/5 — Configuracion del sitio web"
    draw_line
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    # Configurar el binding HTTP al puerto seleccionado.
    # Solo se elimina el binding HTTP anterior — el HTTPS se preserva
    # para no afectar el sitio FTP ni un SSL ya configurado.
    $site = Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
    if ($site) {
        Get-WebBinding -Name "Default Web Site" -Protocol "http" `
            -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
        New-WebBinding -Name "Default Web Site" -Protocol http -Port $Puerto | Out-Null
        msg_success "Binding HTTP configurado: puerto $Puerto"
        # Informar si hay binding HTTPS activo que se preservó
        $httpsB = Get-WebBinding -Name "Default Web Site" -Protocol "https" `
                  -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($httpsB) {
            $hp = ($httpsB.bindingInformation -split ':')[1]
            msg_info "Binding HTTPS existente preservado en puerto ${hp}/tcp"
        }
    }

    # Paso 4: Puerto (ya configurado en el binding)
    Write-Host ""
    draw_line
    msg_info "PASO 4/5 — Puerto $Puerto configurado"
    draw_line
    msg_info "Binding HTTP en puerto $Puerto ya establecido"

    # Paso 5: Iniciar servicio + firewall + index
    Write-Host ""
    draw_line
    msg_info "PASO 5/5 — Activacion del servicio"
    draw_line
    Set-Service -Name $Script:HTTP_WINSVC_IIS -StartupType Automatic
    Start-Service -Name $Script:HTTP_WINSVC_IIS -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (check_service_active $Script:HTTP_WINSVC_IIS) {
        msg_success "IIS iniciado y activo"
    }
    else {
        msg_error "IIS no levanto — revise el Visor de Eventos"
        return $false
    }

    _http_configurar_firewall_inicial "iis" $Puerto
    Write-Host ""
    http_crear_index "iis" "sistema" $Puerto

    Write-Host ""
    $iisVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
            -ErrorAction SilentlyContinue).VersionString
    http_draw_resumen "IIS" "$Puerto" "$iisVer"
    return $true
}

#
# http_instalar_apache
#
# Instala Apache HTTP Server para Windows vía Chocolatey.
#
function http_instalar_apache {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "Apache (httpd)" "Paso 4 de 4 — Instalacion"

    # ── Paso 1: Instalar via Chocolatey ──────────────────────────────────────
    # El chocolateyInstall.ps1 del paquete intenta configurar Apache en el
    # puerto 8080 hardcodeado. Si ese puerto está ocupado el script post-install
    # falla, pero los binarios SÍ se descargan.
    # Usamos --ignore-package-exit-codes para que choco no marque el paquete
    # como fallido y verificamos por presencia de httpd.exe en disco.
    draw_line
    msg_info "PASO 1/5 — Instalacion via Chocolatey"
    draw_line

    # Habilitar allowGlobalConfirmation temporalmente
    $globalConfWasEnabled = (choco feature list 2>$null) -match "allowGlobalConfirmation.*Enabled"
    if (-not $globalConfWasEnabled) {
        & choco feature enable -n allowGlobalConfirmation 2>$null | Out-Null
        msg_info "allowGlobalConfirmation habilitado temporalmente"
    }

    msg_process "Ejecutando choco install apache-httpd (puede tardar varios minutos)..."
    Write-Host ""

    if ($Version -eq "latest") {
        & choco install apache-httpd -y --no-progress --ignore-package-exit-codes
    } else {
        & choco install apache-httpd "--version=$Version" -y --no-progress --ignore-package-exit-codes
    }
    $chocoExitCode = $LASTEXITCODE

    Write-Host ""
    msg_info "choco exit code: $chocoExitCode (se ignora — verificamos por httpd.exe)"

    # Restaurar allowGlobalConfirmation
    if (-not $globalConfWasEnabled) {
        & choco feature disable -n allowGlobalConfirmation 2>$null | Out-Null
    }

    # Buscar httpd.exe — choco puede instalarlo en varias rutas
    $httpdExeVerif = $null
    msg_process "Buscando httpd.exe..."
    $candidatosExe = @(
        "$env:ProgramData\chocolatey\lib\apache-httpd\tools\Apache24\bin\httpd.exe",
        "$env:APPDATA\Apache24\bin\httpd.exe",
        "$env:APPDATA\Apache2.4\bin\httpd.exe",
        "$env:USERPROFILE\AppData\Roaming\Apache24\bin\httpd.exe",
        "$env:USERPROFILE\AppData\Roaming\Apache2.4\bin\httpd.exe",
        "C:\Apache24\bin\httpd.exe",
        "C:\Apache2.4\bin\httpd.exe",
        "C:\tools\httpd\bin\httpd.exe",
        "C:\tools\Apache24\bin\httpd.exe"
    )
    foreach ($c in $candidatosExe) {
        if (Test-Path $c) { $httpdExeVerif = $c; break }
    }

    # Búsqueda recursiva en chocolatey lib
    if (-not $httpdExeVerif) {
        msg_process "Busqueda recursiva en chocolatey lib..."
        $chocoLib = "$env:ProgramData\chocolatey\lib\apache-httpd"
        if (Test-Path $chocoLib) {
            $found = Get-ChildItem $chocoLib -Recurse -Filter httpd.exe `
                     -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $httpdExeVerif = $found.FullName }
        }
    }

    # Búsqueda recursiva en AppData
    if (-not $httpdExeVerif) {
        msg_process "Busqueda recursiva en AppData..."
        $found = Get-ChildItem $env:APPDATA -Recurse -Filter httpd.exe `
                 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $httpdExeVerif = $found.FullName }
    }

    # Búsqueda recursiva en USERPROFILE
    if (-not $httpdExeVerif) {
        msg_process "Busqueda recursiva en USERPROFILE..."
        $found = Get-ChildItem $env:USERPROFILE -Recurse -Filter httpd.exe `
                 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $httpdExeVerif = $found.FullName }
    }

    if (-not $httpdExeVerif) {
        msg_error "httpd.exe no encontrado en disco tras la instalacion"
        msg_info  "  APPDATA     = $env:APPDATA"
        msg_info  "  USERPROFILE = $env:USERPROFILE"
        msg_info  "  ProgramData = $env:ProgramData"
        msg_info  "Verifique: Get-ChildItem C:\ -Recurse -Filter httpd.exe -ErrorAction SilentlyContinue"
        return $false
    }
    msg_success "apache-httpd instalado — httpd.exe en: $httpdExeVerif"

    # ── Paso 2: Localizar httpd.conf y configurar puerto ─────────────────────
    Write-Host ""
    draw_line
    msg_info "PASO 2/5 — Localizar httpd.conf y configurar puerto"
    draw_line

    $apacheRoot    = Split-Path (Split-Path $httpdExeVerif)
    $candidatos    = @(
        (Join-Path $apacheRoot "conf\httpd.conf"),
        "$env:APPDATA\Apache24\conf\httpd.conf",
        "$env:APPDATA\Apache2.4\conf\httpd.conf",
        "C:\Apache24\conf\httpd.conf",
        "C:\tools\httpd\conf\httpd.conf",
        $Script:HTTP_CONF_APACHE
    )
    $httpdConfReal = $null
    foreach ($c in $candidatos) {
        if (Test-Path $c) { $httpdConfReal = Get-Item $c; break }
    }
    if (-not $httpdConfReal) {
        $httpdConfReal = Get-ChildItem $env:APPDATA -Recurse -Filter httpd.conf `
                         -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($httpdConfReal) {
        $Script:HTTP_CONF_APACHE = $httpdConfReal.FullName
        $apacheRootReal = Split-Path (Split-Path $httpdConfReal.FullName)
        $htdocs = Join-Path $apacheRootReal "htdocs"
        if (Test-Path $htdocs) { $Script:HTTP_DIR_APACHE = $htdocs }
        msg_info "httpd.conf: $($httpdConfReal.FullName)"
        http_crear_backup $Script:HTTP_CONF_APACHE

        $srvrootCorrecta = $apacheRootReal -replace '\\', '/'
        $bytes = [System.IO.File]::ReadAllBytes($Script:HTTP_CONF_APACHE)
        $bom   = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $contenido = if ($bom) {
            [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        } else { [System.Text.Encoding]::UTF8.GetString($bytes) }

        $contenido = $contenido -replace 'Define SRVROOT ".*"',   "Define SRVROOT `"$srvrootCorrecta`""
        $contenido = $contenido -replace 'Listen\s+\d+',          "Listen $Puerto"
        $contenido = $contenido -replace 'ServerName\s+\S+:\d+',  "ServerName localhost:$Puerto"

        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Script:HTTP_CONF_APACHE, $contenido, $utf8NoBom)
        msg_success "Puerto $Puerto y SRVROOT configurados en httpd.conf"

        $syntaxOut = & $httpdExeVerif -t 2>&1
        if ($syntaxOut -match "Syntax OK") { msg_success "Sintaxis: OK" }
        else {
            msg_alert "Advertencias de sintaxis:"
            $syntaxOut | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" }
        }
    } else {
        msg_alert "httpd.conf no encontrado — el servicio puede no iniciar correctamente"
    }

    # ── Paso 3: Usuario dedicado ──────────────────────────────────────────────
    Write-Host ""
    draw_line
    msg_info "PASO 3/5 — Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado $Script:HTTP_USUARIO_APACHE $Script:HTTP_DIR_APACHE

    # ── Paso 4: Registrar servicio de Windows ─────────────────────────────────
    Write-Host ""
    draw_line
    msg_info "PASO 4/5 — Registro como servicio de Windows"
    draw_line

    $svcApache = Get-Service -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match '^Apache|^httpd' } |
                 Select-Object -First 1
    if ($svcApache) {
        $Script:HTTP_WINSVC_APACHE = $svcApache.Name
        msg_info "Servicio detectado: $($svcApache.Name)"
    } else {
        & $httpdExeVerif -k install -n "Apache2.4" 2>$null
        $Script:HTTP_WINSVC_APACHE = "Apache2.4"
        msg_success "Servicio Apache2.4 registrado"
    }

    # ── Paso 5: Iniciar servicio ──────────────────────────────────────────────
    Write-Host ""
    draw_line
    msg_info "PASO 5/5 — Activacion del servicio"
    draw_line

    Set-Service -Name $Script:HTTP_WINSVC_APACHE -StartupType Automatic `
        -ErrorAction SilentlyContinue
    Stop-Service  $Script:HTTP_WINSVC_APACHE -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service $Script:HTTP_WINSVC_APACHE -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (check_service_active $Script:HTTP_WINSVC_APACHE) {
        msg_success "Apache iniciado y activo"
    } else {
        msg_error "Apache no levanto — revise el Visor de Eventos"
        return $false
    }

    _http_configurar_firewall_inicial "apache" $Puerto
    Write-Host ""
    http_crear_index "apache" $Version $Puerto
    Write-Host ""
    http_draw_resumen "Apache HTTP Server" "$Puerto" "$Version"
    return $true
}

function http_instalar_nginx {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "Nginx" "Paso 4 de 4 — Instalacion"

    draw_line
    msg_info "PASO 1/5 — Instalacion via Chocolatey"
    draw_line

    if ($Version -eq "latest") {
        & choco install nginx -y >$null 2>&1
    }
    else {
        & choco install nginx "--version=$Version" -y >$null 2>&1
    }

    # Verificar por existencia de nginx.exe, no por exit code
    $nginxExeVerif = $null
    $candidatosNginxVerif = @(
        "C:\tools\nginx\nginx.exe",
        "C:\tools\nginx-1.29.5\nginx.exe",
        "C:\tools\nginx-1.28.0\nginx.exe",
        "$env:ChocolateyInstall\lib\nginx\tools\nginx.exe",
        "$env:ProgramData\chocolatey\lib\nginx\tools\nginx.exe"
    )
    foreach ($c in $candidatosNginxVerif) {
        if (Test-Path $c) { $nginxExeVerif = $c; break }
    }
    if (-not $nginxExeVerif) {
        $nginxItem = Get-ChildItem "C:\tools" -Recurse -Filter nginx.exe `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nginxItem) { $nginxExeVerif = $nginxItem.FullName }
    }
    if (-not $nginxExeVerif) {
        $chocoLibNginx2 = "$env:ProgramData\chocolatey\lib\nginx\tools"
        if (Test-Path $chocoLibNginx2) {
            $nginxItem = Get-ChildItem $chocoLibNginx2 -Recurse -Filter nginx.exe `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($nginxItem) { $nginxExeVerif = $nginxItem.FullName }
        }
    }
    if (-not $nginxExeVerif) {
        msg_error "Fallo choco install nginx — nginx.exe no encontrado en disco"
        return $false
    }
    msg_success "nginx instalado en: $nginxExeVerif"

    Write-Host ""
    draw_line
    msg_info "PASO 2/5 — Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado $Script:HTTP_USUARIO_NGINX $Script:HTTP_DIR_NGINX

    Write-Host ""
    draw_line
    msg_info "PASO 3/5 — Configuracion de puerto en nginx.conf"
    draw_line

    # Actualizar ruta de nginx.conf ahora que nginx ya esta instalado.
    # choco puede instalar en:
    #   C:\tools\nginx-X.Y.Z\         (choco < 2.0, versiones recientes)
    #   C:\ProgramData\chocolatey\lib\nginx\tools\nginx-X.Y.Z\  (choco >= 2.0)
    if (-not (Test-Path $Script:HTTP_CONF_NGINX)) {
        # Buscar en C:\tools primero (instalaciones tipicas)
        $nginxConfReal = Get-ChildItem "C:\tools" -Recurse -Filter nginx.conf `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        # Fallback: ProgramData/chocolatey (choco >= 2.0 o versiones antiguas)
        if (-not $nginxConfReal) {
            $chocoLib = "$env:ProgramData\chocolatey\lib\nginx\tools"
            if (Test-Path $chocoLib) {
                $nginxConfReal = Get-ChildItem $chocoLib -Recurse -Filter nginx.conf `
                    -ErrorAction SilentlyContinue | Select-Object -First 1
            }
        }
        if ($nginxConfReal) {
            $Script:HTTP_CONF_NGINX = $nginxConfReal.FullName
            $nginxHtmlReal = Join-Path (Split-Path (Split-Path $nginxConfReal.FullName)) "html"
            if (Test-Path $nginxHtmlReal) { $Script:HTTP_DIR_NGINX = $nginxHtmlReal }
            msg_info "nginx.conf localizado: $($nginxConfReal.FullName)"
        }
    }

    if (Test-Path $Script:HTTP_CONF_NGINX) {
        http_crear_backup $Script:HTTP_CONF_NGINX
        $bytes = [System.IO.File]::ReadAllBytes($Script:HTTP_CONF_NGINX)
        if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $contenidoNginx = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        }
        else {
            $contenidoNginx = [System.Text.Encoding]::UTF8.GetString($bytes)
        }
        $contenidoNginx = $contenidoNginx -replace 'listen\s+\d+;', "listen $Puerto;"
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Script:HTTP_CONF_NGINX, $contenidoNginx, $utf8NoBom)
        msg_success "Puerto $Puerto configurado en nginx.conf"
    }

    Write-Host ""
    draw_line
    msg_info "PASO 4/5 — Registro como servicio de Windows (NSSM)"
    draw_line

    # Buscar nginx.exe en rutas conocidas de choco
    $nginxExePath = $null
    $candidatosNginx = @(
        "C:\tools\nginx\nginx.exe",
        "C:\tools\nginx-1.29.5\nginx.exe",
        "C:\tools\nginx-1.28.0\nginx.exe",
        "$env:ChocolateyInstall\lib\nginx\tools\nginx.exe",
        "$env:ProgramData\chocolatey\lib\nginx\tools\nginx.exe"
    )
    foreach ($c in $candidatosNginx) {
        if (Test-Path $c) { $nginxExePath = $c; break }
    }
    # Fallback dinamico: buscar en C:\tools Y en ProgramData\chocolatey\lib\nginx
    if (-not $nginxExePath) {
        $nginxItem = Get-ChildItem "C:\tools" -Recurse -Filter nginx.exe `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nginxItem) { $nginxExePath = $nginxItem.FullName }
    }
    if (-not $nginxExePath) {
        $chocoLibNginx = "$env:ProgramData\chocolatey\lib\nginx\tools"
        if (Test-Path $chocoLibNginx) {
            $nginxItem = Get-ChildItem $chocoLibNginx -Recurse -Filter nginx.exe `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($nginxItem) { $nginxExePath = $nginxItem.FullName }
        }
    }

    if (-not $nginxExePath) {
        msg_error "nginx.exe no encontrado tras la instalacion"
        return $false
    }

    msg_info "nginx.exe localizado: $nginxExePath"

    # Instalar NSSM si no está disponible — es obligatorio para registrar nginx como servicio
    $nssm = Get-Command nssm -ErrorAction SilentlyContinue
    if (-not $nssm) {
        msg_info "NSSM no encontrado — instalando via Chocolatey..."
        & choco install nssm -y
        if ($LASTEXITCODE -ne 0) {
            msg_error "No se pudo instalar NSSM — nginx no quedara como servicio de Windows"
            return $false
        }
    }

    # Verificar si el servicio ya existe antes de registrarlo
    $svcNginxExiste = Get-Service -Name "nginx" -ErrorAction SilentlyContinue
    if ($null -eq $svcNginxExiste) {
        Stop-Process -Name nginx -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        & nssm install nginx "$nginxExePath"
        & nssm set nginx AppDirectory (Split-Path $nginxExePath)
        msg_success "Servicio nginx registrado via NSSM"
    }
    else {
        msg_info "Servicio nginx ya registrado"
    }

    Write-Host ""
    draw_line
    msg_info "PASO 5/5 — Activacion del servicio"
    draw_line
    Stop-Service -Name $Script:HTTP_WINSVC_NGINX -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service -Name $Script:HTTP_WINSVC_NGINX -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (check_service_active $Script:HTTP_WINSVC_NGINX) {
        msg_success "nginx iniciado y activo"
    }
    else {
        msg_error "nginx no levanto — revise la configuracion"
        return $false
    }

    _http_configurar_firewall_inicial "nginx" $Puerto
    Write-Host ""
    http_crear_index "nginx" $Version $Puerto

    Write-Host ""
    http_draw_resumen "Nginx" "$Puerto" "$Version"
    return $true
}

#
# http_instalar_tomcat
#
# Instala Tomcat vía Chocolatey (requiere JDK instalado previamente).
#
function http_instalar_tomcat {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "Tomcat" "Paso 4 de 4 — Instalacion"

    # Verificar Java
    draw_line
    msg_info "PASO 1/5 — Verificar Java"
    draw_line

    $java = Get-Command java -ErrorAction SilentlyContinue
    if (-not $java) {
        msg_alert "Java no encontrado — requerido para Tomcat"
        Write-Host ""
        msg_input "Instalar Java 17 (Temurin) automaticamente ahora? [s/n]"
        $respJava = Read-Host
        $rcJava = http_validar_confirmacion $respJava
        if ($rcJava -ne 0) {
            msg_info "Instale Java manualmente con: choco install temurin17 -y"
            msg_info "Luego ejecute refreshenv o abra una nueva sesion y reintente"
            return $false
        }
        msg_info "Instalando Java 17 (Temurin) via Chocolatey..."
        & choco install temurin17 -y >$null 2>&1
        if ($LASTEXITCODE -ne 0) {
            msg_error "Fallo la instalacion de Java"
            return $false
        }
        # Refrescar PATH para que java sea visible en esta sesion
        $javaPath = "C:\Program Files\Eclipse Adoptium\jdk-17*\bin" |
        Resolve-Path -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if ($javaPath) { $env:PATH += ";$javaPath" }
        $java = Get-Command java -ErrorAction SilentlyContinue
        if (-not $java) {
            msg_error "Java instalado pero no visible en PATH — ejecute refreshenv y reintente"
            return $false
        }
    }
    $jver = (java -version 2>&1 | Select-Object -First 1)
    msg_success "Java disponible: $jver"

    Write-Host ""
    draw_line
    msg_info "PASO 2/5 — Instalacion de Tomcat via Chocolatey"
    draw_line

    # Setear JAVA_HOME explicitamente — el instalador choco de tomcat
    # lanza procesos hijos que no heredan el PATH refrescado en esta sesion
    $javaHome = Get-ChildItem "C:\Program Files\Eclipse Adoptium" -Directory `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($javaHome) {
        $env:JAVA_HOME = $javaHome.FullName
        msg_info "JAVA_HOME: $env:JAVA_HOME"
    }

    if ($Version -eq "latest") {
        & choco install tomcat -y >$null 2>&1
    }
    else {
        & choco install tomcat "--version=$Version" -y >$null 2>&1
    }

    # Verificar por existencia del servicio o del jar, no por exit code
    # choco instala tomcat en C:\ProgramData\chocolatey\lib\Tomcat\tools\
    $tomcatVerif = Get-Service -Name "Tomcat*" -ErrorAction SilentlyContinue |
    Select-Object -First 1
    if (-not $tomcatVerif) {
        # choco instalo los archivos pero no registro el servicio porque
        # JAVA_HOME no estaba disponible al momento de ejecutar el instalador.
        # Registrar manualmente con tomcat9.exe //IS//
        msg_alert "Servicio Tomcat no registrado por choco — registrando manualmente..."
        $tomcat9Exe = Get-ChildItem "C:\ProgramData\Tomcat9\bin" -Filter "tomcat9.exe" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $tomcat9Exe) {
            $tomcat9Exe = Get-ChildItem "C:\ProgramData\chocolatey\lib\Tomcat" `
                -Recurse -Filter "tomcat9.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        }
        if ($tomcat9Exe) {
            $catalinaHome = Split-Path (Split-Path $tomcat9Exe.FullName)
            $catalinaBase = "C:\ProgramData\Tomcat9"
            $env:CATALINA_HOME = $catalinaHome
            $env:CATALINA_BASE = $catalinaBase

            # Instalar NSSM si no esta disponible
            $nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue
            if (-not $nssmCmd) {
                msg_info "NSSM no encontrado — instalando via Chocolatey..."
                & choco install nssm -y >$null 2>&1
                $nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue
            }
            if (-not $nssmCmd) {
                msg_error "No se pudo instalar NSSM — Tomcat no quedara como servicio"
                return $false
            }

            # catalina.bat run mantiene el proceso en foreground — NSSM lo gestiona
            $catalinaBat = Join-Path $catalinaHome "bin\catalina.bat"

            & nssm install Tomcat9 cmd /c "`"$catalinaBat`" run" | Out-Null
            & nssm set Tomcat9 DisplayName "Apache Tomcat 9.0" | Out-Null
            & nssm set Tomcat9 AppDirectory $catalinaBase | Out-Null
            & nssm set Tomcat9 AppEnvironmentExtra `
                "JAVA_HOME=$($env:JAVA_HOME)" `
                "CATALINA_HOME=$catalinaHome" `
                "CATALINA_BASE=$catalinaBase" `
                "JRE_HOME=$($env:JAVA_HOME)" | Out-Null
            & nssm set Tomcat9 AppStdout "$catalinaBase\logs\service-stdout.log" | Out-Null
            & nssm set Tomcat9 AppStderr "$catalinaBase\logs\service-stderr.log" | Out-Null
            & nssm set Tomcat9 Start SERVICE_AUTO_START | Out-Null

            Start-Sleep -Seconds 2
            $tomcatVerif = Get-Service -Name "Tomcat9" -ErrorAction SilentlyContinue
            if ($tomcatVerif) {
                msg_success "Servicio Tomcat9 registrado via NSSM"
                $Script:HTTP_WINSVC_TOMCAT = "Tomcat9"
            }
            else {
                msg_error "No se pudo registrar el servicio Tomcat via NSSM"
                return $false
            }
        }
        else {
            msg_error "tomcat9.exe no encontrado — instalacion incompleta"
            return $false
        }
    }
    msg_success "tomcat instalado"

    Write-Host ""
    draw_line
    msg_info "PASO 3/5 — Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado $Script:HTTP_USUARIO_TOMCAT $Script:HTTP_DIR_TOMCAT

    Write-Host ""
    draw_line
    msg_info "PASO 4/5 — Configuracion de puerto en server.xml"
    draw_line
    if (Test-Path $Script:HTTP_CONF_TOMCAT) {
        http_crear_backup $Script:HTTP_CONF_TOMCAT
        [xml]$xml = Get-Content $Script:HTTP_CONF_TOMCAT
        $connector = $null
        foreach ($c in $xml.Server.Service.Connector) {
            if ($c.protocol -match 'HTTP') { $connector = $c; break }
        }
        if ($connector) {
            $connector.SetAttribute("port", "$Puerto")
            $xml.Save($Script:HTTP_CONF_TOMCAT)
            msg_success "Puerto $Puerto configurado en server.xml"
        }
    }

    Write-Host ""
    draw_line
    msg_info "PASO 5/5 — Activacion del servicio"
    draw_line
    Set-Service -Name $Script:HTTP_WINSVC_TOMCAT -StartupType Automatic `
        -ErrorAction SilentlyContinue
    Start-Service -Name $Script:HTTP_WINSVC_TOMCAT -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    if (check_service_active $Script:HTTP_WINSVC_TOMCAT) {
        msg_success "Tomcat iniciado y activo"
    }
    else {
        msg_error "Tomcat no levanto — verifique JAVA_HOME y logs"
        return $false
    }

    _http_configurar_firewall_inicial "tomcat" $Puerto
    Write-Host ""
    http_crear_index "tomcat" $Version $Puerto

    Write-Host ""
    http_draw_resumen "Apache Tomcat" "$Puerto" "$Version"
    return $true
}

#
# http_menu_instalar
#
# Orquestador del flujo completo de instalación.
# Equivalente a http_menu_instalar de FunctionsHTTP-B.sh
#
function http_menu_instalar {
    # ── Paso 1: Selección de servicio ────────────────────────────────────────
    $seleccion = http_seleccionar_servicio

    switch -Wildcard ($seleccion) {
        "cancelar" {
            msg_info "Instalacion cancelada"
            Start-Sleep -Seconds 2
            return
        }
        "reinstalar:*" {
            $servicio = $seleccion -replace "reinstalar:", ""

            # IIS se gestiona con DISM/WindowsFeature, no con choco.
            # Reinstalar IIS puede resetear applicationHost.config
            # y dejar inutilizable el sitio FTP si estaba configurado.
            if ($servicio -eq "iis") {
                Write-Host ""
                msg_alert "ADVERTENCIA: Reinstalar IIS puede afectar el servidor FTP."
                msg_alert "Si tiene IIS FTP configurado, puede quedar inutilizable."
                msg_info  "Se recomienda usar 'Reconfigurar' en lugar de reinstalar."
                Write-Host ""
                msg_input "¿Confirma que desea reinstalar IIS de todas formas? [S/N]: "
                $confirmReinstall = Read-Host
                if ($confirmReinstall -notmatch '^[SsYy]') {
                    msg_info "Reinstalacion cancelada"
                    Start-Sleep -Seconds 1
                    return
                }
                # Para IIS: desinstalar features via DISM
                msg_alert "Desinstalando IIS..."
                Uninstall-WindowsFeature -Name "Web-Server" -IncludeManagementTools `
                    -ErrorAction SilentlyContinue | Out-Null
                msg_success "IIS desinstalado. Continuando con instalacion limpia..."
            } else {
                msg_alert "Desinstalando $servicio..."
                choco uninstall (http_nombre_paquete $servicio) -y 2>$null
                msg_success "Desinstalado. Continuando con instalacion limpia..."
            }
            Start-Sleep -Seconds 2
        }
        "reconfigurar:*" {
            $servicio = $seleccion -replace "reconfigurar:", ""

            # ── Obtener versión instalada actualmente ──────────────────────
            # Apache: el paquete choco es "apache-httpd", no "apache".
            # Usamos http_nombre_paquete para obtener el nombre correcto y
            # filtramos por ese nombre en lugar de por el nombre interno.
            $verActual = _http_obtener_version_local $servicio

            $puertoNew = http_seleccionar_puerto $servicio

            # ── Cambiar puerto según el tipo de servicio ───────────────────
            switch ($servicio) {
                "iis" {
                    # IIS no usa archivo de texto — el puerto se gestiona
                    # via WebAdministration con bindings del sitio web.
                    # Solo se reemplaza el binding HTTP — se preserva el HTTPS
                    # para no romper SSL ni el sitio FTP.
                    Import-Module WebAdministration -ErrorAction SilentlyContinue
                    $site = Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
                    if ($site) {
                        # Eliminar SOLO el binding HTTP — dejar HTTPS intacto
                        Get-WebBinding -Name "Default Web Site" -Protocol "http" `
                            -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
                        New-WebBinding -Name "Default Web Site" -Protocol http -Port $puertoNew | Out-Null
                        msg_success "Binding HTTP actualizado: puerto $puertoNew"
                        # Informar si hay binding HTTPS activo
                        $httpsBinding = Get-WebBinding -Name "Default Web Site" -Protocol "https" `
                            -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($httpsBinding) {
                            $httpsPort = ($httpsBinding.bindingInformation -split ':')[1]
                            msg_info "Binding HTTPS preservado en puerto ${httpsPort}/tcp"
                        }
                    } else {
                        msg_alert "Sitio 'Default Web Site' no encontrado en IIS"
                    }
                }
                "apache" {
                    $confFile = http_get_conf_archivo $servicio
                    if (Test-Path $confFile) {
                        http_crear_backup $confFile
                        $bytesApache = [System.IO.File]::ReadAllBytes($confFile)
                        if ($bytesApache[0] -eq 0xEF -and $bytesApache[1] -eq 0xBB -and $bytesApache[2] -eq 0xBF) {
                            $contenidoApache = [System.Text.Encoding]::UTF8.GetString($bytesApache, 3, $bytesApache.Length - 3)
                        } else {
                            $contenidoApache = [System.Text.Encoding]::UTF8.GetString($bytesApache)
                        }
                        $contenidoApache = $contenidoApache -replace 'Listen\s+\d+', "Listen $puertoNew"
                        $contenidoApache = $contenidoApache -replace 'ServerName\s+\S+:\d+', "ServerName localhost:$puertoNew"
                        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                        [System.IO.File]::WriteAllText($confFile, $contenidoApache, $utf8NoBom)
                        msg_success "Puerto $puertoNew configurado en httpd.conf"
                    } else {
                        msg_alert "httpd.conf no encontrado — omitiendo cambio de puerto"
                    }
                }
                "nginx" {
                    $confFile = http_get_conf_archivo $servicio
                    if (Test-Path $confFile) {
                        http_crear_backup $confFile
                        $bytesNginx = [System.IO.File]::ReadAllBytes($confFile)
                        if ($bytesNginx[0] -eq 0xEF -and $bytesNginx[1] -eq 0xBB -and $bytesNginx[2] -eq 0xBF) {
                            $contenidoNginx = [System.Text.Encoding]::UTF8.GetString($bytesNginx, 3, $bytesNginx.Length - 3)
                        } else {
                            $contenidoNginx = [System.Text.Encoding]::UTF8.GetString($bytesNginx)
                        }
                        $contenidoNginx = $contenidoNginx -replace 'listen\s+\d+;', "listen $puertoNew;"
                        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                        [System.IO.File]::WriteAllText($confFile, $contenidoNginx, $utf8NoBom)
                        msg_success "Puerto $puertoNew configurado en nginx.conf"
                    } else {
                        msg_alert "nginx.conf no encontrado — omitiendo cambio de puerto"
                    }
                }
                "tomcat" {
                    $confFile = http_get_conf_archivo $servicio
                    if (Test-Path $confFile) {
                        http_crear_backup $confFile
                        [xml]$xml = Get-Content $confFile
                        $connector = $null
                        foreach ($c in $xml.Server.Service.Connector) {
                            if ($c.protocol -match 'HTTP') { $connector = $c; break }
                        }
                        if ($connector) {
                            $connector.SetAttribute("port", "$puertoNew")
                            $xml.Save($confFile)
                            msg_success "Puerto $puertoNew configurado en server.xml"
                        }
                    } else {
                        msg_alert "server.xml no encontrado — omitiendo cambio de puerto"
                    }
                }
            }

            if (-not (http_reiniciar_servicio $servicio)) {
                msg_error "El servicio no levanto — revise la configuracion"
                msg_pause
                return
            }

            _http_configurar_firewall_inicial $servicio $puertoNew
            http_crear_index $servicio $verActual $puertoNew
            http_draw_resumen $servicio $puertoNew $verActual

            # ── Hook SSL en reconfiguración ───────────────────────────
            $sslLibPath = Join-Path $PSScriptRoot "..\ssl_lib\ssl.ps1"
            if (Test-Path $sslLibPath) {
                Write-Host ""
                Write-Separator
                msg_input "¿Desea activar/reconfigurar SSL/TLS en ${servicio}? [S/N]: "
                $sslResp = Read-Host
                if ($sslResp -match '^[SsYy]') {
                    . $sslLibPath
                    switch ($servicio) {
                        "iis"    { ssl_configurar_iis    }
                        "apache" { ssl_configurar_apache }
                        "nginx"  { ssl_configurar_nginx  }
                        "tomcat" { ssl_configurar_tomcat }
                    }
                } else {
                    msg_info "SSL omitido — puede activarlo desde ssl_manager.ps1"
                }
            }

            msg_pause
            return
        }
        default { $servicio = $seleccion }
    }

    Write-Host ""

    # ── Selección de fuente de instalación ─────────────────────────────────
    Write-Separator
    msg_info "Fuente de instalación"
    Write-Separator
    Write-Host ""
    Write-Host "  1) Repositorio oficial (internet)"
    Write-Host "  2) Repositorio FTP local"
    Write-Host ""
    $ftpFuente = ""
    do {
        msg_input "Fuente [1/2]: "
        $ftpFuente = Read-Host
        if ($ftpFuente -ne "1" -and $ftpFuente -ne "2") {
            msg_error "Ingrese 1 o 2"; $ftpFuente = ""
        }
    } while ([string]::IsNullOrEmpty($ftpFuente))

    if ($ftpFuente -eq "2") {
        $ftpSrcLib = Join-Path $PSScriptRoot "ws_ftp_source.ps1"
        if (-not (Test-Path $ftpSrcLib)) {
            msg_error "ws_ftp_source.ps1 no encontrado en: $ftpSrcLib"
            msg_pause; return
        }
        . $ftpSrcLib

        # Paso 2+3: FTP completo — incluye credenciales, OS, versión, descarga,
        # selección de puerto e instalación. El puerto queda guardado en $puertoFtp
        # vía la variable de retorno para usarlo en firewall e index.
        $puertoFtp = 0
        $versionFtp = ""
        if (-not (ftp_src_flujo_completo $servicio ([ref]$versionFtp))) {
            msg_error "Instalación desde FTP fallida"
            msg_pause; return
        }
        # Recuperar el puerto que ftp_src_flujo_completo aplicó
        $puertoFtp = $script:FTP_SRC_LAST_PORT
        if (-not (http_validar_puerto "$puertoFtp")) { return }

        _http_configurar_firewall_inicial $servicio $puertoFtp
        http_crear_index $servicio $versionFtp $puertoFtp
        http_draw_resumen $servicio "$puertoFtp" $versionFtp

        $sslLibFtp = Join-Path $PSScriptRoot "..\ssl_lib\ssl.ps1"
        if (Test-Path $sslLibFtp) {
            Write-Host ""; Write-Separator
            msg_input "¿Desea activar SSL/TLS en ${servicio}? [S/N]: "
            $sslRespFtp = Read-Host
            if ($sslRespFtp -match '^[SsYy]') {
                . $sslLibFtp
                switch ($servicio) {
                    "iis"    { ssl_configurar_iis    }
                    "apache" { ssl_configurar_apache }
                    "nginx"  { ssl_configurar_nginx  }
                    "tomcat" { ssl_configurar_tomcat }
                }
            }
        }
        Write-Host ""; msg_pause; return
    }

    # ── Paso 2: Consultar versiones ──────────────────────────────────────────
    $versiones = http_consultar_versiones $servicio
    if (-not $versiones -or $versiones.Count -eq 0) {
        msg_error "No se pudieron obtener versiones. Verifique la conexion."
        msg_pause
        return
    }

    Write-Host ""

    # ── Paso 3: Selección de versión ─────────────────────────────────────────
    $version = http_seleccionar_version $servicio $versiones

    Write-Host ""
    msg_pause

    # ── Paso 4: Selección de puerto ──────────────────────────────────────────
    $puerto = http_seleccionar_puerto $servicio

    Write-Host ""

    # ── Confirmación final ───────────────────────────────────────────────────
    draw_line
    msg_info "Resumen de la instalacion a realizar:"
    Write-Host ""
    Write-Host ("    Servicio : $servicio")
    Write-Host ("    Version  : $version")
    Write-Host ("    Puerto   : ${puerto}/tcp")
    Write-Host ""

    $confirmado = $false
    do {
        msg_input "Confirmar instalacion? [s/n]"
        $resp = Read-Host
        $r = http_validar_confirmacion $resp
        if ($r -eq 0) { $confirmado = $true; break }
        if ($r -eq 1) { msg_info "Instalacion cancelada"; Start-Sleep 2; return }
        Write-Host ""
    } while ($true)

    draw_line
    Write-Host ""

    # ── Paso 5: Ejecutar la instalación ─────────────────────────────────────
    switch ($servicio) {
        "iis"    { http_instalar_iis    $version $puerto }
        "apache" { http_instalar_apache $version $puerto }
        "nginx"  { http_instalar_nginx  $version $puerto }
        "tomcat" { http_instalar_tomcat $version $puerto }
    }

    # ── Hook SSL ──────────────────────────────────────────────────────────────
    # Ofrecer SSL después de cada instalación exitosa
    $sslLibPath = Join-Path $PSScriptRoot "..\ssl_lib\ssl.ps1"
    if (Test-Path $sslLibPath) {
        Write-Host ""
        Write-Separator
        msg_input "¿Desea activar SSL/TLS en ${servicio}? [S/N]: "
        $sslResp = Read-Host
        if ($sslResp -match '^[SsYy]') {
            . $sslLibPath
            switch ($servicio) {
                "iis"    { ssl_configurar_iis    }
                "apache" { ssl_configurar_apache }
                "nginx"  { ssl_configurar_nginx  }
                "tomcat" { ssl_configurar_tomcat }
            }
            # Actualizar index.html con ambos puertos si SSL se configuro
            # Leer los puertos exportados por ssl_configurar_* 
            $httpsLast = $script:_SSL_LAST_HTTPS_PORT
            $httpLast  = $script:_SSL_LAST_HTTP_PORT
            msg_info "Puertos SSL exportados: HTTP=$httpLast HTTPS=$httpsLast"
            if ($httpsLast -gt 0 -and $httpLast -gt 0) {
                $verIdx = if ($servicio -ne "iis") {
                    $pkgName = http_nombre_paquete $servicio
                    $verLine = choco list --local-only $pkgName 2>$null |
                        Where-Object { $_ -match "^$pkgName\s" } |
                        Select-Object -First 1
                    if ($verLine) { ($verLine -split "\s+")[1] } else { "instalado" }
                } else { "sistema" }
                http_crear_index $servicio $verIdx ([int]$httpLast) ([int]$httpsLast)
                msg_success "index.html actualizado con puertos HTTP=${httpLast} HTTPS=${httpsLast}"
                $script:_SSL_LAST_HTTP_PORT  = 0
                $script:_SSL_LAST_HTTPS_PORT = 0
            } else {
                msg_alert "No se detectaron puertos SSL exportados — index.html sin HTTPS"
                msg_info  "Verifique que ssl_configurar_* completó sin errores"
            }
        } else {
            msg_info "SSL omitido — puede activarlo desde ssl_manager.ps1"
        }
    }

    Write-Host ""
    msg_pause
}