-- =============================================================================
-- init/01_schema.sql
-- Se ejecuta automaticamente la primera vez que el volumen esta vacio
-- =============================================================================

-- Tabla de equipos de futbol mexicano
CREATE TABLE IF NOT EXISTS equipos (
    id     SERIAL PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL,
    estado VARCHAR(100) NOT NULL
);

-- Datos iniciales (3 registros para poder agregar mas en la demostracion)
INSERT INTO equipos (nombre, estado) VALUES
    ('Dorados de Sinaloa',   'Sinaloa'),
    ('Necaxa',               'Aguascalientes'),
    ('Atletico de San Luis', 'San Luis Potosi');