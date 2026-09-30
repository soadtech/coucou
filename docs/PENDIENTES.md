# Pendientes — Modo Clase

Cosas conocidas que faltan o hay que mejorar. Se anotan según aparecen, con el
motivo, para que no se pierdan entre fases.

Estado: fases 1 (captura de audio) y 2 (transcripción) hechas.
Pendientes: 3 (UI en el notch), 4 (apuntes + Q&A), 5 (historial y exportación).

---

## Experiencia de primer uso

### 1. La descarga del modelo no se descubre sola — **prioritario**

Hoy hay que ir a Settings → Class Mode → "Download now" y saber que eso existe.
Si no se hace, la clase se graba, el audio queda bien, pero no aparece ni una
frase transcrita y nada explica por qué. Solo se sabe si alguien te lo cuenta.

Qué hacer:
- Al iniciar la primera clase, si no hay modelo, **ofrecer la descarga ahí
  mismo** en vez de fallar en silencio. La grabación puede empezar igual: el
  audio se guarda y se transcribe cuando el modelo esté listo.
- Mostrar el progreso donde el usuario está mirando (notch y menú), no solo en
  Settings.
- Considerar descargar un modelo pequeño automáticamente la primera vez que se
  activa el Modo Clase, y dejar el grande como mejora opcional.
- Decir de antemano el tamaño (~1,5 GB) y que es una sola vez.

### 1b. La descarga no informa de lo que está pasando

Aunque ya funcione, el estado que se muestra es pobre: una barra y un
porcentaje, sin tamaño total, sin velocidad, sin "faltan X MB", y sin forma de
cancelar ni de reanudar si se corta. En una descarga de 1,5 GB eso es poco.

Qué hacer: mostrar MB descargados sobre el total, permitir cancelar, y
detectar y reparar una descarga incompleta (hoy solo se comprueba que exista
algún `.mlmodelc`).

### 2. El permiso de Grabación de Pantalla asusta y confunde

ScreenCaptureKit lo exige aunque Coucou solo lea la pista de audio y nunca la
imagen. El diálogo del sistema dice "grabar la pantalla", que es alarmante y no
refleja lo que hace la app.

Qué hacer:
- Explicarlo **antes** de que salga el diálogo del sistema.
- Dejar claro en Settings y en la web que no se captura vídeo.
- macOS solo aplica el permiso tras reiniciar la app: avisarlo y ofrecer el
  reinicio.

*(El bucle de diálogos repetidos ya está corregido: se comprueba con
`CGPreflightScreenCaptureAccess()`, que no pregunta, y solo se llama a
ScreenCaptureKit cuando el permiso ya está concedido.)*

---

## Funcionalidad

### 3. No se puede volver a transcribir una clase

Si la transcripción falla, o el modelo no estaba descargado, ese tramo de texto
se pierde aunque el audio esté intacto en disco. Debería poder relanzarse la
transcripción sobre el `.m4a` ya guardado.

Encaja de forma natural en la Fase 5, junto al historial.

### 3b. El atajo global de marcar no llega a dispararse

⌘⇧L está implementado con `NSEvent.addGlobalMonitorForEvents` —el mismo
mecanismo que el atajo de abrir la isla, que ya existía— pero en pruebas no
responde. Lo más probable es que falte el permiso de Accesibilidad: sin él
macOS no entrega los eventos y la tecla no hace absolutamente nada, sin aviso.
Settings ya detecta y avisa de esa situación, pero está sin confirmar.

Si resulta que el permiso está concedido y aun así falla, hay que pasar a
`RegisterEventHotKey` (Carbon), que no depende de Accesibilidad y es lo que
usan la mayoría de apps para atajos globales.

Impacto bajo por ahora: se puede marcar desde la isla y desde el menú. Pero el
sentido del atajo es marcar **sin salir de la reunión**, así que en una clase
real sí importa.

### 4. Aviso de calidad con auriculares Bluetooth

Al abrir el micrófono, macOS conmuta los auriculares a HFP y **todo** el audio
de la clase baja a calidad de llamada. Se detecta mirando si el dispositivo
está por debajo de 24 kHz.

Qué hacer: avisar al iniciar la clase y ofrecer grabar sin micrófono para
conservar la calidad. Requiere la UI de la Fase 3.

### 5. Los primeros segundos de una clase

Sin verificar: cuánto audio se pierde entre que se pulsa iniciar y que el
stream entrega el primer buffer.

---

## Deuda técnica

### 6. `BotCanvasView` crashea al lanzar desde terminal

`EXC_BAD_ACCESS` en el chequeo de executor de Swift 6 dentro del cierre de
`Canvas`, al arrancar el binario directamente en vez de con `open`. No afecta al
uso normal y no es del Modo Clase, pero estorba al depurar y probablemente
señala un problema real de aislamiento en esa vista.

### 5b. La isla "oculta" es una barra negra en Macs sin notch

`IslandWindowController.notchScreen()` busca una pantalla con
`safeAreaInsets.top > 0`. En un Mac mini con monitor externo no hay ninguna, se
cae al tamaño por defecto (184×32) y el estado "oculto" **dibuja esa barra
negra** en la parte superior de la pantalla, donde en un MacBook quedaría
tapada por el recorte físico.

No es del Modo Clase: es comportamiento del núcleo de la isla y afecta a
cualquiera sin notch. El arreglo sería no dibujar nada en estado oculto cuando
ninguna pantalla tiene notch, dejando solo la zona sensible al ratón (que es lo
que ya hace la versión de Windows). **Decidido no hacerlo por ahora** para no
tocar el núcleo ni desviarse del prototipo.

Lección aparte: cualquier diseño de la isla debe probarse en monitor externo,
no solo en un MacBook.

### 6b. Las builds de Debug se firman ad-hoc y pierden los permisos

Xcode firma Debug sin equipo (`Signature=adhoc`, `TeamIdentifier=not set`), y
macOS ata los permisos de TCC —Grabación de pantalla, Micrófono— al hash del
binario cuando no hay equipo. Cada compilación es, para el sistema, una app
nueva: el permiso concedido deja de valer y Ajustes del Sistema muestra
entradas obsoletas que confunden todavía más.

Solución provisional: `scripts/sign-debug.sh` firma con una identidad de
desarrollo fija (guardada en `.sign-identity`, gitignored) después de compilar.

Arreglo real: configurar la firma de Debug en el proyecto. No se hizo porque
`project.yml` va a git y el `DEVELOPMENT_TEAM` declarado es el del autor
original del repo, no el de quien compila.

### 7. Los dos targets escriben `Coucou.app` en la misma carpeta

`NotchBuddy` y `CoucouAppStore` comparten `Build/Products/Debug/`, así que
compilar uno pisa al otro — y la versión App Store no lleva el Modo Clase, lo
que parece que la funcionalidad ha desaparecido. Mientras tanto se compila el
target App Store con `-derivedDataPath` aparte.

Arreglo real: darles nombres de producto distintos en depuración.
