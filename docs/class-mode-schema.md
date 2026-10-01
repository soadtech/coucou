# Modo Clase — esquema de exportación

Este documento describe el JSON que produce el botón **Exportar** del Modo
Clase. Es un contrato: **las claves existentes no cambian de nombre ni de
significado.** Lo que puede pasar en versiones futuras es que aparezcan claves
nuevas, así que un consumidor debe ignorar las que no conozca.

El formato de exportación **no** es el formato en disco. En disco los datos
están repartidos en varios archivos que convienen a cómo los escribe la app; la
exportación es un único documento plano y versionado, para que quien lo importe
no tenga que saber nada de cómo guarda Coucou las cosas.

## Qué contiene una exportación

Al exportar una clase se obtiene una carpeta (o un zip con esa carpeta dentro)
llamada `AAAA-MM-DD Título de la clase`:

```
2026-10-01 Clase de francés/
  class.json     ← todo lo descrito aquí
  notes.md       ← los mismos apuntes en Markdown, para leer
  audio.m4a      ← la grabación (opcional)
```

Solo `class.json` es contrato. `notes.md` es una comodidad y su formato puede
cambiar.

## Versionado

```json
{ "formatVersion": 1 }
```

`formatVersion` sube solo si hay un cambio incompatible. Un consumidor debería
rechazar lo que no sepa leer en vez de adivinar:

```js
if (data.formatVersion !== 1) throw new Error("Formato no soportado");
```

## Documento

```jsonc
{
  "formatVersion": 1,
  "exportedAt": "2026-10-01T18:04:11Z",   // ISO 8601, UTC
  "generator": "Coucou Class Mode",

  "id": "B1BF6BFA-060D-47EA-A55F-A18439FBF70B",  // UUID, estable
  "title": "Clase de Inglés — 30 sept 19:48",
  "language": "en",                       // "en" | "fr" — el idioma que se estudia
  "startedAt": "2026-09-30T17:48:02Z",
  "endedAt": "2026-09-30T18:49:30Z",      // null si la clase quedó a medias
  "duration": 3688.4,                     // segundos de audio grabado
  "sourceApp": "Safari",                  // app escuchada; null si solo micrófono
  "transcriptionModel": "large-v3-v20240930_turbo",  // puede ser null
  "audioFile": "audio.m4a",               // null si se exportó sin audio

  "transcript": [ /* ver abajo */ ],
  "marks":      [ /* ver abajo */ ],
  "notes":        /* ver abajo, o null */
}
```

**Todos los tiempos en segundos** desde el inicio de la clase, como número
decimal. Las fechas son ISO 8601 en UTC.

### `transcript[]`

En orden cronológico.

```jsonc
{
  "start": 124.5,      // segundos desde el inicio
  "end": 131.2,
  "speaker": "clase",  // ver tabla
  "text": "Dull is the opposite of sharp.",
  "language": "en"     // idioma detectado, o null
}
```

| `speaker` | Qué significa |
|---|---|
| `clase` | Audio de la app de la reunión: el profesor, otros alumnos |
| `yo` | El micrófono del estudiante |
| `desconocido` | Transcripción rehecha desde `audio.m4a`, que mezcla las dos fuentes y ya no permite distinguirlas |

`language` es el idioma detectado **en ese fragmento**, no el de la clase: una
clase mezcla español, inglés y francés, y cada trozo se detecta por separado.

> La transcripción es automática y tiene errores. No la trates como una
> transcripción literal fiable.

### `marks[]`

Momentos que el estudiante marcó durante la clase.

```jsonc
{
  "at": 842.0,                 // segundos desde el inicio
  "kind": "notUnderstood",     // "notUnderstood" | "important"
  "note": null,                // nota escrita por el estudiante, normalmente null
  "excerpt": "Clase: ...\nYo: ...",   // transcripción alrededor; null si no hay apuntes
  "explanation": "El profe estaba explicando…"  // en español; null si no hay apuntes
}
```

`excerpt` se extrae de la transcripción guardada (unos 25 s antes y 10 s
después), **no lo escribe el modelo**. `explanation` sí es generada.

### `notes`

`null` si la clase todavía no tiene apuntes.

**Todas las explicaciones están en español**, escritas para un estudiante de
nivel A2. El material en el idioma de la clase (`term`, `example`, `phrase`,
`said`, `corrected`) va en su idioma original.

```jsonc
{
  "generatedAt": "2026-09-30T18:51:02Z",
  "summary": "En esta clase el profesor explicó…",

  "vocabulary": [{
    "term": "dull",
    "translation": "sin brillo, soso; también romo",
    "example": "This end of the pen is sharp, this one is dull.",
    "exampleTranslation": "Esta punta del boli está afilada, esta otra es roma."  // puede ser null
  }],

  "grammar": [{
    "title": "Comparativos con -er",
    "explanation": "Para comparar dos cosas en inglés…",
    "examples": ["This pen is sharper than that one."]
  }],

  "phrases": [{
    "phrase": "the opposite of",
    "meaning": "lo contrario de",
    "context": "Para explicar una palabra por su contrario"  // puede ser null
  }],

  "corrections": [{
    "said": "I have 25 years",        // lo que dijo el estudiante
    "corrected": "I am 25 years old", // la forma correcta
    "explanation": "En inglés la edad va con el verbo to be, no con have.",
    "at": 512.0                       // segundos; puede ser null
  }],

  "review": ["Repasar cuándo se usa dull y cuándo boring"]
}
```

Cualquier lista puede venir vacía. Es intencionado: si una clase no tuvo
correcciones, `corrections` es `[]`, no correcciones inventadas.

## Notas para quien importe esto

- **`id` es estable** entre exportaciones de la misma clase: úsalo para
  deduplicar.
- **Las listas pueden estar vacías y los campos opcionales ser `null`.** Nada
  garantiza que una clase tenga apuntes, marcas o transcripción.
- **`duration` es el audio realmente grabado**, que puede ser algo menor que
  `endedAt - startedAt`.
- **Los tiempos sirven para saltar dentro de `audio.m4a`** si lo exportaste: el
  archivo empieza en el segundo 0 de la clase.
- **No hay datos personales más allá de lo que se dijo en clase.** No hay
  identificadores de dispositivo, ni de cuenta, ni telemetría.
