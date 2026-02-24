$ErrorActionPreference = "Stop"
#
#   Gestor de Servicio DHCP - Windows Server
#
#   Requiere:
#       lib\ui.ps1    -> funciones de salida formateada (msg_*, Write-Separator)
#       lib\net.ps1   -> validaciones de IP, mascara y calculo de subred
#       lib\iface.ps1 -> deteccion y configuracion de interfaces de red
#
#   NOTA: Disenado para Windows Server en modo Workgroup (sin Active Directory).
#         Se utiliza -Force en Set-DhcpServerv4OptionValue para omitir la
#         validacion de PTR que Windows realiza cuando no hay AD disponible.
#
#Requires -RunAsAdministrator

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($lib in @('ui', 'net', 'iface')) {
    $libPath = Join-Path $ScriptDir "lib\${lib}.ps1"
    if (-not (Test-Path $libPath)) {
        Write-Host "ERROR: No se encontro el modulo requerido: $libPath"
        exit 1
    }
    . $libPath
}

# =============================================================================
#   Tabla de equivalencias (referencia interna)
#
#   utils.ps1 / validators.ps1      -> lib equivalente
#   -----------------------------------------------
#   Write-InfoMessage $m            -> msg_info    $m        (lib\ui.ps1)
#   Write-SuccessMessage $m         -> msg_success $m        (lib\ui.ps1)
#   Write-ErrorMessage $m           -> msg_error   $m        (lib\ui.ps1)
#   Write-WarningCustom $m          -> msg_alert   $m        (lib\ui.ps1)
#   Write-SeparatorLine             -> Write-Separator       (lib\ui.ps1)
#   Write-Header $t                 -> Write-Separator +
#                                      Write-Host $t +
#                                      Write-Separator       (lib\ui.ps1)
#   Read-Host (con prompt inline)   -> msg_input $p; Read-Host (lib\ui.ps1)
#   Invoke-Pause                    -> Read-Host "Enter..."  (inline)
#   Test-AdminPrivileges            -> #Requires -RunAsAdministrator
#   validar_formato_ip $ip          -> Test-ValidIp $ip      (lib\net.ps1)
#   validar_cidr $cidr              -> Test-ValidCidr $cidr  (lib\net.ps1)
#   validar_ip_usable $ip           -> Test-ValidIp $ip      (lib\net.ps1)
#   validar_ip_no_especial $ip ...  -> Test-IpIsNetwork /
#                                      Test-IpIsBroadcast    (lib\net.ps1)
#   validar_mismo_segmento $r $i $m -> Test-IpInNetwork      (lib\net.ps1)
#   validar_rango_ips $ini $fin     -> IpToInt comparacion   (lib\net.ps1)
#   calcular_subred_cidr $ip $cidr  -> CidrToMask +
#                                      Get-NetworkAddress +
#                                      Get-BroadcastAddress  (lib\net.ps1)
#   ip_a_numero $ip                 -> IpToInt $ip           (lib\net.ps1)
#   numero_a_ip $num                -> IntToIp $num          (lib\net.ps1)
#   obtener_ip_red $ip $mask        -> Get-NetworkAddress    (lib\net.ps1)
#   cidr_a_mascara $cidr            -> CidrToMask $cidr      (lib\net.ps1)
# =============================================================================

#
#   Variables Globales
#
$script:interfaces           = @()
$script:listaInterfaces      = @()
$script:interfazSeleccionada = $null
$script:nombreScope          = ""
$script:red                  = ""
$script:mascara              = ""
$script:bitsMascara          = 0
$script:ipServidorEstatica   = ""   # primera IP del rango ingresado
$script:ipInicio             = ""
$script:ipInicioClientes     = ""   # ipInicio + 1 (rango para clientes)
$script:ipFin                = ""
$script:gateway              = ""
$script:dnsPrimario          = ""
$script:dnsSecundario        = ""
$script:leaseTime            = $null

# Exponer variables de segmento que Test-IpInSegment (lib\net.ps1) necesita
# en $script:NETWORK_ADDRESS, $script:MASCARA, $script:BROADCAST_ADDRESS, $script:CIDR
$script:NETWORK_ADDRESS   = ""
$script:MASCARA           = ""
$script:BROADCAST_ADDRESS = ""
$script:CIDR              = 0

# Helper: sincroniza las variables de lib\net con las locales tras calcular subred
function Sync-SubnetVars {
    $script:NETWORK_ADDRESS   = $script:red
    $script:MASCARA           = $script:mascara
    $script:CIDR              = $script:bitsMascara
    $script:BROADCAST_ADDRESS = Get-BroadcastAddress $script:red $script:mascara
}

# Helper: Write-Header equivalente con lib\ui
function Write-Header {
    param([string]$Title)
    Write-Separator
    Write-Host "  $Title" -ForegroundColor White
    Write-Separator
}

# Helper: Invoke-Pause equivalente
function Invoke-Pause {
    Write-Host ""
    Write-Host "Presiona Enter para continuar..." -NoNewline
    $null = Read-Host
}

# =============================================================================
#   Funciones de Deteccion y Configuracion
# =============================================================================

function deteccion_interfaces_red {
    # Test-NetworkTools (lib\iface) verifica que Get-NetAdapter / Get-NetIPAddress existan
    if (-not (Test-NetworkTools)) { exit 1 }

    $script:interfaces = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -notlike "127.*" -and
            $_.IPAddress -notlike "169.254.*"
        }

    if ($script:interfaces.Count -eq 0) {
        Write-Host ""
        msg_error "No se detectaron interfaces de red"
        exit 1
    }

    Write-Host ""
    msg_info "Interfaces de red detectadas:"
    Write-Host ""

    $script:listaInterfaces = @()
    $index = 1

    foreach ($adapter in $script:interfaces) {
        $netAdapter = Get-NetAdapter -InterfaceIndex $adapter.InterfaceIndex

        $info = [PSCustomObject]@{
            Numero    = $index
            Interfaz  = $adapter.InterfaceAlias
            Direccion = $adapter.IPAddress
            Estado    = $netAdapter.Status
            IfIndex   = $adapter.InterfaceIndex
        }

        $script:listaInterfaces += $info
        Write-Host ("  {0}) {1,-15} (IP actual: {2})" -f $index, $adapter.InterfaceAlias, $adapter.IPAddress)
        $index++
    }
    Write-Host ""

    while ($true) {
        msg_input "Seleccione el numero de la interfaz para DHCP [1-$($script:listaInterfaces.Count)]: "
        $selection = Read-Host

        if ($selection -match '^\d+$') {
            $selectionNum = [int]$selection

            if ($selectionNum -ge 1 -and $selectionNum -le $script:listaInterfaces.Count) {
                $script:interfazSeleccionada = $script:listaInterfaces[$selectionNum - 1]
                break
            }
        }

        msg_error "Seleccion invalida. Ingrese un numero entre 1 y $($script:listaInterfaces.Count)"
    }

    Write-Host ""
    msg_success "Interfaz seleccionada: $($script:interfazSeleccionada.Interfaz)"
}

# =============================================================================
#   Parametros de usuario
# =============================================================================

function parametros_usuario {
    Write-Host ""
    Write-Header "Configuracion de parametros"

    # --- NOMBRE DEL SCOPE ---
    Write-Host ""
    msg_input "Nombre del Scope [default: RedInterna]: "
    $script:nombreScope = Read-Host
    if ([string]::IsNullOrWhiteSpace($script:nombreScope)) {
        $script:nombreScope = "RedInterna"
    }

    # --- SEGMENTO DE RED ---
    # IP base y CIDR por separado. CidrToMask / Get-NetworkAddress / Get-BroadcastAddress
    # son de lib\net.ps1 y reemplazan calcular_subred_cidr.
    while ($true) {
        Write-Host ""
        msg_info "Ingrese el segmento de red (solo la IP base, sin prefijo)"
        msg_input "Segmento de red: "
        $script:red = Read-Host

        Write-Host ""

        # validar_formato_ip + validar_ip_usable -> Test-ValidIp (lib\net)
        if (-not (Test-ValidIp $script:red)) {
            msg_error "IP invalida o en segmento no usable"
            continue
        }

        # --- CIDR ---
        while ($true) {
            Write-Host ""
            msg_info "Ingrese el prefijo CIDR (ej: 24 para /24 -> 255.255.255.0)"
            msg_input "Prefijo CIDR: "
            $cidrInput = Read-Host

            if ($cidrInput -notmatch '^\d+$') {
                msg_error "El prefijo CIDR debe ser un numero entero"
                continue
            }

            # validar_cidr -> Test-ValidCidr (lib\net) valida 8-30
            if (-not (Test-ValidCidr ([int]$cidrInput))) {
                msg_error "El prefijo CIDR debe estar entre /8 y /30"
                msg_info  "  /31 y /32 no permiten rangos DHCP validos"
                continue
            }

            # calcular_subred_cidr -> CidrToMask + Get-NetworkAddress + Get-BroadcastAddress
            $script:mascara     = CidrToMask ([int]$cidrInput)
            $script:bitsMascara = [int]$cidrInput
            $redCalculada       = Get-NetworkAddress $script:red $script:mascara
            $broadcastCalc      = Get-BroadcastAddress $redCalculada $script:mascara

            # Mostrar resumen equivalente a calcular_subred_cidr
            Write-Host ""
            Write-Separator
            Write-Host "  Informacion de subred /$($script:bitsMascara)" -ForegroundColor White
            Write-Separator
            Write-Host ("  Direccion de red    : {0}" -f $redCalculada)
            Write-Host ("  Mascara             : {0}" -f $script:mascara)
            Write-Host ("  Broadcast           : {0}" -f $broadcastCalc)
            $hostsBits  = 32 - $script:bitsMascara
            $ipsTotales = [math]::Pow(2, $hostsBits)
            Write-Host ("  IPs totales         : {0}" -f $ipsTotales)
            Write-Host ("  IPs usables         : {0}" -f ($ipsTotales - 2))
            Write-Separator
            Write-Host ""

            $script:red = $redCalculada
            break
        }

        # Verificar que la IP ingresada sea la IP de red correcta
        $redCalculada = Get-NetworkAddress $script:red $script:mascara

        if ($script:red -ne $redCalculada) {
            Write-Host ""
            msg_alert "El segmento ingresado no es la IP de red"
            msg_info  "  IP ingresada      : $($script:red)"
            msg_info  "  IP de red correcta: $redCalculada"
            Write-Host ""

            msg_input "Usar la IP de red correcta ($redCalculada)? (s/n): "
            $confirmar = Read-Host

            if ($confirmar -match '^[Ss]$') {
                $script:red = $redCalculada
                msg_success "IP de red actualizada a: $($script:red)"
                break
            } else {
                msg_info "Por favor, ingrese nuevamente el segmento de red"
                continue
            }
        }

        break
    }

    # Sincronizar variables para Test-IpInSegment (lib\net)
    Sync-SubnetVars

    # --- RANGO DE IPs ---
    Write-Host ""
    Write-Header "Rango de IPs"
    Write-Host ""
    msg_info "IMPORTANTE: El servidor tomara automaticamente la IP inicial del rango"
    Write-Host ""

    # IP Inicio
    while ($true) {
        msg_info "Ingrese la IP INICIAL del rango"
        msg_input "IP inicial: "
        $script:ipInicio = Read-Host
        Write-Host ""

        # Test-ValidIp reemplaza validar_formato_ip + validar_ip_usable (lib\net)
        if (-not (Test-ValidIp $script:ipInicio)) {
            msg_error "IP invalida o en segmento no usable"
            continue
        }

        # Test-IpInNetwork reemplaza validar_mismo_segmento (lib\net)
        if (-not (Test-IpInNetwork $script:ipInicio $script:red $script:mascara)) {
            msg_error "La IP $($script:ipInicio) no pertenece al segmento $($script:red)/$($script:bitsMascara)"
            continue
        }

        # Test-IpIsNetwork / Test-IpIsBroadcast reemplazan validar_ip_no_especial (lib\net)
        if (Test-IpIsNetwork $script:ipInicio $script:red) {
            msg_error "No puede usar la direccion de red ($($script:red))"
            continue
        }
        $bcast = Get-BroadcastAddress $script:red $script:mascara
        if (Test-IpIsBroadcast $script:ipInicio $bcast) {
            msg_error "No puede usar la direccion de broadcast ($bcast)"
            continue
        }

        # El servidor toma la IP inicial, los clientes comienzan en la siguiente
        # IpToInt / IntToIp reemplazan ip_a_numero / numero_a_ip (lib\net)
        $script:ipServidorEstatica = $script:ipInicio
        $numRangoClientes          = (IpToInt $script:ipInicio) + 1
        $ipInicioClientes          = IntToIp $numRangoClientes

        # Verificar que la IP de clientes no sea broadcast ni red
        if (Test-IpIsNetwork $ipInicioClientes $script:red) {
            msg_error "La IP calculada para clientes ($ipInicioClientes) es la direccion de red"
            msg_info  "Por favor, ingrese una IP inicial diferente"
            continue
        }
        if (Test-IpIsBroadcast $ipInicioClientes $bcast) {
            msg_error "La IP calculada para clientes ($ipInicioClientes) es la de broadcast"
            msg_info  "Por favor, ingrese una IP inicial menor"
            continue
        }

        $script:ipInicioClientes = $ipInicioClientes

        msg_success "IP inicial validada: $($script:ipInicio)"
        Write-Host ""
        msg_info "IP del servidor DHCP (estatica) : $($script:ipServidorEstatica)"
        msg_info "Rango para clientes inicia en   : $ipInicioClientes"
        Write-Host ""
        break
    }

    # IP Fin
    while ($true) {
        msg_info "Ingrese la IP FINAL del rango"
        msg_input "IP final: "
        $script:ipFin = Read-Host
        Write-Host ""

        if (-not (Test-ValidIp $script:ipFin)) {
            msg_error "IP invalida o en segmento no usable"
            continue
        }

        if (-not (Test-IpInNetwork $script:ipFin $script:red $script:mascara)) {
            msg_error "La IP $($script:ipFin) no pertenece al segmento $($script:red)/$($script:bitsMascara)"
            continue
        }

        if (Test-IpIsNetwork $script:ipFin $script:red) {
            msg_error "No puede usar la direccion de red ($($script:red))"
            continue
        }
        if (Test-IpIsBroadcast $script:ipFin $bcast) {
            msg_error "No puede usar la direccion de broadcast ($bcast)"
            continue
        }

        # validar_rango_ips -> IpToInt comparacion (lib\net)
        if ((IpToInt $script:ipInicio) -ge (IpToInt $script:ipFin)) {
            msg_error "La IP inicial debe ser menor que la IP final"
            msg_info  "  IP Inicial : $($script:ipInicio)  (valor: $(IpToInt $script:ipInicio))"
            msg_info  "  IP Final   : $($script:ipFin)  (valor: $(IpToInt $script:ipFin))"
            continue
        }

        msg_success "IP final validada: $($script:ipFin)"
        break
    }

    # --- GATEWAY (opcional) ---
    Write-Host ""
    Write-Header "Gateway (Opcional)"
    Write-Host ""

    while ($true) {
        msg_input "Ingrese la IP del Gateway (o ENTER para omitir): "
        $script:gateway = Read-Host

        if ([string]::IsNullOrWhiteSpace($script:gateway)) {
            $script:gateway = $null
            Write-Host ""
            msg_info "Gateway: NO CONFIGURADO"
            break
        }

        Write-Host ""

        if (-not (Test-ValidIp $script:gateway)) {
            msg_error "IP de gateway invalida"
            continue
        }

        if (-not (Test-IpInNetwork $script:gateway $script:red $script:mascara)) {
            msg_error "El gateway no pertenece al segmento $($script:red)/$($script:bitsMascara)"
            continue
        }

        if (Test-IpIsNetwork $script:gateway $script:red) {
            msg_error "No puede usar la direccion de red ($($script:red))"
            continue
        }
        if (Test-IpIsBroadcast $script:gateway $bcast) {
            msg_error "No puede usar la direccion de broadcast ($bcast)"
            continue
        }

        msg_success "Gateway validado: $($script:gateway)"
        break
    }

    # --- DNS (opcional) ---
    Write-Host ""
    Write-Header "Servidores DNS (Opcional)"
    Write-Host ""

    while ($true) {
        msg_info "IP del servidor Windows en esta red: $($script:ipServidorEstatica)"
        Write-Host ""
        msg_input "Desea configurar un servidor DNS primario? (s/n): "
        $respuestaDnsPrimario = Read-Host

        if ($respuestaDnsPrimario -match '^[Ss]$') {
            Write-Host ""

            while ($true) {
                msg_input "Ingrese la IP del DNS primario: "
                $script:dnsPrimario = Read-Host
                Write-Host ""

                if (-not (Test-ValidIp $script:dnsPrimario)) {
                    msg_error "IP de DNS invalida"
                    continue
                }

                # Advertir si el DNS primario no pertenece al segmento (no bloquear)
                if (-not (Test-IpInNetwork $script:dnsPrimario $script:red $script:mascara)) {
                    msg_alert "El DNS primario no pertenece al segmento $($script:red)/$($script:bitsMascara)"
                    msg_info  "Los clientes podrian no alcanzar ese servidor DNS"
                    msg_input "Desea usar esta IP de todas formas? (s/n): "
                    $continuar = Read-Host
                    if ($continuar -notmatch '^[Ss]$') { continue }
                }

                msg_success "DNS primario validado: $($script:dnsPrimario)"
                break
            }

            Write-Host ""

            while ($true) {
                msg_input "Desea configurar un servidor DNS secundario? (s/n): "
                $respuestaDnsSecundario = Read-Host

                if ($respuestaDnsSecundario -match '^[Ss]$') {
                    Write-Host ""

                    while ($true) {
                        msg_input "Ingrese la IP del DNS secundario: "
                        $script:dnsSecundario = Read-Host
                        Write-Host ""

                        if (-not (Test-ValidIp $script:dnsSecundario)) {
                            msg_error "IP de DNS invalida"
                            continue
                        }

                        msg_success "DNS secundario validado: $($script:dnsSecundario)"
                        break
                    }
                    break

                } elseif ($respuestaDnsSecundario -match '^[Nn]$') {
                    $script:dnsSecundario = $null
                    Write-Host ""
                    msg_info "DNS secundario: NO CONFIGURADO"
                    break

                } else {
                    msg_error "Respuesta invalida. Ingrese 's' o 'n'"
                }
            }
            break

        } elseif ($respuestaDnsPrimario -match '^[Nn]$') {
            $script:dnsPrimario   = $null
            $script:dnsSecundario = $null
            Write-Host ""
            msg_info "DNS: NO CONFIGURADO"
            break

        } else {
            msg_error "Respuesta invalida. Ingrese 's' o 'n'"
        }
    }

    # --- LEASE TIME ---
    while ($true) {
        Write-Host ""
        msg_input "Lease Time en segundos (ej: 86400 para 24 horas): "
        $leaseSeconds = Read-Host

        if ($leaseSeconds -match '^\d+$' -and [int]$leaseSeconds -gt 0) {
            $script:leaseTime  = New-TimeSpan -Seconds ([int]$leaseSeconds)
            $totalSegundos = [int]$leaseSeconds
            $dias    = [math]::Floor($totalSegundos / 86400)
            $horas   = [math]::Floor(($totalSegundos % 86400) / 3600)
            $minutos = [math]::Floor(($totalSegundos % 3600) / 60)
            $segs    = $totalSegundos % 60

            Write-Host ""
            msg_success "Tiempo configurado: $dias dias, $horas horas, $minutos minutos, $segs segundos"
            break
        } else {
            msg_error "Debe ser un numero entero positivo"
        }
    }

    # --- RESUMEN ---
    Write-Host ""
    Write-Header "Resumen de la configuracion"
    Write-Host ""
    Write-Host "  Nombre del Scope   : $($script:nombreScope)"
    Write-Host "  Segmento de red    : $($script:red)"
    Write-Host "  Mascara de subred  : $($script:mascara) (/$($script:bitsMascara))"
    Write-Host ""
    Write-Host "  IP del servidor    : $($script:ipServidorEstatica)"
    Write-Host ""
    Write-Host "  Rango para clientes:"
    Write-Host "    IP inicial       : $($script:ipInicioClientes)"
    Write-Host "    IP final         : $($script:ipFin)"
    Write-Host ""
    Write-Host "  Gateway            : $(if ($script:gateway) { $script:gateway } else { 'NO CONFIGURADO' })"
    Write-Host ""

    if ($script:dnsPrimario) {
        Write-Host "  DNS primario       : $($script:dnsPrimario)"
        Write-Host "  DNS secundario     : $(if ($script:dnsSecundario) { $script:dnsSecundario } else { 'NO CONFIGURADO' })"
    } else {
        Write-Host "  DNS                : NO CONFIGURADO"
    }

    Write-Host ""
    Write-Host "  Lease Time         : $($script:leaseTime)"
    Write-Host ""
    Write-Separator
    Write-Host ""
}

# =============================================================================
#   Configuracion de la interfaz de red
# =============================================================================

function configurar_interfaz_red {
    Write-Host ""
    Write-Header "Configurando Interfaz de Red"
    Write-Host ""

    $interfazIndex = $script:interfazSeleccionada.IfIndex

    msg_info "Eliminando configuracion IP anterior..."

    Get-NetIPAddress -InterfaceIndex $interfazIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Get-NetRoute -InterfaceIndex $interfazIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    msg_info "Configurando IP estatica: $($script:ipServidorEstatica)..."

    try {
        if ($script:gateway) {
            New-NetIPAddress `
                -InterfaceIndex  $interfazIndex `
                -IPAddress       $script:ipServidorEstatica `
                -PrefixLength    $script:bitsMascara `
                -DefaultGateway  $script:gateway `
                -ErrorAction Stop | Out-Null

            msg_success "IP estatica y gateway configurados"
        } else {
            New-NetIPAddress `
                -InterfaceIndex $interfazIndex `
                -IPAddress      $script:ipServidorEstatica `
                -PrefixLength   $script:bitsMascara `
                -ErrorAction Stop | Out-Null

            msg_success "IP estatica configurada (sin gateway)"
        }
    } catch {
        msg_error "Error al configurar la interfaz de red: $_"
        exit 1
    }

    if ($script:dnsPrimario) {
        try {
            $dnsServers = if ($script:dnsSecundario) {
                @($script:dnsPrimario, $script:dnsSecundario)
            } else {
                $script:dnsPrimario
            }
            Set-DnsClientServerAddress -InterfaceIndex $interfazIndex `
                -ServerAddresses $dnsServers `
                -ErrorAction SilentlyContinue
            msg_success "DNS configurados en la interfaz: $($dnsServers -join ', ')"
        } catch {
            msg_alert "No se pudo configurar DNS en la interfaz: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2

    Write-Host ""
    msg_info "Verificando configuracion de red..."
    Get-NetIPAddress -InterfaceIndex $interfazIndex -AddressFamily IPv4 |
        Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize
    Write-Host ""
}

# =============================================================================
#   Configuracion del servicio DHCP
# =============================================================================

function config_dhcp {
    Write-Host ""
    Write-Header "Configuracion del Servicio DHCP"
    Write-Host ""

    msg_info "Verificando scopes anteriores..."

    $existingScopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue

    if ($existingScopes) {
        msg_alert "Se encontraron $($existingScopes.Count) scope(s) anterior(es)"
        msg_info  "Eliminando TODOS los scopes anteriores..."

        foreach ($scope in $existingScopes) {
            msg_info "  - Eliminando scope: $($scope.Name) (Red: $($scope.ScopeId))"
            Remove-DhcpServerv4Scope -ScopeId $scope.ScopeId -Force -ErrorAction SilentlyContinue
        }

        msg_success "Todos los scopes anteriores han sido eliminados"
    } else {
        msg_info "No se encontraron scopes anteriores"
    }

    Write-Host ""
    msg_info "Creando scope DHCP..."

    try {
        Add-DhcpServerv4Scope `
            -Name          $script:nombreScope `
            -StartRange    $script:ipInicioClientes `
            -EndRange      $script:ipFin `
            -SubnetMask    $script:mascara `
            -LeaseDuration $script:leaseTime `
            -State         Active `
            -ErrorAction Stop | Out-Null

        msg_success "Scope creado exitosamente"
    } catch {
        msg_error "Error al crear scope: $_"
        exit 1
    }

    Write-Host ""
    msg_info "Configurando opciones del scope..."

    if ($script:gateway) {
        try {
            # -Force omite la validacion de AD en servidores Workgroup
            Set-DhcpServerv4OptionValue `
                -ScopeId $script:red `
                -Router  $script:gateway `
                -Force `
                -ErrorAction Stop | Out-Null

            msg_success "Gateway configurado: $($script:gateway)"
        } catch {
            msg_error "Error al configurar gateway: $($_.Exception.Message)"
        }
    } else {
        msg_info "Gateway: NO CONFIGURADO"
    }

    if ($script:dnsPrimario) {
        try {
            # -Force omite la validacion de PTR que Windows realiza sin AD
            $dnsServers = if ($script:dnsSecundario) {
                @($script:dnsPrimario, $script:dnsSecundario)
            } else {
                $script:dnsPrimario
            }

            Set-DhcpServerv4OptionValue `
                -ScopeId   $script:red `
                -DnsServer $dnsServers `
                -Force `
                -ErrorAction Stop | Out-Null

            msg_success "DNS configurados en el scope: $($dnsServers -join ', ')"
        } catch {
            msg_error "Error al configurar DNS en el scope: $($_.Exception.Message)"
            exit 1
        }
    } else {
        msg_info "DNS: NO CONFIGURADO"
    }

    # --- Firewall ---
    Write-Host ""
    msg_info "Configurando firewall..."

    # UDP 67 Inbound — recibir DISCOVER/REQUEST de clientes
    $rule67 = "DHCP Server (UDP-In 67)"
    $existing67 = Get-NetFirewallRule -DisplayName $rule67 -ErrorAction SilentlyContinue
    if ($existing67) { Remove-NetFirewallRule -DisplayName $rule67 -ErrorAction SilentlyContinue }
    New-NetFirewallRule `
        -DisplayName $rule67 `
        -Direction   Inbound `
        -Protocol    UDP `
        -LocalPort   67 `
        -Action      Allow `
        -Profile     Any `
        -ErrorAction SilentlyContinue | Out-Null

    # UDP 68 Outbound — enviar OFFER/ACK a clientes
    $rule68 = "DHCP Server (UDP-Out 68)"
    $existing68 = Get-NetFirewallRule -DisplayName $rule68 -ErrorAction SilentlyContinue
    if ($existing68) { Remove-NetFirewallRule -DisplayName $rule68 -ErrorAction SilentlyContinue }
    New-NetFirewallRule `
        -DisplayName $rule68 `
        -Direction   Outbound `
        -Protocol    UDP `
        -LocalPort   68 `
        -Action      Allow `
        -Profile     Any `
        -ErrorAction SilentlyContinue | Out-Null

    msg_success "Reglas de firewall configuradas (UDP 67 In / UDP 68 Out)"
    Write-Host ""
}

# =============================================================================
#   Iniciar servicio DHCP y verificar opciones
# =============================================================================

function iniciar_dhcp {
    Write-Host ""
    Write-Header "Iniciando Servicio DHCP"
    Write-Host ""

    msg_info "Iniciando servicio DHCPServer..."

    try {
        Restart-Service -Name DHCPServer -Force -ErrorAction Stop
        msg_success "Servicio iniciado correctamente"
        Write-Host ""

        $service = Get-Service -Name DHCPServer
        msg_info "Estado del servicio: $($service.Status)"

        # Verificar que las opciones del scope quedaron registradas
        Write-Host ""
        $scopesActivos = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        foreach ($scope in $scopesActivos) {
            msg_info "Verificando opciones del scope: $($scope.Name)"

            $opcionDNS = Get-DhcpServerv4OptionValue `
                -ScopeId  $scope.ScopeId `
                -OptionId 6 `
                -ErrorAction SilentlyContinue

            if ($opcionDNS) {
                msg_success "Opcion 6 (DNS) registrada: $($opcionDNS.Value)"
            } else {
                msg_alert "El scope '$($scope.Name)' NO tiene la opcion 6 (DNS) configurada"
                msg_info  "Los clientes no recibiran servidor DNS por DHCP"
            }

            $opcionGW = Get-DhcpServerv4OptionValue `
                -ScopeId  $scope.ScopeId `
                -OptionId 3 `
                -ErrorAction SilentlyContinue

            if ($opcionGW) {
                msg_success "Opcion 3 (Gateway) registrada: $($opcionGW.Value)"
            } else {
                msg_info "Opcion 3 (Gateway): NO CONFIGURADA"
            }
        }

    } catch {
        msg_error "Error al iniciar el servicio: $_"
        exit 1
    }
}

# =============================================================================
#   Monitor en tiempo real
# =============================================================================

function monitoreo_info {
    Write-Header "Monitor de Servicio DHCP"
    Write-Host ""
    msg_info "Actualizacion: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ""

    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue

    if ($scopes) {
        foreach ($scope in $scopes) {
            Write-Host "  Scope  : $($scope.Name)"
            Write-Host "  Red    : $($scope.ScopeId)"
            Write-Host "  Rango  : $($scope.StartRange) - $($scope.EndRange)"
            Write-Host ""

            # Obtener IP del servidor en el mismo segmento que el scope
            $octetsScope = $scope.ScopeId.ToString().Split('.')
            $prefijoScope = "$($octetsScope[0]).$($octetsScope[1]).$($octetsScope[2])."

            $serverIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.IPAddress -notlike "127.*" -and
                    $_.IPAddress -notlike "169.254.*" -and
                    $_.IPAddress.StartsWith($prefijoScope)
                } |
                Select-Object -ExpandProperty IPAddress -First 1

            if ($serverIP) {
                msg_info "IP del servidor DHCP: $serverIP"
                Write-Host ""
            }

            try {
                $leases = @(Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction Stop)

                if ($leases.Count -gt 0) {
                    msg_info "Concesiones activas: $($leases.Count)"
                    Write-Host ""

                    foreach ($lease in $leases) {
                        $estado   = if ($lease.AddressState -eq "Active") { "ACTIVO" } else { $lease.AddressState }
                        $hostname = if ($lease.HostName) { $lease.HostName } else { "Sin nombre" }
                        $expira   = if ($lease.LeaseExpiryTime) { $lease.LeaseExpiryTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }

                        Write-Host "  IP     : $($lease.IPAddress)"
                        Write-Host "    Host   : $hostname"
                        Write-Host "    MAC    : $($lease.ClientId)"
                        Write-Host "    Estado : $estado"
                        Write-Host "    Expira : $expira"
                        Write-Host ""
                    }
                } else {
                    msg_info "Sin concesiones activas"
                    Write-Host ""
                }
            } catch {
                msg_error "Error al obtener concesiones: $_"
                Write-Host ""
            }
        }
    } else {
        msg_info "No hay scopes configurados"
        Write-Host ""
    }
}

# =============================================================================
#   Funciones del Menu Principal
# =============================================================================

function verificar_instalacion {
    Write-Host ""
    Write-Header "Verificando instalacion del servicio DHCP"
    Write-Host ""

    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

    if ($dhcpFeature.Installed) {
        msg_success "Estado: INSTALADO"
        Write-Host ""

        $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue

        if ($service) {
            Write-Host "  Servicio DHCPServer:"
            Write-Host "    Estado : $($service.Status)"
            Write-Host "    Inicio : $($service.StartType)"
        }
    } else {
        msg_alert "Estado: NO INSTALADO"
        Write-Host ""
        msg_info "Use la opcion 2 del menu para instalar el servicio"
    }
    Write-Host ""
}

function instalar_y_configurar_servicio {
    Write-Host ""
    Write-Header "INSTALACION Y CONFIGURACION COMPLETA"
    Write-Host ""

    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

    if (-not $dhcpFeature.Installed) {
        msg_info "Instalando rol DHCP..."
        msg_info "Esto puede tardar varios minutos..."
        Write-Host ""

        try {
            Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop | Out-Null

            Write-Host ""
            msg_success "Rol DHCP instalado correctamente"
            Write-Host ""

            Set-Service -Name DHCPServer -StartupType Automatic

            # Grupos de seguridad DHCP
            netsh dhcp add securitygroups | Out-Null

            # Registrar en AD solo si hay dominio
            $cs = Get-WmiObject Win32_ComputerSystem
            if ($cs.PartOfDomain) {
                try {
                    Add-DhcpServerInDC -DnsName $cs.DNSHostName -ErrorAction Stop
                    msg_success "Servidor DHCP registrado en Active Directory"
                } catch {
                    msg_alert "No se pudo registrar en AD: $_"
                    msg_info  "Puedes registrarlo manualmente con: Add-DhcpServerInDC"
                }
            } else {
                msg_info "Servidor standalone — registro en AD omitido"
            }

        } catch {
            Write-Host ""
            msg_error "Error durante la instalacion: $_"
            return
        }
    } else {
        msg_info "El servicio DHCP ya esta instalado"
        Write-Host ""
    }

    msg_info "Iniciando configuracion..."
    Write-Host ""

    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp

    Write-Host ""
    Write-Separator
    msg_success "Instalacion y configuracion completada"
    Write-Separator
    Write-Host ""
}

function nueva_configuracion {
    Write-Host ""
    Write-Header "Nueva configuracion del servicio DHCP"
    Write-Host ""

    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

    if (-not $dhcpFeature.Installed) {
        msg_error "El servicio DHCP no esta instalado"
        Write-Host ""
        msg_info "Use la opcion 2 del menu para instalar"
        return
    }

    msg_info "Iniciando configuracion..."

    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp

    Write-Host ""
    Write-Separator
    msg_success "Configuracion Completada"
    Write-Separator
    Write-Host ""
}

function reiniciar_servicio {
    Write-Header "Reiniciando servicio DHCP"

    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

    if (-not $dhcpFeature.Installed) {
        msg_error "El servicio no esta instalado"
        return
    }

    try {
        Restart-Service -Name DHCPServer -Force -ErrorAction Stop
        msg_success "Servicio reiniciado correctamente"
        Write-Host ""

        $service = Get-Service -Name DHCPServer
        msg_info "Estado: $($service.Status)"
    } catch {
        msg_error "Error al reiniciar el servicio"
        msg_error "Detalle: $_"
    }
}

function modo_monitor {
    Write-Host ""
    msg_info "Iniciando modo monitor..."
    msg_info "Presiona Ctrl+C para salir"
    Write-Host ""
    Start-Sleep -Seconds 2

    while ($true) {
        Clear-Host
        monitoreo_info
        Start-Sleep -Seconds 5
    }
}

function ver_configuracion_actual {
    Write-Host ""
    Write-Header "Configuracion Actual del Servidor"
    Write-Host ""

    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

    if (-not $dhcpFeature.Installed) {
        msg_alert "El servicio DHCP no esta instalado"
        return
    }

    Write-Host "1. Estado del Servicio:"
    Write-Separator

    $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue

    if ($service) {
        if ($service.Status -eq 'Running') {
            msg_success "Estado: ACTIVO"
        } else {
            msg_alert "Estado: $($service.Status)"
        }
        if ($service.StartType -eq 'Automatic') {
            msg_success "Inicio automatico: HABILITADO"
        } else {
            msg_alert "Inicio automatico: $($service.StartType)"
        }
    } else {
        msg_alert "Servicio no encontrado"
    }
    Write-Host ""

    Write-Host "2. Configuracion DHCP:"
    Write-Separator

    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue

    if ($scopes) {
        foreach ($scope in $scopes) {
            Write-Host "  Nombre del Scope   : $($scope.Name)"
            Write-Host "  ScopeId            : $($scope.ScopeId)"
            Write-Host "  Mascara            : $($scope.SubnetMask)"
            Write-Host "  Rango              : $($scope.StartRange) - $($scope.EndRange)"
            Write-Host "  Estado             : $($scope.State)"
            Write-Host "  Lease Duration     : $($scope.LeaseDuration)"
            Write-Host ""

            $options    = Get-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
            $gatewayOpt = ($options | Where-Object { $_.OptionId -eq 3 }).Value
            $dnsOpt     = ($options | Where-Object { $_.OptionId -eq 6 }).Value

            if ($gatewayOpt) { Write-Host "  Gateway            : $gatewayOpt" }
            else             { msg_info "Gateway: NO CONFIGURADO" }

            if ($dnsOpt) { Write-Host "  DNS                : $dnsOpt" }
            else         { msg_info "DNS: NO CONFIGURADO" }

            Write-Host ""
        }
    } else {
        msg_info "No hay scopes configurados"
    }
    Write-Host ""

    Write-Host "3. Estadisticas:"
    Write-Separator

    if ($scopes) {
        foreach ($scope in $scopes) {
            Write-Host "  Scope: $($scope.Name)"

            try {
                $leases = @(Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction Stop)

                if ($leases.Count -gt 0) {
                    $totalLeases  = $leases.Count
                    $activeLeases = @($leases | Where-Object { $_.AddressState -eq "Active" }).Count

                    Write-Host "    Concesiones totales : $totalLeases"
                    Write-Host "    Concesiones activas : $activeLeases"
                    Write-Host ""

                    foreach ($lease in $leases) {
                        $estado   = if ($lease.AddressState -eq "Active") { "ACTIVO" } else { $lease.AddressState }
                        $hostname = if ($lease.HostName) { $lease.HostName } else { "Sin nombre" }
                        Write-Host "    - IP: $($lease.IPAddress) | Estado: $estado | Host: $hostname"
                    }
                } else {
                    msg_info "Sin concesiones"
                }
            } catch {
                msg_error "Error al obtener concesiones: $_"
            }
            Write-Host ""
        }
    } else {
        msg_info "Sin scopes configurados"
    }
    Write-Host ""
}

# =============================================================================
#   Menu Principal
# =============================================================================

function main_menu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Header "Gestor de Servicio DHCP"
        Write-Host ""
        Write-Host "Seleccione una opcion:"
        Write-Host ""
        Write-Host "  1) Verificar instalacion"
        Write-Host "  2) Instalar y configurar servicio"
        Write-Host "  3) Nueva configuracion (requiere instalacion previa)"
        Write-Host "  4) Reiniciar servicio"
        Write-Host "  5) Monitor de concesiones"
        Write-Host "  6) Ver configuracion actual"
        Write-Host "  7) Salir"
        Write-Host ""
        msg_input "Opcion: "
        $OP = Read-Host

        switch ($OP) {
            "1" { verificar_instalacion }
            "2" { instalar_y_configurar_servicio }
            "3" { nueva_configuracion }
            "4" { reiniciar_servicio }
            "5" { modo_monitor }
            "6" { ver_configuracion_actual }
            "7" {
                Write-Host ""
                msg_info "Saliendo del programa..."
                exit 0
            }
            default {
                Write-Host ""
                msg_error "Opcion invalida"
            }
        }

        Write-Host ""
        Invoke-Pause
    }
}

# =============================================================================
#   Punto de Entrada
# =============================================================================

main_menu