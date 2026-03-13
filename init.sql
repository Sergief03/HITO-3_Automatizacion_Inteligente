-- Base de datos del chatbot multiherramienta
CREATE DATABASE chatbot_multiherramienta;

USE chatbot_multiherramienta;

-- Tabla de conversaciones

CREATE TABLE IF NOT EXISTS conversaciones (
    id          SERIAL PRIMARY KEY,
    session_id  VARCHAR(100) NOT NULL,
    rol         VARCHAR(20)  NOT NULL CHECK (rol IN ('user','assistant')),
    mensaje     TEXT         NOT NULL,
    herramienta VARCHAR(50),          -- 'clima' | 'paises' | 'wikipedia' | 'ninguna'
    created_at  TIMESTAMP    DEFAULT NOW()
);

CREATE INDEX idx_session ON conversaciones(session_id);
CREATE INDEX idx_created ON conversaciones(created_at);

-- Vista útil para ver el historial por sesión
CREATE VIEW historial_sesion AS
    SELECT session_id,
           rol,
           LEFT(mensaje, 80) AS preview,
           herramienta,
           created_at
    FROM conversaciones
    ORDER BY session_id, created_at;