# 📖 Documentación: Chatbot Multiherramienta - Hito 3

## Índice

1. [Descripción General](#descripción-general)
2. [Arquitectura del Workflow](#arquitectura-del-workflow)
3. [Diagrama de Flujo](#diagrama-de-flujo)
4. [Nodos del Workflow](#nodos-del-workflow)
   - [Entrada y Validación](#entrada-y-validación)
   - [Clasificación de Intención (IA)](#clasificación-de-intención-ia)
   - [Router de Herramientas](#router-de-herramientas)
   - [Rama: Clima](#rama-clima)
   - [Rama: Países](#rama-países)
   - [Rama: Wikipedia](#rama-wikipedia)
   - [Rama: Sin Herramienta](#rama-sin-herramienta)
   - [Generación de Respuesta](#generación-de-respuesta)
   - [Salida](#salida)
5. [APIs Externas Utilizadas](#apis-externas-utilizadas)
6. [Modelos de IA](#modelos-de-ia)
7. [Memoria Conversacional](#memoria-conversacional)
8. [Estructura de Datos](#estructura-de-datos)
9. [Configuración y Credenciales](#configuración-y-credenciales)
10. [Manejo de Errores](#manejo-de-errores)
11. [Limitaciones Conocidas](#limitaciones-conocidas)

---

## Descripción General

**Chatbot Multiherramienta - Hito 3** es un workflow de n8n que implementa un chatbot conversacional con capacidad de enrutamiento inteligente hacia múltiples herramientas externas. El sistema recibe mensajes de texto por HTTP, clasifica la intención del usuario usando un modelo de lenguaje local (LLM via Ollama), consulta la API correspondiente, y devuelve una respuesta natural generada también por IA.

**Capacidades principales:**

- Consulta del **tiempo meteorológico** para cualquier ciudad del mundo.
- Obtención de **información detallada de países** (capital, población, moneda, idiomas, superficie).
- Búsqueda y resumen de artículos de **Wikipedia en español**.
- Conversación **general** sin herramienta externa cuando el mensaje no requiere datos en tiempo real.
- **Memoria conversacional persistente** almacenada en PostgreSQL por sesión.

---

## Arquitectura del Workflow

El sistema sigue un patrón de **arquitectura de agente con enrutamiento explícito**, compuesto por tres fases bien diferenciadas:

```
[ENTRADA] → [CLASIFICACIÓN IA] → [ROUTER] → [HERRAMIENTA] → [RESPUESTA IA] → [SALIDA]
```

**Fase 1 — Entrada y clasificación:** El mensaje del usuario se valida y se envía a un agente de IA que devuelve un JSON indicando qué herramienta usar y qué parámetros extraer.

**Fase 2 — Ejecución de herramienta:** Un nodo Switch enruta el flujo a la rama correspondiente (Clima, Países, Wikipedia o ninguna), que llama a la API externa y formatea los datos obtenidos.

**Fase 3 — Respuesta:** Un segundo agente de IA recibe el contexto de la API y el mensaje original, y genera una respuesta en lenguaje natural en español. La respuesta final se construye y se devuelve al cliente por HTTP.

---

## Diagrama de Flujo

```
Webhook Entrada (POST /chat)
        │
        ▼
Validar Input
        │
        ▼
AI Agent ──[Ollama qwen2.5:32b]──[Postgres Chat Memory]
        │  (Clasifica intención → JSON)
        ▼
Parsear Intencion
        │
        ▼
Router Herramienta (Switch)
   ├──[clima]──────► HTTP Request (Geocoding)
   │                       │
   │                ▼
   │            Extraer Coordenadas
   │                       │
   │                ▼
   │            API OpenMeteo
   │                       │
   │                ▼
   │            Formatear Clima ──────────────────────────┐
   │                                                       │
   ├──[paises]─────► Normalizar Pais                       │
   │                       │                               │
   │                ▼                                      │
   │            API REST Countries                         │
   │                       │                               │
   │                ▼                                      │
   │            Formatear Pais ────────────────────────────┤
   │                                                       │
   ├──[wikipedia]──► API Wikipedia                         │
   │                       │                               │
   │                ▼                                      │
   │            Formatear Wikipedia ──────────────────────┤
   │                                                       │
   └──[ninguna]────► Sin Herramienta ────────────────────┐ │
                                                          │ │
                                                          ▼ ▼
                                              Chain Generar Respuesta
                                              [Ollama gpt-oss:20b]
                                                          │
                                                          ▼
                                              Construir Respuesta
                                                          │
                                                          ▼
                                              Responder Cliente (HTTP 200)
```

---

## Nodos del Workflow

### Entrada y Validación

#### `Webhook Entrada`
- **Tipo:** `n8n-nodes-base.webhook`
- **Método HTTP:** `POST`
- **Ruta:** `/chat`
- **Modo de respuesta:** `responseNode` (la respuesta HTTP la gestiona otro nodo explícitamente)
- **Webhook ID:** `chatbot-hito3`

**Descripción:** Punto de entrada del sistema. Escucha peticiones POST en la ruta `/chat` y pasa el cuerpo completo al siguiente nodo.

---

#### `Validar Input`
- **Tipo:** `n8n-nodes-base.code` (JavaScript)

**Descripción:** Extrae y valida los campos del cuerpo de la petición. Acepta los campos `mensaje` o `message` (compatibilidad), y `session_id` o `sessionId`. Si el mensaje está vacío, lanza un error.

**Salida:**
```json
{
  "mensaje": "string (requerido)",
  "sessionId": "string (por defecto: 'default-session')",
  "timestamp": "ISO 8601"
}
```

---

### Clasificación de Intención (IA)

#### `AI Agent`
- **Tipo:** `@n8n/n8n-nodes-langchain.agent` (v3.1)
- **Modelo:** Ollama Chat Model (`qwen2.5:32b`)
- **Memoria:** Postgres Chat Memory

**Descripción:** Primer agente de IA del sistema. Su única tarea es **clasificar la intención** del mensaje del usuario y devolver un JSON estructurado. El prompt está diseñado para que responda **exclusivamente en JSON** sin texto adicional.

**Prompt de sistema:**
```
Responde SOLO con JSON, sin explicaciones, sin texto adicional, sin markdown.

Clasifica este mensaje en una de estas herramientas: clima, paises, wikipedia, ninguna.

EJEMPLOS:
Mensaje: "que tiempo hace en barcelona"
  → {"herramienta":"clima","parametros":{"ciudad":"barcelona"},"razon":"pregunta clima"}
Mensaje: "capital de francia"
  → {"herramienta":"paises","parametros":{"pais":"france"},"razon":"pregunta pais"}
Mensaje: "quien fue napoleon"
  → {"herramienta":"wikipedia","parametros":{"query":"napoleon"},"razon":"pregunta wikipedia"}
Mensaje: "hola como estas"
  → {"herramienta":"ninguna","parametros":{},"razon":"saludo"}
```

**Salida esperada del modelo:**
```json
{
  "herramienta": "clima | paises | wikipedia | ninguna",
  "parametros": { "ciudad": "..." | "pais": "..." | "query": "..." },
  "razon": "string explicativo"
}
```

---

#### `Parsear Intencion`
- **Tipo:** `n8n-nodes-base.code` (JavaScript)

**Descripción:** Recibe la salida del agente (que puede contener múltiples bloques) y extrae el primer JSON válido que contenga una herramienta distinta de `"ninguna"`. Si no encuentra ninguno válido, establece la herramienta como `"ninguna"`.

**Salida:**
```json
{
  "mensaje": "string",
  "session_id": "string",
  "timestamp": "ISO 8601",
  "herramienta": "clima | paises | wikipedia | ninguna",
  "parametros": {},
  "razon_clasificacion": "string"
}
```

---

### Router de Herramientas

#### `Router Herramienta`
- **Tipo:** `n8n-nodes-base.switch` (v3)
- **Fallback:** `extra` (sale por la rama por defecto si no coincide ninguna regla)

**Descripción:** Nodo central de enrutamiento. Compara el campo `herramienta` con los valores posibles y dirige el flujo a la rama correspondiente.

| Valor de `herramienta` | Rama de salida | Siguiente nodo |
|------------------------|----------------|----------------|
| `"clima"` | Clima | HTTP Request (Geocoding) |
| `"paises"` | Paises | Normalizar Pais |
| `"wikipedia"` | Wikipedia | API Wikipedia |
| *(cualquier otro)* | Fallback | Sin Herramienta |

---

### Rama: Clima

Esta rama consta de **4 nodos** que trabajan en cadena para obtener y formatear datos meteorológicos.

#### `HTTP Request` (Geocoding)
- **API:** `https://geocoding-api.open-meteo.com/v1/search`
- **Parámetros:** nombre de ciudad (URL-encoded), `count=1`, `language=es`, `format=json`

**Descripción:** Convierte el nombre de la ciudad en coordenadas geográficas (latitud/longitud). Usa la API de geocodificación de Open-Meteo, que es gratuita y no requiere clave API.

---

#### `Extraer Coordenadas`
- **Tipo:** `n8n-nodes-base.code` (JavaScript)

**Descripción:** Procesa la respuesta de geocodificación. Si no se encuentra la ciudad, lanza un error descriptivo. Si se encuentra, extrae nombre, país, latitud y longitud del primer resultado.

**Salida:**
```json
{
  "geo": {
    "nombre": "string",
    "pais": "string",
    "lat": number,
    "lon": number
  }
}
```

---

#### `API OpenMeteo`
- **API:** `https://api.open-meteo.com/v1/forecast`
- **Parámetros actuales:** `temperature_2m`, `relative_humidity_2m`, `wind_speed_10m`, `weather_code`, `apparent_temperature`
- **Parámetros diarios:** `temperature_2m_max`, `temperature_2m_min`, `precipitation_sum`
- **Configuración:** `timezone=auto`, `forecast_days=3`

**Descripción:** Obtiene el pronóstico meteorológico actual y los próximos 3 días para las coordenadas extraídas. API gratuita sin clave.

---

#### `Formatear Clima`
- **Tipo:** `n8n-nodes-base.code` (JavaScript)

**Descripción:** Transforma la respuesta cruda de Open-Meteo en un texto estructurado y legible. Incluye un mapa de códigos WMO (World Meteorological Organization) para convertir el código de tiempo en descripción en español (ej.: `61` → `"Lluvia leve"`).

**Ejemplo de `contexto_api` generado:**
```
Ciudad: Barcelona, Spain
Temperatura: 18C (sensacion 16C)
Viento: 12 km/h
Humedad: 65%
Estado: Parcialmente nublado
Proximos 3 dias:
- Hoy: 14C - 21C | Lluvia: 0mm
- Manana: 13C - 20C | Lluvia: 2mm
- Pasado: 12C - 19C | Lluvia: 5mm
```

---

### Rama: Países

Esta rama consta de **3 nodos**.

#### `Normalizar Pais`
- **Tipo:** `n8n-nodes-base.code` (JavaScript)

**Descripción:** Traduce el nombre del país del español al inglés, ya que la API REST Countries trabaja con nombres en inglés. Incluye un diccionario de traducción de más de 50 países con sus variantes comunes (acentos, abreviaturas: `eeuu`, `usa`).

**Ejemplo:** `"japón"` → `"japan"`, `"estados unidos"` → `"united states"`

---

#### `API REST Countries`
- **API:** `https://restcountries.com/v3.1/name/{pais}`

**Descripción:** Consulta información detallada del país. Devuelve un array con todos los países que coinciden con el nombre; el nodo siguiente usa el primero.

---

#### `Formatear Pais`
- **Tipo:** `n8n-nodes-base.code` (JavaScript)

**Descripción:** Extrae y formatea los datos del país. Prioriza el nombre en español usando `translations.spa.common` si está disponible. Formatea la población con separadores de miles en formato español.

**Ejemplo de `contexto_api` generado:**
```
Pais: Japón
Capital: Tokio
Poblacion: 125.700.000 habitantes
Moneda: Japanese Yen (¥)
Idioma(s): Japanese
Superficie: 377.930 km2
Region: Eastern Asia, Asia
```

---

### Rama: Wikipedia

Esta rama consta de **2 nodos**.

#### `API Wikipedia`
- **API:** `https://es.wikipedia.org/w/api.php`
- **Parámetros:** `action=query`, `list=search`, `srlimit=1`, `format=json`
- **Headers:** `User-Agent: n8n-chatbot/1.0 (educational project)` (requerido por Wikipedia)

**Descripción:** Realiza una búsqueda en la Wikipedia en español con el query extraído por el agente clasificador. Devuelve el resultado más relevante.

> ⚠️ **Nota:** Este nodo realiza una búsqueda (`list=search`). El nodo de formateo trabaja con los campos `title` y `extract` del resultado, pero la API de búsqueda no devuelve `extract` directamente. Para obtener el extracto completo sería necesario una segunda llamada a `action=query&prop=extracts`. Esta es una limitación conocida del workflow actual.

---

#### `Formatear Wikipedia`
- **Tipo:** `n8n-nodes-base.code` (JavaScript)

**Descripción:** Extrae título, resumen (limitado a 800 caracteres) y URL de la página. Construye un texto de contexto para el agente generador.

**Ejemplo de `contexto_api` generado:**
```
Tema: Napoleón Bonaparte
Resumen: Napoleón Bonaparte (Ajaccio, 15 de agosto de 1769-isla de Santa Elena...
Mas info: https://es.wikipedia.org/wiki/Napole%C3%B3n_Bonaparte
```

---

### Rama: Sin Herramienta

#### `Sin Herramienta`
- **Tipo:** `n8n-nodes-base.code` (JavaScript)

**Descripción:** Rama fallback cuando el agente clasificador determina que el mensaje no requiere ninguna herramienta externa (saludos, preguntas generales, conversación). Pasa el mensaje directamente al generador de respuesta con `contexto_api` vacío.

---

### Generación de Respuesta

#### `Chain Generar Respuesta`
- **Tipo:** `@n8n/n8n-nodes-langchain.agent` (v3.1)
- **Modelo:** Ollama Chat Model (`gpt-oss:20b`)

**Descripción:** Segundo agente de IA. Recibe el mensaje original del usuario y el contexto estructurado obtenido de la API (o vacío si no se usó herramienta), y genera una respuesta en lenguaje natural en español, clara y amigable.

**Prompt de sistema:**
```
Eres un asistente virtual inteligente y amigable. Responde siempre en español de forma 
clara y concisa. Si recibes información de herramientas externas, úsala como base para 
tu respuesta. Mantén el contexto de la conversación.

Información obtenida (herramienta: {herramienta}):
{contexto_api || 'No se usó herramienta externa.'}

Mensaje del usuario:
{mensaje}
```

---

#### `Construir Respuesta`
- **Tipo:** `n8n-nodes-base.code` (JavaScript)

**Descripción:** Postprocesa la salida del agente generador. Aplica lógica para eliminar el razonamiento interno del modelo (tokens de "thinking" que algunos modelos incluyen antes de la respuesta real). Intenta detectar el inicio del contenido útil buscando patrones como `**` o párrafos reales tras una línea en blanco.

**Salida final:**
```json
{
  "ok": true,
  "session_id": "string",
  "mensaje_usuario": "string",
  "respuesta": "string (respuesta en lenguaje natural)",
  "herramienta_usada": "clima | paises | wikipedia | ninguna",
  "timestamp": "ISO 8601"
}
```

---

### Salida

#### `Responder Cliente`
- **Tipo:** `n8n-nodes-base.respondToWebhook`
- **Formato:** JSON
- **Código HTTP:** `200`

**Descripción:** Cierra el ciclo HTTP devolviendo la respuesta construida como JSON al cliente que realizó la petición original.

---

## APIs Externas Utilizadas

| API | URL Base | Autenticación | Coste |
|-----|----------|---------------|-------|
| Open-Meteo Geocoding | `https://geocoding-api.open-meteo.com` | Ninguna | Gratuita |
| Open-Meteo Forecast | `https://api.open-meteo.com` | Ninguna | Gratuita |
| REST Countries | `https://restcountries.com/v3.1` | Ninguna | Gratuita |
| Wikipedia (ES) | `https://es.wikipedia.org/w/api.php` | Ninguna (User-Agent requerido) | Gratuita |

---

## Modelos de IA

El workflow utiliza **dos modelos diferentes** servidos localmente a través de **Ollama**:

| Nodo | Modelo | Propósito |
|------|--------|-----------|
| `AI Agent` | `qwen2.5:32b` | Clasificación de intención (razonamiento estructurado, output JSON) |
| `Chain Generar Respuesta` | `gpt-oss:20b` | Generación de respuesta en lenguaje natural |

Ambos modelos usan la misma credencial `Ollama account` . El servidor Ollama debe estar activo y tener ambos modelos descargados para que el workflow funcione.

---

## Memoria Conversacional

#### `Postgres Chat Memory`
- **Tipo:** `@n8n/n8n-nodes-langchain.memoryPostgresChat` (v1.3)
- **Credencial:** `Postgres account`
- **Conectado a:** `AI Agent` (nodo clasificador)

**Descripción:** Almacena el historial de conversación por `session_id` en una base de datos PostgreSQL. Esto permite que el agente clasificador recuerde el contexto de turnos anteriores, mejorando la clasificación en conversaciones multi-turno.

> ⚠️ **Nota:** La memoria está conectada únicamente al agente **clasificador**, no al agente **generador de respuesta**. Esto significa que el historial influye en la detección de intención, pero el generador responde sin memoria explícita de la conversación (aunque puede recibir contexto implícitamente a través del mensaje).

---

## Estructura de Datos

### Petición entrante (POST `/chat`)

```json
{
  "mensaje": "¿Qué tiempo hace en Madrid?",
  "session_id": "usuario-123"
}
```

**Campos aceptados:**

| Campo | Aliases | Tipo | Requerido | Default |
|-------|---------|------|-----------|---------|
| `mensaje` | `message` | string | ✅ Sí | — |
| `session_id` | `sessionId` | string | No | `"default-session"` |

### Respuesta exitosa (HTTP 200)

```json
{
  "ok": true,
  "session_id": "usuario-123",
  "mensaje_usuario": "¿Qué tiempo hace en Madrid?",
  "respuesta": "En Madrid ahora mismo hay 22°C con sensación térmica de 20°C...",
  "herramienta_usada": "clima",
  "timestamp": "2025-10-15T14:32:00.000Z"
}
```

---

## Configuración y Credenciales

Para poner en marcha el workflow son necesarias las siguientes credenciales configuradas en n8n:

| Credencial | Usada por |
|------------|-----------|
| `Ollama account` | AI Agent, Chain Generar Respuesta |
| `Postgres account` | Postgres Chat Memory |

**Estado del workflow:** `active: false` — el workflow está **inactivo** y debe activarse manualmente en n8n antes de poder recibir peticiones.

---

## Manejo de Errores

| Nodo | Condición de error | Comportamiento |
|------|--------------------|----------------|
| `Validar Input` | `mensaje` vacío o ausente | Lanza `Error: El campo mensaje es obligatorio` |
| `Extraer Coordenadas` | Ciudad no encontrada en geocodificación | Lanza `Error: Ciudad no encontrada: {ciudad}` |
| `Parsear Intencion` | Ningún JSON válido en output del agente | Establece `herramienta: "ninguna"` como fallback seguro |
| `Router Herramienta` | `herramienta` no coincide con ninguna regla | Enruta al fallback → `Sin Herramienta` |

---

## Limitaciones Conocidas

1. **Wikipedia sin extracto completo:** La llamada a la API de Wikipedia usa `list=search`, que no devuelve el campo `extract` con el resumen del artículo. Para obtenerlo se necesitaría una segunda petición HTTP con `action=query&prop=extracts&pageids={id}`.

2. **Memoria solo en clasificador:** El historial de conversación (PostgreSQL) solo alimenta al agente clasificador, no al generador de respuesta. Conversaciones largas con contexto acumulado pueden no reflejarse correctamente en las respuestas.

3. **Diccionario de países limitado:** El nodo `Normalizar Pais` incluye un diccionario manual de ~55 países. Países menos comunes o con nombres muy distintos en español e inglés pueden no ser reconocidos correctamente.

4. **Postprocesado de respuesta frágil:** El nodo `Construir Respuesta` usa expresiones regulares para eliminar el razonamiento interno del modelo. Si el modelo cambia su formato de salida, estos separadores pueden fallar.

5. **Workflow inactivo por defecto:** `active: false` — debe activarse manualmente antes de su uso en producción.