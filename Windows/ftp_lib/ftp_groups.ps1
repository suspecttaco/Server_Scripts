# =============================================================================
# ftp_lib/ftp_groups.ps1 — CRUD de grupos FTP y permisos de directorios
# =============================================================================

function Load-FtpGroups {
    $script:FTP_GROUPS = @()
    if (-not (Test-Path $script:FTP_GROUPS_FILE)) { return }
    Get-Content $script:FTP_GROUPS_FILE | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $script:FTP_GROUPS += $line
        }
    }
}

function Save-FtpGroups {
    if (-not (Test-Path $script:FTP_ROOT)) {
        New-Item -ItemType Directory -Path $script:FTP_ROOT -Force | Out-Null
    }
    $script:FTP_GROUPS | Set-Content $script:FTP_GROUPS_FILE
}

function Request-InitialGroups {
    if ((Test-Path $script:FTP_GROUPS_FILE) -and (Get-Content $script:FTP_GROUPS_FILE | Where-Object { $_.Trim() })) {
        Load-FtpGroups
        msg_info "Grupos existentes: $($script:FTP_GROUPS -join ', ')"
        return
    }

    Write-Separator
    msg_info "Define los grupos FTP (al menos uno). Linea vacia para terminar."
    Write-Separator

    $script:FTP_GROUPS = @()
    while ($true) {
        $grupo = Read-Input "Nombre del grupo (Enter para terminar): "
        if ([string]::IsNullOrWhiteSpace($grupo)) {
            if ($script:FTP_GROUPS.Count -eq 0) { msg_error "Al menos un grupo requerido"; continue }
            break
        }
        if ($grupo -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
            msg_error "Nombre invalido: solo minusculas, numeros, _ y -"
            continue
        }
        if ($script:FTP_GROUPS -contains $grupo) {
            msg_alert "'$grupo' ya esta en la lista"; continue
        }
        $script:FTP_GROUPS += $grupo
        msg_success "Grupo '$grupo' agregado"
    }

    Save-FtpGroups
    msg_success "Grupos guardados: $($script:FTP_GROUPS -join ', ')"
}

function Show-FtpGroups {
    Write-Separator
    msg_info "Grupos FTP:"
    foreach ($grupo in $script:FTP_GROUPS) {
        $dir = "$script:FTP_ROOT\grupos\$grupo"
        Write-Host ""
        Write-Host "  Grupo     : $grupo"
        Write-Host "  Directorio: $dir"
        if (Test-Path $dir) {
            $acl = (Get-Acl $dir).Access | Where-Object { $_.IdentityReference -notlike "*SYSTEM*" -and $_.IdentityReference -notlike "*Administrators*" }
            Write-Host "  Permisos  : $($acl | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights)" } | Select-Object -First 3)"
        } else {
            Write-Host "  Directorio: no existe"
        }
        # Miembros desde metadatos
        $miembros = @()
        if (Test-Path $script:FTP_META) {
            $miembros = Get-Content $script:FTP_META | Where-Object { $_ -match ":${grupo}$" } | ForEach-Object { ($_ -split ':')[0] }
        }
        Write-Host "  Miembros  : $(if ($miembros) { $miembros -join ', ' } else { '(sin miembros)' })"
    }
    Write-Host ""
    Write-Separator
    msg_info "Directorio general: $script:FTP_GENERAL"
    if (Test-Path $script:FTP_GENERAL) {
        $acl = (Get-Acl $script:FTP_GENERAL).Access | Where-Object { $_.IdentityReference -like "*$script:FTP_GROUP_ALL*" }
        Write-Host "  Permisos grupo ftp_users: $($acl.FileSystemRights)"
    }
}

function New-FtpGroup {
    Write-Separator
    $nuevoGrupo = Read-Input "Nombre del nuevo grupo: "

    if ([string]::IsNullOrWhiteSpace($nuevoGrupo) -or $nuevoGrupo -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        msg_error "Nombre invalido"; return
    }
    if ($script:FTP_GROUPS -contains $nuevoGrupo) {
        msg_alert "El grupo '$nuevoGrupo' ya existe"; return
    }

    # Crear grupo local Windows si no existe
    if (-not (Get-LocalGroup -Name $nuevoGrupo -ErrorAction SilentlyContinue)) {
        try {
            New-LocalGroup -Name $nuevoGrupo -Description "Grupo FTP: $nuevoGrupo" -ErrorAction Stop | Out-Null
            msg_success "Grupo local '$nuevoGrupo' creado"
        } catch {
            msg_error "No se pudo crear el grupo local: $_"; return
        }
    }

    # Crear directorio y aplicar permisos
    $dir = "$script:FTP_ROOT\grupos\$nuevoGrupo"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Disable-NtfsInheritance $dir
    Set-NtfsPermission $dir "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $dir "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $dir $nuevoGrupo              "Modify"

    $script:FTP_GROUPS += $nuevoGrupo
    Save-FtpGroups
    msg_success "Grupo '$nuevoGrupo' creado"
}

function Remove-FtpGroup {
    Write-Separator
    Show-FtpGroups

    $grupoEliminar = Read-Input "Nombre del grupo a eliminar: "
    if ($script:FTP_GROUPS -notcontains $grupoEliminar) {
        msg_error "Grupo no encontrado"; return
    }
    if ($script:FTP_GROUPS.Count -le 1) {
        msg_error "Debe quedar al menos un grupo"; return
    }

    # Reasignar usuarios del grupo
    $miembros = @()
    if (Test-Path $script:FTP_META) {
        $miembros = Get-Content $script:FTP_META | Where-Object { $_ -match ":${grupoEliminar}$" } | ForEach-Object { ($_ -split ':')[0] }
    }
    if ($miembros.Count -gt 0) {
        msg_info "Usuarios a reasignar: $($miembros -join ', ')"
        $grupoDestino = Select-FtpGroup
        foreach ($u in $miembros) {
            Meta-Set $u $grupoDestino
            Update-FtpUserVirtualDirectories $u $grupoDestino
            # Mover al nuevo grupo local Windows
            try {
                Remove-LocalGroupMember -Group $grupoEliminar -Member $u -ErrorAction SilentlyContinue
                Add-LocalGroupMember    -Group $grupoDestino  -Member $u -ErrorAction SilentlyContinue
            } catch {}
            msg_success "'$u' reasignado a '$grupoDestino'"
        }
    }

    # Eliminar directorio
    $dir = "$script:FTP_ROOT\grupos\$grupoEliminar"
    if (Test-Path $dir) {
        if (Confirm-Action "Eliminar directorio $dir?") {
            Remove-Item $dir -Recurse -Force
            msg_success "Directorio eliminado"
        }
    }

    # Eliminar grupo local Windows
    try { Remove-LocalGroup -Name $grupoEliminar -ErrorAction SilentlyContinue } catch {}

    $script:FTP_GROUPS = $script:FTP_GROUPS | Where-Object { $_ -ne $grupoEliminar }
    Save-FtpGroups
    msg_success "Grupo '$grupoEliminar' eliminado"
}

function Select-FtpGroup {
    while ($true) {
        Write-Host "  Grupos disponibles:"
        for ($i = 0; $i -lt $script:FTP_GROUPS.Count; $i++) {
            Write-Host "    $($i+1)) $($script:FTP_GROUPS[$i])"
        }
        $sel = Read-Input "Selecciona grupo [1-$($script:FTP_GROUPS.Count)]: "
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $script:FTP_GROUPS.Count) {
            return $script:FTP_GROUPS[[int]$sel - 1]
        }
        msg_error "Seleccion invalida"
    }
}

function Manage-GroupDirectoryPermissions {
    Write-Separator
    msg_info "Permisos actuales:"
    Write-Host ""
    foreach ($path in @($script:FTP_ROOT, $script:FTP_GENERAL)) {
        if (Test-Path $path) {
            Write-Host "  $path"
        }
    }
    foreach ($grupo in $script:FTP_GROUPS) {
        $d = "$script:FTP_ROOT\grupos\$grupo"
        Write-Host "  $d $(if (-not (Test-Path $d)) { '(no existe)' })"
    }
    Write-Separator
    Repair-FtpPermissions
}

function Repair-FtpGroupMemberships {
    Write-Separator
    msg_process "Verificando grupos de usuarios FTP..."
    if (-not (Test-Path $script:FTP_META)) { msg_alert "No hay usuarios registrados"; return }

    Get-Content $script:FTP_META | ForEach-Object {
        if ($_ -match '^(.+):(.+)$') {
            $u = $Matches[1]; $g = $Matches[2]
            # Verificar que el usuario pertenece al grupo correcto en Windows
            $enGrupo = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$u" }
            if (-not $enGrupo) {
                try {
                    Add-LocalGroupMember -Group $g -Member $u -ErrorAction Stop
                    msg_success "$u : agregado a grupo '$g'"
                } catch {
                    msg_error "No se pudo agregar '$u' a '$g': $_"
                }
            } else {
                msg_info "$u : grupo '$g' OK"
            }
            # Garantizar que esta en ftp_users
            $enFtpUsers = Get-LocalGroupMember -Group $script:FTP_GROUP_ALL -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$u" }
            if (-not $enFtpUsers) {
                Add-LocalGroupMember -Group $script:FTP_GROUP_ALL -Member $u -ErrorAction SilentlyContinue
            }
        }
    }
    msg_success "Revision completada"
}