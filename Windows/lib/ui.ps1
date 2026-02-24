# =============================================================================
# ui.ps1 — Utilidades de interfaz: colores, mensajes, separador
# Uso: . .\ui.ps1
# =============================================================================

function Write-Separator {
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
}

function msg_success { param([string]$msg) Write-Host "[ " -NoNewline; Write-Host "EXITO " -ForegroundColor Green -NoNewline; Write-Host "] $msg" }
function msg_error   { param([string]$msg) Write-Host "[ " -NoNewline; Write-Host "ERROR " -ForegroundColor Red -NoNewline; Write-Host "] $msg" }
function msg_info    { param([string]$msg) Write-Host "[ " -NoNewline; Write-Host "INFO  " -ForegroundColor Blue -NoNewline; Write-Host "] $msg" }
function msg_alert   { param([string]$msg) Write-Host "[ " -NoNewline; Write-Host "ALERT " -ForegroundColor Yellow -NoNewline; Write-Host "] $msg" }
function msg_process { param([string]$msg) Write-Host "[  " -NoNewline; Write-Host "---  " -ForegroundColor Cyan -NoNewline; Write-Host "] $msg" }
function msg_input   { param([string]$msg) Write-Host "-> $msg" -ForegroundColor Cyan -NoNewline }