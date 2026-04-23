#
# ac_mfa.ps1
#
# Modulo de Autenticacion Multi-Factor (MFA) para AC Manager
# Adaptado de la Practica 9.
#

$script:MULTIOTP_BASE = "C:\multiOTP"
$script:MULTIOTP_EXE_DIR = "$script:MULTIOTP_BASE\windows"
$script:MULTIOTP_EXE = "$script:MULTIOTP_EXE_DIR\multiotp.exe"
$script:MULTIOTP_QRCODES = "$script:MULTIOTP_BASE\qrcodes"
$script:MULTIOTP_URL = "https://download.multiotp.net/multiotp.zip"

$script:MULTIOTP_SERVER_SECRET = "P09Secret2024"
$script:MULTIOTP_IIS_PORT = 8112
$script:MULTIOTP_WEBSERVICE = "$script:MULTIOTP_BASE\webservice"
$script:MULTIOTP_IIS_SITENAME = "multiOTP-Service"

# ---------------------------------------------------------------------------
# Sync-ACNTPConfiguration
# ---------------------------------------------------------------------------
function Sync-ACNTPConfiguration {
    draw_header "Sincronizacion NTP (Requisito MFA)"
    Write-Log INFO "=== INICIO CONFIGURACION NTP ==="

    msg_info "Verificando conectividad (ping 8.8.8.8)..."
    if (-not (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        msg_alert "Sin conectividad a internet. Hora actual: $(Get-Date)"
        return $false
    }

    if (-not (Get-NetFirewallRule -DisplayName "NTP-Outbound-UDP123" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "NTP-Outbound-UDP123" -Direction Outbound -Protocol UDP -RemotePort 123 -Action Allow -ErrorAction SilentlyContinue | Out-Null
        msg_success "Regla de firewall NTP creada (UDP 123 Out)."
    }

    $w32Params = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
    $w32Config = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config"
    try {
        Set-ItemProperty -Path $w32Params -Name "Type" -Value "NTP" -ErrorAction Stop
        Set-ItemProperty -Path $w32Params -Name "NtpServer" -Value "time.windows.com,0x9 0.pool.ntp.org,0x9" -ErrorAction Stop
        Set-ItemProperty -Path $w32Config -Name "AnnounceFlags" -Value 5 -ErrorAction Stop
    }
    catch { msg_error "Error configurando registro NTP: $_" }

    msg_info "Reiniciando servicio w32time..."
    try {
        Stop-Service w32time -Force -ErrorAction Stop | Out-Null; Start-Sleep 2
        w32tm /register 2>&1 | Out-Null
        Start-Service w32time -ErrorAction Stop | Out-Null; Start-Sleep 5
    }
    catch { msg_alert "Error reiniciando w32time." }

    msg_info "Forzando sincronizacion NTP..."
    $resyncOut = w32tm /resync /force 2>&1
    $status = w32tm /query /status 2>&1 -join " "

    if (($status -match "Stratum: [1-4]" -or $status -match "Estrato: [1-4]") -and ($status -notmatch "LOCL")) {
        msg_success "NTP sincronizado con exito."
        Write-Log SUCCESS "NTP Sincronizado."
        return $true
    }
    elseif ($resyncOut -match "sincroniz|successful|correcto") {
        msg_success "NTP reporto sincronizacion manual exitosa."
        return $true
    }
    else {
        msg_alert "NTP sigue mostrando LOCL. Confirma la hora: $(Get-Date)"
        return $false
    }
}

# ---------------------------------------------------------------------------
# Test-MultiOTPInstalled
# ---------------------------------------------------------------------------
function Test-MultiOTPInstalled {
    if (-not (Test-Path $script:MULTIOTP_EXE_DIR)) { return $false }
    if (-not (Test-Path $script:MULTIOTP_EXE)) { return $false }
    return $true
}

# ---------------------------------------------------------------------------
# Install-ACMultiOTP
# ---------------------------------------------------------------------------
function Install-ACMultiOTP {
    draw_header "Instalacion de multiOTP Servidor"
    if (Test-MultiOTPInstalled) {
        msg_success "multiOTP ya se encuentra instalado."
        return $true
    }

    $zipPath = "$env:TEMP\multiotp.zip"
    msg_info "Descargando multiOTP desde internet..."
    try {
        Invoke-WebRequest -Uri $script:MULTIOTP_URL -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        msg_success "Descarga completada."
    }
    catch { msg_error "Error descargando: $_"; return $false }

    msg_info "Extrayendo directorio (esto instalara PHP base)..."
    try {
        if (-not (Test-Path $script:MULTIOTP_BASE)) { New-Item -ItemType Directory -Path $script:MULTIOTP_BASE -Force | Out-Null }
        Expand-Archive -Path $zipPath -DestinationPath $script:MULTIOTP_BASE -Force -ErrorAction Stop
        msg_success "Extraccion completada en $script:MULTIOTP_BASE."
    }
    catch { msg_error "Error extrayendo: $_"; return $false }

    # Setup web service for Client Validations
    if (-not (Test-Path $script:MULTIOTP_WEBSERVICE)) { New-Item -ItemType Directory -Path $script:MULTIOTP_WEBSERVICE -Force | Out-Null }
    
    $phpScript = @"
<?php
define('MULTIOTP_EXE', 'C:\\multiOTP\\windows\\multiotp.exe');
define('MULTIOTP_WORKDIR', 'C:\\multiOTP\\windows');
define('SERVER_SECRET', '$script:MULTIOTP_SERVER_SECRET');

header("Content-Type: text/plain");
`$body = file_get_contents('php://input');
`$data = [];
if (!empty(`$body)) {
    if (strpos(`$_SERVER['CONTENT_TYPE'] ?? '', 'application/json') !== false) {
        `$data = json_decode(`$body, true) ?? [];
    } else { parse_str(`$body, `$data); }
} else { `$data = `$_GET; }

`$secret  = `$data['secret']  ?? '';
`$user    = `$data['user']    ?? '';
`$otp     = `$data['otp']     ?? '';
`$command = `$data['command'] ?? 'check';

if (`$secret !== SERVER_SECRET) { http_response_code(403); echo "Error: Invalid secret\n"; exit; }
if (`$command === 'ping') { echo "multiOTP server OK\n"; exit; }

if (`$command === 'check' || `$command === '') {
    if (empty(`$user) || empty(`$otp)) { http_response_code(400); echo "Error: user and otp required\n"; exit; }
    `$user = preg_replace('/[^a-zA-Z0-9_\-\.]/', '', `$user);
    `$otp  = preg_replace('/[^0-9]/', '', `$otp);
    if (empty(`$user) || empty(`$otp)) { http_response_code(400); echo "Error: invalid chars\n"; exit; }
    `$cmd = sprintf('cd /d "%s" && "%s" "%s" "%s" 2>&1', MULTIOTP_WORKDIR, MULTIOTP_EXE, `$user, `$otp);
    exec(`$cmd, `$output, `$exitCode);
    if (`$exitCode === 0) { echo "OK\n"; }
    elseif (`$exitCode === 7) { echo "Error: User not found (exit=7)\n"; http_response_code(200); }
    else { echo "Error: Auth failed (exit=`$exitCode)\n"; http_response_code(401); }
    exit;
}
http_response_code(400); echo "Error: Unknown command\n";
?>
"@
    $phpScript | Out-File "$script:MULTIOTP_WEBSERVICE\index.php" -Encoding UTF8 -Force
    @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <defaultDocument><files><add value="index.php"/></files></defaultDocument>
    <directoryBrowse enabled="false"/>
  </system.webServer>
</configuration>
'@ | Out-File "$script:MULTIOTP_WEBSERVICE\web.config" -Encoding UTF8 -Force

    msg_info "Configurando caracteristicas IIS..."
    foreach ($f in @("Web-Server", "Web-CGI", "Web-Mgmt-Console")) {
        $feat = Get-WindowsFeature -Name $f -EA SilentlyContinue
        if ($null -eq $feat -or $feat.InstallState -ne "Installed") {
            Install-WindowsFeature -Name $f -IncludeManagementTools -EA SilentlyContinue | Out-Null
        }
    }

    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $poolName = "multiOTPPool"
    if (-not (Test-Path "IIS:\AppPools\$poolName")) { New-WebAppPool -Name $poolName | Out-Null }
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name processModel -Value @{ userName = "LocalSystem"; password = ""; logonType = 0 }
    
    if (Get-Website -Name $script:MULTIOTP_IIS_SITENAME -EA SilentlyContinue) {
        Remove-Website -Name $script:MULTIOTP_IIS_SITENAME -EA SilentlyContinue
    }
    
    try {
        New-Website -Name $script:MULTIOTP_IIS_SITENAME -Port $script:MULTIOTP_IIS_PORT -PhysicalPath $script:MULTIOTP_WEBSERVICE -ApplicationPool $poolName -Force | Out-Null
        msg_success "Sitio IIS '$script:MULTIOTP_IIS_SITENAME' en puerto $script:MULTIOTP_IIS_PORT configurado."
    }
    catch { msg_error "Error IIS Website: $_" }

    $phpExe = "$script:MULTIOTP_EXE_DIR\php\php-cgi.exe"
    if (Test-Path $phpExe) {
        & "$env:SystemRoot\System32\inetsrv\appcmd.exe" unlock config "-section:system.webServer/handlers" 2>&1 | Out-Null
        try {
            $ex = Get-WebConfiguration "system.webServer/fastCgi/application" -PSPath "IIS:\" -EA SilentlyContinue | Where-Object { $_.fullPath -eq $phpExe }
            if (-not $ex) { Add-WebConfiguration -Filter "system.webServer/fastCgi" -Value @{ fullPath = $phpExe; maxInstances = 4 } -PSPath "IIS:\" -EA Stop }
            $exH = Get-WebConfigurationProperty -PSPath "IIS:\Sites\$script:MULTIOTP_IIS_SITENAME" -Filter "system.webServer/handlers/add[@name='PHP_via_FastCGI']" -Name "name" -EA SilentlyContinue
            if (-not $exH) {
                Add-WebConfigurationProperty -PSPath "IIS:\Sites\$script:MULTIOTP_IIS_SITENAME" -Filter "system.webServer/handlers" -Name "." -Value @{ name = "PHP_via_FastCGI"; path = "*.php"; verb = "GET,HEAD,POST"; modules = "FastCgiModule"; scriptProcessor = $phpExe; resourceType = "Unspecified" } -EA Stop
            }
            msg_success "PHP FastCGI configurado correctamente en IIS."
        }
        catch { msg_alert "Error FastCGI: $_" }
        
        try {
            $acl = Get-Acl "C:\multiOTP"
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("IIS_IUSRS", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
            $acl.AddAccessRule($rule)
            Set-Acl "C:\multiOTP" $acl
        }
        catch {}
    }
    else {
        msg_alert "PHP (php-cgi.exe) no fue encontrado en el subdirectorio de multiOTP."
    }

    if (-not (Get-NetFirewallRule -DisplayName "multiOTP-HTTP-$script:MULTIOTP_IIS_PORT" -EA SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "multiOTP-HTTP-$script:MULTIOTP_IIS_PORT" -Direction Inbound -Protocol TCP -LocalPort $script:MULTIOTP_IIS_PORT -Action Allow -Profile Any -Description "MFA API" | Out-Null
    }

    Start-Website -Name $script:MULTIOTP_IIS_SITENAME -EA SilentlyContinue
    msg_success "multiOTP instalado y servicio API web disponible."
    Write-Log SUCCESS "Install-ACMultiOTP ejecutado."
    return $true
}

# ---------------------------------------------------------------------------
# Register-UserMFA
# ---------------------------------------------------------------------------
function Register-UserMFA {
    param([string]$SamAccount, [switch]$Force)

    if (-not (Test-MultiOTPInstalled)) { msg_error "multiOTP no esta instalado."; return $false }
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$SamAccount'" -SearchBase $script:AD_DOMAIN_DN -EA SilentlyContinue)) { msg_error "Usuario no existe."; return $false }

    msg_info "Procesando $SamAccount..."
    $dirAnterior = Get-Location; Set-Location $script:MULTIOTP_EXE_DIR
    & $script:MULTIOTP_EXE -check-user $SamAccount 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        if (-not $Force) {
            $regenerar = Read-Confirm -Prompt "Token MFA ya existe. Regenerar" -Default 'N'
            if (-not $regenerar) { Set-Location $dirAnterior; return $true }
        }
        & $script:MULTIOTP_EXE -delete $SamAccount | Out-Null
    }

    & $script:MULTIOTP_EXE -fastcreatenopin $SamAccount 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 11 -and $LASTEXITCODE -ne 0) { msg_error "Fallo creacion del token (Exit $LASTEXITCODE)."; Set-Location $dirAnterior; return $false }
    
    if (-not (Test-Path $script:MULTIOTP_QRCODES)) { New-Item -ItemType Directory -Path $script:MULTIOTP_QRCODES -Force | Out-Null }
    
    $pngPath = "$script:MULTIOTP_QRCODES\$SamAccount.png"
    & $script:MULTIOTP_EXE -qrcode $SamAccount $pngPath 2>&1 | Out-Null
    
    $rawOutput = & $script:MULTIOTP_EXE -urllink $SamAccount 2>&1
    $otpauthUri = $rawOutput | Where-Object { $_ -match "otpauth://" } | Select-Object -First 1
    if (-not $otpauthUri -and "$rawOutput" -match "otpauth://") { $otpauthUri = ($rawOutput | Select-Object -First 1).ToString().Trim() }
    
    Set-Location $dirAnterior

    msg_success "Generado TOTP QR para $SamAccount."
    
    if ($otpauthUri -and $otpauthUri -match "secret=([A-Z2-7=]+)") {
        $base32Secret = $Matches[1]
        try { Set-ADUser -Identity $SamAccount -Replace @{employeeNumber = $base32Secret } -EA Stop } catch { msg_alert "No se guardo el employeeNumber." }
    }
    
    $txtPath = "$script:MULTIOTP_QRCODES\$SamAccount.txt"
    @"
MFA - $SamAccount ($script:AD_DOMAIN)
QR PNG: $pngPath
URI   : $otpauthUri
"@ | Out-File $txtPath -Encoding UTF8 -Force
    msg_info "Resumen guardado en $txtPath"
    return $true
}

# ---------------------------------------------------------------------------
# Invoke-MFAMenu
# ---------------------------------------------------------------------------
function Invoke-MFAMenu {
    while ($true) {
        Show-Banner
        draw_header "MFA - Autenticacion Multi-Factor"

        Write-Host "  Estado: " -NoNewline
        if (Test-MultiOTPInstalled) { Write-Host "Instalado" -ForegroundColor Green } else { Write-Host "No activo" -ForegroundColor Red }
        Write-Host ""
        
        Write-Host "    [1]  Sincronizar NTP (Requisito Obligatorio)"
        Write-Host "    [2]  Instalar Servidor SDK MultiOTP (Local IIS)"
        Write-Host "    [3]  Generar/Reestablecer QR MFA de un usuario"
        Write-Host "    [4]  Registrar MFA a todos los usuarios del dominio"
        Write-Host "    [5]  Instalar Credential Provider (requiere GUI en servidor)"
        Write-Host "    [6]  Configurar registro CP post-instalacion"
        Write-Host "    [7]  Verificar estado MFA del sistema"
        Write-Host "    [0]  Volver"
        Write-Host ""

        msg_input "Opcion: "
        $op = Read-Host

        switch ($op.Trim()) {
            "1" { Sync-ACNTPConfiguration | Out-Null; msg_pause }
            "2" { Install-ACMultiOTP | Out-Null; msg_pause }
            "3" {
                $sam = Read-InputLoop -Prompt "Usuario" -Validator { param($v) $v.Length -gt 0 }
                if ($sam) { Register-UserMFA -SamAccount $sam }
                msg_pause
            }
            "4" {
                draw_header "Registro masivo MFA - todos los usuarios"
                if (-not (Test-MultiOTPInstalled)) {
                    msg_error "Instala multiOTP primero (opcion 2)."
                    msg_pause; break
                }
                if (-not $script:AD_DOMAIN_DN) {
                    msg_error "Conecta al dominio primero (opcion C del menu principal)."
                    msg_pause; break
                }
                msg_alert "Esto genera un token TOTP para cada usuario de GRP_Cuates y GRP_NoCuates."
                msg_alert "El QR y el URI se guardan en C:\multiOTP\qrcodes\<usuario>.png/.txt"
                Write-Host ""
                $confirm = Read-Confirm -Prompt "Continuar con el registro masivo" -Default "S"
                if (-not $confirm) { msg_pause; break }

                $targets = @()
                foreach ($grp in @("GRP_Cuates", "GRP_NoCuates")) {
                    try {
                        $members = Get-ADGroupMember $grp -EA Stop |
                                   Where-Object { $_.objectClass -eq "user" }
                        $targets += $members
                    } catch { msg_alert "No se pudo leer $grp" }
                }

                if ($targets.Count -eq 0) {
                    msg_alert "No hay usuarios en GRP_Cuates ni GRP_NoCuates."
                    msg_pause; break
                }

                $ok = 0; $skip = 0; $fail = 0
                foreach ($u in $targets) {
                    $result = Register-UserMFA -SamAccount $u.SamAccountName -Force
                    if ($result) { $ok++ } else { $fail++ }
                }
                msg_success "Registro masivo completado: OK=$ok | Fallidos=$fail"
                msg_info "QRs en: C:\multiOTP\qrcodes"
                msg_pause
            }
            "5" {
                draw_header "Instalar Credential Provider (GUI)"
                msg_alert "TOMA UN SNAPSHOT DE LA VM ANTES DE CONTINUAR."
                msg_alert "Si el CP falla, el servidor puede quedar inaccesible por RDP."
                Write-Host ""

                $cp_url = "https://download.multiotp.net/credential-provider/legacy/multiOTPCredentialProvider-5.8.1.1.exe"
                $cp_dest = "$env:TEMP\multiOTPCredentialProvider.exe"
                $cp_installed = Test-Path "C:\Windows\System32\multiOTPCredentialProvider.dll"

                if ($cp_installed) {
                    msg_success "El Credential Provider ya esta instalado (DLL detectada)."
                    $reinstall = Read-Confirm -Prompt "Reinstalar de todas formas" -Default "N"
                    if (-not $reinstall) { msg_pause; break }
                }

                $snapshot = Read-Confirm -Prompt "Confirmo que tome un snapshot de la VM" -Default "N"
                if (-not $snapshot) {
                    msg_alert "Operacion cancelada. Toma el snapshot antes de continuar."
                    msg_pause; break
                }

                msg_process "Descargando Credential Provider..."
                try {
                    Invoke-WebRequest -Uri $cp_url -OutFile $cp_dest -UseBasicParsing -ErrorAction Stop
                    msg_success "Descargado: $cp_dest"
                } catch {
                    msg_error "Fallo la descarga: $_"
                    msg_info "Descarga manual desde: $cp_url"
                    msg_pause; break
                }

                msg_info "Abriendo el instalador. Sigue los pasos de la GUI."
                msg_info "Cuando termine, vuelve aqui y ejecuta la opcion [6]."
                Write-Host ""
                try {
                    Start-Process -FilePath $cp_dest -Wait -ErrorAction Stop
                    msg_success "Instalador finalizado."
                } catch {
                    msg_error "No se pudo lanzar el instalador: $_"
                }
                msg_pause
            }
            "6" {
                draw_header "Configurar registro CP post-instalacion"

                $cpDLL = "C:\Windows\System32\multiOTPCredentialProvider.dll"
                if (-not (Test-Path $cpDLL)) {
                    msg_error "DLL del Credential Provider no encontrada en $cpDLL"
                    msg_info "Instala primero el CP (opcion 5)."
                    msg_pause; break
                }

                msg_info "Configurando el registro de Windows para multiOTP CP..."

                $serverHost = "127.0.0.1"
                $serverPort = $script:MULTIOTP_IIS_PORT
                $secret     = $script:MULTIOTP_SERVER_SECRET

                try {
                    $cpRegPath = "HKLM:\SOFTWARE\multiOTP"
                    if (-not (Test-Path $cpRegPath)) {
                        New-Item -Path $cpRegPath -Force | Out-Null
                    }
                    Set-ItemProperty -Path $cpRegPath -Name "server_ip"     -Value $serverHost  -Type String  -EA Stop
                    Set-ItemProperty -Path $cpRegPath -Name "server_port"   -Value $serverPort  -Type DWord   -EA Stop
                    Set-ItemProperty -Path $cpRegPath -Name "shared_secret" -Value $secret      -Type String  -EA Stop
                    Set-ItemProperty -Path $cpRegPath -Name "display_login" -Value 1            -Type DWord   -EA Stop
                    Set-ItemProperty -Path $cpRegPath -Name "no_Internet_required" -Value 1     -Type DWord   -EA Stop

                    msg_success "Registro configurado:"
                    msg_info "  Server : $serverHost`:$serverPort"
                    msg_info "  Secret : $secret"
                    Write-Log SUCCESS "CP registry configured: $serverHost : $serverPort"
                } catch {
                    msg_error "Error configurando registro: $_"
                }

                # Reiniciar el servicio de credenciales para aplicar cambios
                try {
                    Stop-Service -Name "Credential Manager" -Force -EA SilentlyContinue
                    Start-Sleep -Seconds 2
                    Start-Service -Name "Credential Manager" -EA SilentlyContinue
                    msg_success "Servicio de credenciales reiniciado."
                } catch {}

                msg_info "Para probar: cierra sesion y vuelve a iniciar. El CP debe pedir codigo MFA."
                msg_pause
            }
            "7" {
                draw_header "Estado MFA del sistema"
                $mfaInstalled = Test-MultiOTPInstalled
                $cpInstalled  = Test-Path "C:\Windows\System32\multiOTPCredentialProvider.dll"

                msg_info "multiOTP EXE  : $(if ($mfaInstalled) { 'Instalado' } else { 'NO instalado' })"
                msg_info "Credential CP : $(if ($cpInstalled)  { 'Instalado' } else { 'NO instalado' })"

                if ($mfaInstalled -and $script:AD_DOMAIN_DN) {
                    # Contar usuarios con QR generado
                    $qrDir = $script:MULTIOTP_QRCODES
                    if (Test-Path $qrDir) {
                        $qrCount = @(Get-ChildItem $qrDir -Filter "*.png" -EA SilentlyContinue).Count
                        msg_info "Usuarios con QR : $qrCount"
                    }

                    # Estado de sincronizacion NTP
                    $ntpStatus = w32tm /query /status 2>&1 | Select-Object -First 5
                    msg_info "NTP Status:"
                    $ntpStatus | ForEach-Object { Write-Host "  $_" }
                }
                msg_pause
            }
            "0" { return }
            default { msg_alert "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}