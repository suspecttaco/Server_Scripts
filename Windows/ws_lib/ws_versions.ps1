#
# FunctionsHTTP-D.ps1
# Grupo D — Gestión de versiones (upgrade / downgrade)
#
# Equivalente a FunctionsHTTP-D.sh de la práctica Linux.
# En Windows el gestor de paquetes es Chocolatey (choco) en lugar de dnf.
#
# Funciones públicas:
#   http_ver_version_instalada()   — Panel de versiones instaladas vs disponibles
#   http_upgrade_servicio()        — Actualiza a versión superior (choco upgrade)
#   http_downgrade_servicio()      — Retrocede a versión anterior (choco install --version)
#   http_menu_versiones()          — Submenú del Grupo D
#
# Funciones internas (prefijo _):
#   _http_comparar_versiones()     — Compara dos cadenas semver
#   _http_versiones_superiores()   — Filtra versiones > instalada
#   _http_versiones_inferiores()   — Filtra versiones < instalada
#   _http_ejecutar_cambio_version()— Orquestador común upgrade/downgrade
#
# Requiere: utils.ps1, utilsHTTP.ps1, validatorsHTTP.ps1,
#           FunctionsHTTP-A.ps1, FunctionsHTTP-B.ps1, FunctionsHTTP-C.ps1
#

#Requires -Version 5.1

#
# _http_comparar_versiones  (interna)
#
# Compara dos cadenas de versión semver.
# Equivalente a _http_comparar_versiones de FunctionsHTTP-D.sh
#
# Uso: _http_comparar_versiones "2.4.58" "2.4.62"
# Devuelve: "menor" | "igual" | "mayor"
#
function _http_comparar_versiones {
    param([string]$V1, [string]$V2)

    # Limpiar sufijos de release (ej: "2.4.58-1.fc43" → "2.4.58")
    $v1Clean = ($V1 -split '-')[0]
    $v2Clean = ($V2 -split '-')[0]

    try {
        $ver1 = [version]$v1Clean
        $ver2 = [version]$v2Clean

        if ($ver1 -lt $ver2) { return "menor" }
        if ($ver1 -gt $ver2) { return "mayor" }
        return "igual"
    }
    catch {
        # Si no se puede parsear como version, comparar como string
        if ($v1Clean -lt $v2Clean) { return "menor" }
        if ($v1Clean -gt $v2Clean) { return "mayor" }
        return "igual"
    }
}

#
# _http_versiones_superiores  (interna)
#
# Obtiene versiones disponibles en Chocolatey numéricamente mayores
# que la instalada actualmente.
# Equivalente a _http_versiones_superiores de FunctionsHTTP-D.sh
#
# Uso: $vers = _http_versiones_superiores "nginx" "1.24.0"
#
function _http_versiones_superiores {
    param([string]$Servicio, [string]$VersionActual)

    $paquete = http_nombre_paquete $Servicio
    $verActClean = ($VersionActual -split '-')[0]

    $todas = choco list $paquete --all 2>$null |
    Where-Object { $_ -match "^$paquete\s+[\d]" } |
    ForEach-Object { ($_ -split '\s+')[1] }

    return ($todas | Where-Object {
            $v = ($_ -split '-')[0]
            (_http_comparar_versiones $v $verActClean) -eq "mayor"
        } | Sort-Object { [version](($_ -split '-')[0]) } -Descending)
}

#
# _http_versiones_inferiores  (interna)
#
# Obtiene versiones disponibles en Chocolatey numéricamente menores
# que la instalada actualmente.
# Equivalente a _http_versiones_inferiores de FunctionsHTTP-D.sh
#
# Uso: $vers = _http_versiones_inferiores "nginx" "1.28.0"
#
function _http_versiones_inferiores {
    param([string]$Servicio, [string]$VersionActual)

    $paquete = http_nombre_paquete $Servicio
    $verActClean = ($VersionActual -split '-')[0]

    $todas = choco list $paquete --all 2>$null |
    Where-Object { $_ -match "^$paquete\s+[\d]" } |
    ForEach-Object { ($_ -split '\s+')[1] }

    return ($todas | Where-Object {
            $v = ($_ -split '-')[0]
            (_http_comparar_versiones $v $verActClean) -eq "menor"
        } | Sort-Object { [version](($_ -split '-')[0]) } -Descending)
}

#
# http_ver_version_instalada
#
# Panel de versiones instaladas para los cuatro servicios.
# Muestra: versión, fecha de instalación, estado, puerto activo y
# comparación con la última disponible en Chocolatey.
# Equivalente a http_ver_version_instalada de FunctionsHTTP-D.sh
#
function http_ver_version_instalada {
    Clear-Host
    draw_header "Version Instalada de Servicios HTTP"

    $servicios = @(
        @{ Interno = "iis"; Nombre = "IIS"; WinSvc = $Script:HTTP_WINSVC_IIS }
        @{ Interno = "apache"; Nombre = "Apache (httpd)"; WinSvc = $Script:HTTP_WINSVC_APACHE }
        @{ Interno = "nginx"; Nombre = "Nginx"; WinSvc = $Script:HTTP_WINSVC_NGINX }
        @{ Interno = "tomcat"; Nombre = "Tomcat"; WinSvc = $Script:HTTP_WINSVC_TOMCAT }
    )

    foreach ($svc in $servicios) {
        Write-Host ""
        Write-Host "  ${CYAN}-> $($svc.Nombre)${NC}"
        Write-Separator

        # IIS: versión desde el registro
        if ($svc.Interno -eq "iis") {
            $iisReg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
                -ErrorAction SilentlyContinue
            if ($iisReg) {
                Write-Host ("  ${GREEN}[OK]${NC}  {0,-20}: {1}" -f "Version instalada", $iisReg.VersionString)
                Write-Host ("        {0,-20}: Sistema Windows" -f "Gestor")
            }
            else {
                Write-Host ("  ${GRAY}[--]${NC}  No instalado")
            }
            Write-Host ""
            continue
        }

        # Resto: detectar via Get-Service (primario) + choco para version
        $paquete   = http_nombre_paquete $svc.Interno
        $svcObj    = Get-Service -Name $svc.WinSvc -ErrorAction SilentlyContinue
        $chocoInfo = choco list $paquete 2>$null | Where-Object { $_ -match "^$paquete\s" }

        if (-not $svcObj -and -not $chocoInfo) {
            Write-Host ("  ${GRAY}[--]${NC}  No instalado")
            Write-Host ""
            continue
        }

        $verInstalada = ($chocoInfo -split '\s+')[1]
        Write-Host ("  ${GREEN}[OK]${NC}  {0,-20}: {1}" -f "Version instalada", $verInstalada)

        # Fecha de instalación (desde el log de choco si existe)
        $chocoLog = "$env:ChocolateyInstall\logs\chocolatey.log"
        if (Test-Path $chocoLog) {
            $fechaLine = Get-Content $chocoLog |
            Where-Object { $_ -match "Successfully installed '$paquete'" } |
            Select-Object -Last 1
            if ($fechaLine -match '\d{4}-\d{2}-\d{2}') {
                Write-Host ("        {0,-20}: {1}" -f "Instalado el", $Matches[0])
            }
        }

        # Estado del servicio
        if (check_service_active $svc.WinSvc) {
            $wmiSvc = Get-CimInstance Win32_Service -Filter "Name='$($svc.WinSvc)'" `
                -ErrorAction SilentlyContinue
            $pidStr = if ($wmiSvc) { "PID: $($wmiSvc.ProcessId)" } else { "" }
            Write-Host ("        {0,-20}: {1}{2}" -f "Servicio", "${GREEN}ACTIVO${NC}", " — $pidStr")
        }
        else {
            Write-Host ("        {0,-20}: {1}" -f "Servicio", "${YELLOW}INACTIVO${NC}")
        }

        # Puerto activo
        $puertoActivo = _http_obtener_puerto_activo $svc.WinSvc
        if ($puertoActivo -gt 0) {
            Write-Host ("        {0,-20}: {1}/tcp" -f "Puerto activo", $puertoActivo)
        }
        else {
            $puertoConf = _http_leer_puerto_config $svc.Interno
            Write-Host ("        {0,-20}: {1}/tcp (servicio inactivo)" -f "Puerto en config", $puertoConf)
        }

        # Comparar con la última versión disponible en choco
        msg_info "  Consultando ultima version disponible en Chocolatey..."

        # choco info devuelve la version disponible en el repositorio
        $ultimaDisp = choco info $paquete 2>$null |
        Where-Object { $_ -match "^$paquete\s+[\d]" } |
        ForEach-Object { ($_ -split '\s+')[1] } |
        Select-Object -First 1

        if ($ultimaDisp) {
            $relacion = _http_comparar_versiones `
            ($verInstalada -split '-')[0] `
            ($ultimaDisp -split '-')[0]

            switch ($relacion) {
                "igual" {
                    Write-Host ("        ${GREEN}Al dia${NC} — ultima version: {0}" -f $ultimaDisp)
                }
                "menor" {
                    Write-Host ("        ${YELLOW}Actualizacion disponible${NC}: {0} -> {1}" -f $verInstalada, $ultimaDisp)
                    msg_info  "  Use Grupo D opcion 2) para actualizar"
                }
                "mayor" {
                    Write-Host ("        ${CYAN}Version mas reciente que el repositorio${NC}: {0}" -f $verInstalada)
                }
            }
        }
        else {
            Write-Host ("        {0,-20}: no disponible (sin conexion)" -f "Version en repo")
        }

        Write-Host ""
    }

    draw_line
}

#
# _http_ejecutar_cambio_version  (interna)
#
# Orquestador común para upgrade y downgrade.
# En Windows: choco upgrade / choco install --version=X
# Flujo:
#   1. Leer versión y puerto actuales
#   2. Mostrar versiones disponibles
#   3. Seleccionar versión destino
#   4. Backup de configuración
#   5. Ejecutar choco upgrade/install --version
#   6. Verificar que la versión cambió
#   7. Reaplicar el puerto (choco puede resetear la config)
#   8. Reiniciar servicio
#   9. Verificar respuesta HTTP
#  10. Actualizar index.html
#
# Equivalente a _http_ejecutar_cambio_version de FunctionsHTTP-D.sh
#
function _http_ejecutar_cambio_version {
    param(
        [string]   $Servicio,
        [string]   $Operacion,      # "upgrade" o "downgrade"
        [string[]] $VersionesDisp
    )

    if ($VersionesDisp.Count -eq 0) {
        if ($Operacion -eq "upgrade") {
            msg_info "No hay versiones superiores disponibles en Chocolatey"
            msg_info "El servicio ya esta en la version mas reciente"
        }
        else {
            msg_info "No hay versiones anteriores disponibles en Chocolatey"
            msg_info "Esta es la version mas antigua disponible"
        }
        return
    }

    $paquete = http_nombre_paquete $Servicio

    # ── Paso 1: Leer estado actual ────────────────────────────────────────
    $verActual = choco list $paquete 2>$null |
    Where-Object { $_ -match "^$paquete\s" } |
    ForEach-Object { ($_ -split '\s+')[1] }
    $puertoActual = _http_leer_puerto_config $Servicio
    if ([string]::IsNullOrEmpty($puertoActual)) {
        $puertoActual = switch ($Servicio) {
            "iis" { "$($Script:HTTP_PUERTO_DEFAULT_IIS)" }
            "apache" { "$($Script:HTTP_PUERTO_DEFAULT_APACHE)" }
            "nginx" { "$($Script:HTTP_PUERTO_DEFAULT_NGINX)" }
            "tomcat" { "$($Script:HTTP_PUERTO_DEFAULT_TOMCAT)" }
        }
    }

    msg_info "Version actual    : $verActual"
    msg_info "Puerto preservado : ${puertoActual}/tcp"
    Write-Host ""

    # ── Paso 2: Mostrar versiones disponibles ─────────────────────────────
    $etiquetaOp = if ($Operacion -eq "upgrade") { "superiores" } else { "anteriores" }
    msg_info "Versiones ${etiquetaOp} disponibles en Chocolatey:"
    Write-Host ""
    Write-Host ("  {0,-6} {1}" -f "NUM", "VERSION")
    Write-Separator

    for ($i = 0; $i -lt $VersionesDisp.Count; $i++) {
        Write-Host ("  {0,-6} {1}" -f "$($i+1))", $VersionesDisp[$i])
    }
    Write-Host ""

    # ── Paso 3: Seleccionar versión destino ───────────────────────────────
    $idxElegido = ""
    do {
        msg_input "Seleccione version destino [1-$($VersionesDisp.Count)]"
        $idxElegido = Read-Host
    } while (-not (http_validar_indice_version $idxElegido $VersionesDisp.Count))

    $versionDestino = $VersionesDisp[[int]$idxElegido - 1]

    Write-Host ""
    msg_alert "Se realizara $Operacion de ${Servicio}:"
    Write-Host "    Version actual  : $verActual"
    Write-Host "    Version destino : $versionDestino"
    Write-Host "    Puerto          : ${puertoActual}/tcp (se preservara)"
    Write-Host ""

    # Confirmación
    $confirmado = $false
    do {
        msg_input "Confirmar ${Operacion}? [s/n]"
        $resp = Read-Host
        $rc = http_validar_confirmacion $resp
        if ($rc -eq 0) { $confirmado = $true; break }
        if ($rc -eq 1) {
            msg_info "${Operacion} cancelado"
            Start-Sleep 1
            return
        }
        Write-Host ""
    } while ($true)

    draw_line
    Write-Host ""

    # ── Paso 4: Backup ────────────────────────────────────────────────────
    $confFile = http_get_conf_archivo $Servicio
    msg_info "PASO 1/5 — Backup de configuracion"
    http_crear_backup $confFile
    Write-Host ""

    # ── Paso 5: Ejecutar choco upgrade / install --version ────────────────
    msg_info "PASO 2/5 — Ejecutando choco $Operacion a $versionDestino"
    Write-Host ""

    if ($Operacion -eq "upgrade") {
        # choco upgrade actualiza a la última por defecto — usamos install con version exacta
        $chocoResult = choco install $paquete --version=$versionDestino --allow-downgrade -y 2>&1
    }
    else {
        # Downgrade en choco también usa install --version con --allow-downgrade
        $chocoResult = choco install $paquete --version=$versionDestino --allow-downgrade -y 2>&1
    }

    $chocoResult | ForEach-Object { Write-Host "    $_" }

    if ($LASTEXITCODE -ne 0) {
        msg_error "Error durante el $Operacion — restaurando configuracion"
        http_restaurar_backup $confFile
        return
    }

    Write-Host ""

    # ── Paso 6: Verificar que la versión cambió ───────────────────────────
    msg_info "PASO 3/5 — Verificando version instalada tras $Operacion"
    $verNueva = choco list $paquete 2>$null |
    Where-Object { $_ -match "^$paquete\s" } |
    ForEach-Object { ($_ -split '\s+')[1] }

    if ($verNueva -eq $verActual) {
        msg_alert "La version no cambio tras el $Operacion"
        msg_info    "choco puede haber omitido el cambio si ya estaba satisfecho"
    }
    else {
        msg_success "Version actualizada: $verActual -> $verNueva"
    }

    Write-Host ""

    # ── Paso 7: Reaplicar puerto ──────────────────────────────────────────
    # choco puede sobrescribir el archivo de configuración con el del paquete
    # nuevo, reseteando el puerto al valor por defecto. Se reaaplica siempre.
    msg_info "PASO 4/5 — Reaplying puerto $puertoActual en configuracion"

    switch ($Servicio) {
        "apache" {
            if (Test-Path $Script:HTTP_CONF_APACHE) {
                $apacheContent = (Get-Content $Script:HTTP_CONF_APACHE -Raw) -replace 'Listen\s+\d+', "Listen $puertoActual"
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($Script:HTTP_CONF_APACHE, $apacheContent, $utf8NoBom)
            }
        }
        "nginx" {
            if (Test-Path $Script:HTTP_CONF_NGINX) {
                $nginxContent = (Get-Content $Script:HTTP_CONF_NGINX -Raw) -replace 'listen\s+\d+;', "listen $puertoActual;"
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($Script:HTTP_CONF_NGINX, $nginxContent, $utf8NoBom)
            }
        }
        "tomcat" {
            if (Test-Path $Script:HTTP_CONF_TOMCAT) {
                [xml]$xml = Get-Content $Script:HTTP_CONF_TOMCAT
                $connector = $null
                foreach ($c in $xml.Server.Service.Connector) {
                    if ($c.protocol -match 'HTTP') { $connector = $c; break }
                }
                if ($connector) {
                    $connector.SetAttribute("port", $puertoActual)
                    $xml.Save($Script:HTTP_CONF_TOMCAT)
                }
            }
        }
        "iis" {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            Remove-WebBinding -Name "Default Web Site" -ErrorAction SilentlyContinue
            New-WebBinding -Name "Default Web Site" -Protocol http `
                -Port ([int]$puertoActual) | Out-Null
        }
    }

    msg_success "Puerto $puertoActual reaplicado en configuracion"
    Write-Host ""

    # ── Paso 8: Reiniciar servicio ────────────────────────────────────────
    msg_info "PASO 5/5 — Reiniciando servicio"
    if (-not (http_reiniciar_servicio $Servicio)) {
        msg_error "El servicio no levanto tras el $Operacion"
        msg_alert "Restaurando configuracion anterior..."
        http_restaurar_backup $confFile
        # Intentar volver a la version anterior
        msg_info "Intentando restaurar version $verActual..."
        choco install $paquete --version=$verActual --allow-downgrade -y 2>$null | Out-Null
        http_reiniciar_servicio $Servicio
        return
    }

    Write-Host ""

    # ── Paso 9: Verificar respuesta HTTP ──────────────────────────────────
    msg_info "Verificando respuesta HTTP en puerto ${puertoActual}..."
    Start-Sleep -Seconds 2

    if (-not (http_verificar_respuesta $Servicio ([int]$puertoActual))) {
        msg_alert "El servicio no responde — puede necesitar mas tiempo"
        msg_info    "Verifique manualmente: curl.exe -I http://localhost:${puertoActual}"
    }

    Write-Host ""

    # ── Paso 10: Actualizar index.html ────────────────────────────────────
    http_crear_index $Servicio $verNueva ([int]$puertoActual)

    Write-Host ""
    draw_line
    msg_success "${Operacion} completado: $verActual -> $verNueva"
    Write-Host "    Servicio : $Servicio"
    Write-Host "    Puerto   : ${puertoActual}/tcp (preservado)"
    draw_line
}

#
# http_upgrade_servicio
#
# Actualiza un servicio HTTP a una versión superior disponible en Chocolatey.
# Muestra solo versiones numéricamente mayores a la actual.
# Equivalente a http_upgrade_servicio de FunctionsHTTP-D.sh
#
function http_upgrade_servicio {
    Clear-Host
    draw_header "Upgrade de Servicio HTTP"

    msg_info "Actualiza el servicio a una version superior disponible en"
    msg_info "Chocolatey. Preserva el puerto configurado."
    Write-Host ""

    $servicio = _http_seleccionar_servicio_instalado
    if ([string]::IsNullOrEmpty($servicio)) { return }

    if ($servicio -eq "iis") {
        msg_alert "IIS se actualiza via Windows Update, no via Chocolatey"
        msg_info    "Use: Install-WindowsUpdate -AcceptAll (modulo PSWindowsUpdate)"
        return
    }

    http_draw_servicio_header $servicio "Upgrade de Version"

    msg_info "Consultando versiones superiores disponibles en Chocolatey..."
    Write-Host ""

    $paquete = http_nombre_paquete $servicio
    $verActual = choco list $paquete 2>$null |
    Where-Object { $_ -match "^$paquete\s" } |
    ForEach-Object { ($_ -split '\s+')[1] }

    $versionesUpgrade = _http_versiones_superiores $servicio $verActual
    _http_ejecutar_cambio_version $servicio "upgrade" $versionesUpgrade
}

#
# http_downgrade_servicio
#
# Retrocede un servicio HTTP a una versión anterior disponible en Chocolatey.
# Muestra solo versiones numéricamente menores a la actual.
# Equivalente a http_downgrade_servicio de FunctionsHTTP-D.sh
#
function http_downgrade_servicio {
    Clear-Host
    draw_header "Downgrade de Servicio HTTP"

    msg_alert "El downgrade retrocede el servicio a una version anterior."
    msg_alert "Use esto solo si la version actual presenta problemas."
    Write-Host ""

    $servicio = _http_seleccionar_servicio_instalado
    if ([string]::IsNullOrEmpty($servicio)) { return }

    if ($servicio -eq "iis") {
        msg_alert "IIS no puede hacer downgrade de forma sencilla en Windows"
        msg_info    "Considere usar un punto de restauracion del sistema"
        return
    }

    http_draw_servicio_header $servicio "Downgrade de Version"

    msg_info "Consultando versiones anteriores disponibles en Chocolatey..."
    Write-Host ""

    $paquete = http_nombre_paquete $servicio
    $verActual = choco list $paquete 2>$null |
    Where-Object { $_ -match "^$paquete\s" } |
    ForEach-Object { ($_ -split '\s+')[1] }

    $versionesDowngrade = _http_versiones_inferiores $servicio $verActual
    _http_ejecutar_cambio_version $servicio "downgrade" $versionesDowngrade
}

#
# http_menu_versiones
#
# Submenú del Grupo D. Llamado desde http_menu_configurar (Grupo C, opción 4).
# Equivalente a http_menu_versiones de FunctionsHTTP-D.sh
#
function http_menu_versiones {
    while ($true) {
        Clear-Host
        draw_header "Gestion de Versiones HTTP"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Ver version instalada y disponibilidad de actualizaciones"
        Write-Host "  ${BLUE}2)${NC} Upgrade   — actualizar a version superior"
        Write-Host "  ${BLUE}3)${NC} Downgrade — retroceder a version anterior"
        Write-Host "  ${BLUE}4)${NC} Volver al menu de configuracion"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" { http_ver_version_instalada; Write-Host ""; msg_pause }
            "2" { http_upgrade_servicio; Write-Host ""; msg_pause }
            "3" { http_downgrade_servicio; Write-Host ""; msg_pause }
            "4" { return }
            default {
                msg_error "Opcion invalida. Seleccione entre 1 y 4"
                Start-Sleep -Seconds 2
            }
        }
    }
}