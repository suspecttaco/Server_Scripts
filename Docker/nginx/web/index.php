<?php
# =============================================================================
# web/index.php — Monitor de infraestructura
# Verifica conectividad con PostgreSQL y FTP
# Muestra tabla de equipos si PostgreSQL esta disponible
# =============================================================================

# Leer variables de entorno inyectadas por Docker
$pg_host = getenv('POSTGRES_HOST') ?: '172.20.0.10';
$pg_port = getenv('POSTGRES_PORT') ?: '5432';
$pg_db   = getenv('POSTGRES_DB')   ?: 'infradb';
$pg_user = getenv('POSTGRES_USER') ?: 'infrauser';
$pg_pass = getenv('POSTGRES_PASSWORD') ?: '';

$ftp_host = getenv('FTP_HOST') ?: '172.20.0.30';
$ftp_port = getenv('FTP_PORT') ?: '21';

# -----------------------------------------------------------------------------
# Verificar conexion a PostgreSQL
# pg_connect intenta conectar; si falla devuelve false
# -----------------------------------------------------------------------------
$pg_status = false;
$pg_error  = '';
$equipos   = [];

$conn = @pg_connect("host={$pg_host} port={$pg_port} dbname={$pg_db} user={$pg_user} password={$pg_pass} connect_timeout=3");

if ($conn) {
    $pg_status = true;
    $result = pg_query($conn, "SELECT nombre, estado FROM equipos ORDER BY id");
    if ($result) {
        while ($row = pg_fetch_assoc($result)) {
            $equipos[] = $row;
        }
    }
    pg_close($conn);
} else {
    $pg_error = 'No se pudo conectar a PostgreSQL';
}

# -----------------------------------------------------------------------------
# Verificar conectividad con FTP (intento de conexion TCP al puerto 21)
# No hace login, solo verifica que el puerto responde
# -----------------------------------------------------------------------------
$ftp_status = false;
$ftp_sock   = @fsockopen($ftp_host, (int)$ftp_port, $errno, $errstr, 3);
if ($ftp_sock) {
    $ftp_status = true;
    fclose($ftp_sock);
}
?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="10">
    <title>Monitor de Infraestructura</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #0f1117;
            color: #e0e0e0;
            padding: 2rem;
        }

        /* Layout principal: contenido a la izquierda, mosaico a la derecha */
        .layout {
            display: flex;
            gap: 2rem;
            align-items: flex-start;
        }

        .content {
            flex: 1;
            min-width: 0;
        }

        /* Mosaico de 4 gifs en grid 2x2 */
        .mosaic {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 0.5rem;
            width: 320px;
            flex-shrink: 0;
        }

        .mosaic img {
            width: 100%;
            height: 150px;
            object-fit: cover;
            border-radius: 6px;
            border: 1px solid #22263a;
        }

        h1 {
            font-size: 1.5rem;
            font-weight: 600;
            margin-bottom: 0.25rem;
            color: #ffffff;
        }

        .subtitle {
            font-size: 0.85rem;
            color: #666;
            margin-bottom: 2rem;
        }

        /* Tarjetas de estado */
        .cards {
            display: flex;
            gap: 1rem;
            margin-bottom: 2.5rem;
            flex-wrap: wrap;
        }

        .card {
            background: #1a1d27;
            border-radius: 8px;
            padding: 1.25rem 1.5rem;
            min-width: 200px;
            border-left: 4px solid #333;
        }

        .card.up   { border-left-color: #22c55e; }
        .card.down { border-left-color: #ef4444; }

        .card-label {
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            color: #888;
            margin-bottom: 0.5rem;
        }

        .card-name {
            font-size: 1rem;
            font-weight: 600;
            color: #fff;
            margin-bottom: 0.25rem;
        }

        .card-status {
            font-size: 0.85rem;
            font-weight: 500;
        }

        .card.up   .card-status { color: #22c55e; }
        .card.down .card-status { color: #ef4444; }

        .card-detail {
            font-size: 0.75rem;
            color: #555;
            margin-top: 0.25rem;
        }

        /* Tabla de equipos */
        h2 {
            font-size: 1rem;
            font-weight: 600;
            color: #aaa;
            margin-bottom: 1rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }

        table {
            width: 100%;
            max-width: 500px;
            border-collapse: collapse;
            background: #1a1d27;
            border-radius: 8px;
            overflow: hidden;
        }

        thead {
            background: #22263a;
        }

        th {
            padding: 0.75rem 1rem;
            text-align: left;
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: #888;
        }

        td {
            padding: 0.75rem 1rem;
            font-size: 0.9rem;
            border-top: 1px solid #22263a;
        }

        tr:hover td { background: #22263a; }

        .no-data {
            color: #555;
            font-size: 0.85rem;
            padding: 1rem 0;
        }

        .refresh-note {
            margin-top: 2rem;
            font-size: 0.75rem;
            color: #444;
        }
    </style>
</head>
<body>

<div class="layout">
<div class="content">

<h1>Monitor de Infraestructura</h1>
<p class="subtitle">Actualizacion automatica cada 10 segundos</p>

<div class="cards">

    <!-- Estado PostgreSQL -->
    <div class="card <?= $pg_status ? 'up' : 'down' ?>">
        <div class="card-label">Base de datos</div>
        <div class="card-name">PostgreSQL</div>
        <div class="card-status"><?= $pg_status ? 'Activo' : 'Inactivo' ?></div>
        <div class="card-detail"><?= htmlspecialchars($pg_host) ?>:<?= htmlspecialchars($pg_port) ?></div>
    </div>

    <!-- Estado FTP -->
    <div class="card <?= $ftp_status ? 'up' : 'down' ?>">
        <div class="card-label">Servidor FTP</div>
        <div class="card-name">vsftpd</div>
        <div class="card-status"><?= $ftp_status ? 'Activo' : 'Inactivo' ?></div>
        <div class="card-detail"><?= htmlspecialchars($ftp_host) ?>:<?= htmlspecialchars($ftp_port) ?></div>
    </div>

</div>

<!-- Tabla de equipos (solo si PostgreSQL esta disponible) -->
<?php if ($pg_status && count($equipos) > 0): ?>
<h2>Equipos de Futbol</h2>
<table>
    <thead>
        <tr>
            <th>Equipo</th>
            <th>Estado</th>
        </tr>
    </thead>
    <tbody>
        <?php foreach ($equipos as $equipo): ?>
        <tr>
            <td><?= htmlspecialchars($equipo['nombre']) ?></td>
            <td><?= htmlspecialchars($equipo['estado']) ?></td>
        </tr>
        <?php endforeach; ?>
    </tbody>
</table>
<?php elseif (!$pg_status): ?>
<p class="no-data">Sin conexion a PostgreSQL — tabla no disponible.</p>
<?php endif; ?>

<p class="refresh-note">Servidor: Nginx &bull; <?= date('Y-m-d H:i:s') ?> UTC</p>

</div>

<!-- Mosaico de gifs decorativos -->
<div class="mosaic">
    <img src="img/gif1.gif" alt="">
    <img src="img/gif2.gif" alt="">
    <img src="img/gif3.gif" alt="">
    <img src="img/gif4.gif" alt="">
</div>

</div>

</body>
</html>