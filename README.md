# Tube

**YouTube y YouTube Music en el iPhone, sin anuncios, en una sola app.**

Tube abre YouTube y YouTube Music a pantalla completa, con el bloqueo de anuncios de Brave Shields, audio en segundo plano y una cápsula alrededor de la isla dinámica que hace de barra de navegación. No es una app de la App Store: la compilas e instalas tú en tu iPhone con tu Apple ID, gratis.

<p align="center">
  <img src="docs/screenshots/youtube-lista.png" width="220" alt="Resultados de búsqueda en YouTube">
  <img src="docs/screenshots/minirreproductor.png" width="220" alt="Minirreproductor sobre la lista">
  <img src="docs/screenshots/music-inicio.png" width="220" alt="Inicio de YouTube Music">
</p>

> **Proyecto personal, sin relación con YouTube ni Google.** Se compila e instala en tu propio iPhone; no se distribuye en la App Store. Bloquear anuncios o reproducir en segundo plano puede ir contra las condiciones de uso de YouTube: úsalo bajo tu responsabilidad. Si quieres apoyar a los creadores, YouTube Premium es la vía oficial.

## La cápsula

<p align="center">
  <img src="docs/screenshots/capsula.png" width="520" alt="Cápsula de la isla dinámica">
</p>

En lugar de las cabeceras de YouTube y Music hay una cápsula alrededor de la isla dinámica (de Liquid Glass en iOS 26):

- **▶︎ ♪** cambia de pestaña sin recargar ni cortar la música. Tocar la pestaña en la que estás vuelve a su inicio. Mantener ♪ reanuda la última canción.
- **🔍** abre el buscador. Mantenerlo pulsado busca por voz.
- **☾** (solo en Music) es el temporizador para dormir, con la cuenta atrás en la cápsula.
- **⋯** abre el menú: compartir, subtítulos, mostrar Shorts, velocidad, calidad y ahorro de datos, letra, cuenta, AirPlay a la tele y recargar. En Music también Inicio, Explorar, Biblioteca e Historial.

En iPhone sin isla dinámica, y con el iPhone en horizontal, es una barra arriba con los mismos botones.

## YouTube

<p align="center">
  <img src="docs/screenshots/youtube-video.png" width="220" alt="Vídeo abierto">
  <img src="docs/screenshots/menu.png" width="220" alt="Menú de la cápsula">
  <img src="docs/screenshots/calidad.png" width="220" alt="Calidad y ahorro de datos">
</p>

- **Sin anuncios**: los mismos filtros que Brave y uBlock Origin. Si alguno se cuela, se silencia y se salta solo.
- **SponsorBlock**: salta patrocinios, autopromoción y recordatorios de «suscríbete», con un aviso.
- **Títulos sin clickbait** (DeArrow): en las listas y bajo el vídeo, el título escrito por la comunidad cuando lo hay.
- **Sin Shorts** en la portada, las búsquedas ni la barra inferior, y un enlace a un Short se abre como vídeo normal. Si quieres verlos, actívalos en ⋯ › *Mostrar Shorts*; dentro de un Short, arrastra el dedo a los lados desde el centro para avanzar o retroceder.
- **Los vídeos se abren encima de la lista**, así la lista nunca se recarga.
- **Minirreproductor**: arrastra el vídeo hacia abajo y sigue sonando en una ventanita que puedes mover.
  - Tócala para volver al vídeo; el botón del centro pausa.
  - Lánzala a la **izquierda** (o pulsa ×) para cerrarla.
  - Lánzala a la **derecha** y se esconde en el borde con una pestaña ‹, sin dejar de sonar. Toca la pestaña para sacarla.
- **Pantalla completa con el reproductor de iOS** (sus controles de Liquid Glass) al girar el iPhone o con el botón de pantalla completa del vídeo. Al ponerlo vertical o cerrarlo vuelve, y el vídeo sigue sonando.
- **Calidad hasta 4K60 HDR** sin Premium (opción *Máxima*). Por defecto 720p.
- **Ahorro de datos**: con datos móviles o en Modo de datos reducidos, 480p; con wifi, la calidad elegida. Cambia solo, también a mitad de vídeo.
- **Subtítulos** apagados por defecto, también en las vistas previas. Se activan en ⋯ y se recuerda.
- **Compartir en el minuto exacto** con un enlace `youtu.be` limpio.
- **Velocidad** e **imagen en imagen**.
- **AirPlay a la tele**: ⋯ › *AirPlay a la tele* recarga el vídeo en el mismo segundo en un formato que la tele puede mostrar (360p, el único que YouTube da así; en su formato normal solo llegaría el sonido) y abre el selector. Vuelve a tocarlo para recuperar la calidad normal. Para verlo a más calidad, usa *Duplicar pantalla* del Centro de control con el iPhone en horizontal.

## YouTube Music

<p align="center">
  <img src="docs/screenshots/music-lista.png" width="220" alt="Lista de reproducción">
  <img src="docs/screenshots/temporizador.png" width="220" alt="Temporizador para dormir">
</p>

- **Audio con el iPhone bloqueado**, con carátula y botones de **siguiente / anterior** en la pantalla de bloqueo (en lugar de los saltos de 10 segundos).
- **Gestos en la carátula**: deslízala a los lados para cambiar de canción, tócala para ver la letra y deslízala hacia abajo para minimizar. Al abrir el reproductor, unos avisos breves te los recuerdan.
- **Letra sincronizada**: la línea que suena se ilumina; toca una para saltar a ella. Si no hay letra sincronizada, un botón abre la de YouTube Music.
- **Temporizador para dormir**: 15, 30, 45 o 60 minutos, o al acabar la canción.
- **Sin avisos de Premium** ni de «Abrir en la aplicación».
- El mejor audio gratuito de YouTube (Opus, formato 251). El de 256 kbps es solo para Premium.

## Más cómodo

<p align="center">
  <img src="docs/screenshots/buscador.png" width="220" alt="Buscador con búsquedas recientes">
</p>

- **Buscador propio**: sugerencias mientras escribes, búsquedas recientes (desliza para borrar una) y micrófono.
- **Recuerda dónde estabas**: al abrir vuelve a la pestaña, la página y el segundo exacto del vídeo o la canción, en pausa.
- **Volver atrás** con el gesto del borde izquierdo. Si no hay página anterior, vuelve a la última búsqueda o al inicio.
- **Liquid Glass** de iOS 26 en la cápsula, el minirreproductor, el buscador, la letra y el reproductor a pantalla completa.
- **Vibración suave** al tocar, **deslizar hacia abajo para recargar** y una pantalla **«Sin conexión»** que se recarga sola.
- **Siri y Atajos**: «Pon mi música en Tube», «Abre Music en Tube», «Abre YouTube en Tube», «Temporizador de Tube».
- **Accesos rápidos**: mantén pulsado el icono para abrir Music o YouTube.
- **Enlaces de fuera**: iOS no deja que otra app abra directamente los enlaces de YouTube. Dos atajos:
  - En la app Atajos, crea uno con la acción «Abrir en Tube» y activa «Mostrar en hoja de compartir». Luego, en WhatsApp o Safari: *Compartir › Abrir en Tube*.
  - O escribe `tube://` delante del enlace en Safari.
- Inicias sesión en Google una vez y vale para las dos pestañas.
- Textos de la app en español o inglés, según el idioma del iPhone.

## Privacidad: a qué se conecta

Aparte de YouTube y YouTube Music, sin cuentas ni datos personales:

| Servicio | Para qué | Qué se envía |
|---|---|---|
| [sponsor.ajay.app](https://sponsor.ajay.app) | SponsorBlock y títulos sin clickbait | Los 4 primeros caracteres de una huella del vídeo; no sabe qué vídeo ves |
| [lrclib.net](https://lrclib.net) | Letra sincronizada | Título y artista de la canción, al abrir la letra |
| suggestqueries.google.com | Sugerencias del buscador | Lo que escribes en el buscador |

## Instalación

Necesitas un Mac con **Xcode** (gratis en la App Store del Mac) y tu Apple ID normal. No hace falta pagar.

### Opción A: desde Xcode

La firma gratuita dura **7 días**; para no tener que repetir el paso 6, activa la renovación automática (más abajo).

1. Descarga el proyecto y abre `TubeShell.xcodeproj`.
2. En Xcode › Ajustes › Cuentas, añade tu Apple ID si no está.
3. Indica tu equipo de firma: crea en la carpeta del proyecto un archivo `Local.xcconfig` (no se sube a git) con
   ```
   DEVELOPMENT_TEAM = TU_ID_DE_EQUIPO
   ```
   El ID está en Xcode › Ajustes › Cuentas › tu Apple ID (Personal Team). Si Xcode dice que el **Bundle Identifier** ya existe, cámbialo por algo tuyo, por ejemplo `es.tunombre.tube`.
4. Conecta el iPhone por cable y desbloquéalo. La primera vez, activa en el iPhone **Ajustes › Privacidad y seguridad › Modo de desarrollador** y reinicia.
5. Arriba en Xcode, elige tu iPhone como destino.
6. Pulsa **▶ (Run)**.
7. Si el iPhone dice «Desarrollador no fiable»: **Ajustes › General › VPN y gestión de dispositivos** › tu Apple ID › **Confiar**.

### Renovación automática desde el Mac

`renew.sh` vuelve a firmar e instalar la app antes de que caduque. Una tarea de launchd lo ejecuta cada hora: cuando quedan menos de 2 días, pide a Apple un perfil nuevo de 7 días, compila e instala. El iPhone tiene que estar conectado por cable o en la misma wifi, y el Mac encendido. Si el último día no lo encuentra, avisa con una notificación.

Indica tu iPhone en un archivo `renew.local` (no se sube a git):

```bash
xcrun devicectl list devices
```

```bash
echo 'DEVICE=TU_IDENTIFICADOR' > renew.local
```

```bash
./renew.sh --install-agent
```

`./renew.sh --force` renueva al momento y `./renew.sh --remove-agent` lo desactiva. El registro está en `~/Library/Logs/TubeShell-renew.log`.

### Opción B: SideStore o AltStore

Instala [SideStore](https://sidestore.io) o [AltStore](https://altstore.io), genera el IPA sin firmar con `./make_ipa.sh` y ábrelo con ellos en el iPhone. Ellos se encargan de renovar la firma cada semana. Con una cuenta gratuita puedes tener hasta 3 apps instaladas así.

## Cuando vuelvan a aparecer anuncios

YouTube cambia su web de vez en cuando. Todo el bloqueo está en `TubeShell/Resources/`:

- **`Shields.js`**: los scripts. Es el que habrá que tocar casi siempre.
- **`ContentRules.json`**: las reglas de red.

Para inspeccionar la app desde el Mac, activa en Safari **Ajustes › Avanzado › Mostrar funciones para desarrolladores web** y, con el iPhone conectado y la app abierta, abre **Desarrollo › tu iPhone › m.youtube.com** (o music.youtube.com).

Las reglas de referencia son las de la [lista de Brave para iOS](https://github.com/brave/adblock-lists/blob/master/brave-lists/brave-ios-specific.txt) y los [quick-fixes de uBlock Origin](https://github.com/uBlockOrigin/uAssets/blob/master/filters/quick-fixes.txt).

## Cómo está hecho

Una app UIKit con dos `WKWebView` (más una tercera para el reproductor de YouTube) que cargan las webs móviles oficiales. `Shields.js` se inyecta al inicio de cada página para quitar los anuncios de los datos antes de que el reproductor los vea, ocultar elementos y añadir las funciones de la cápsula. La parte nativa añade la cápsula, el minirreproductor, el buscador, Siri y la sesión de audio.

```
TubeShell/
├── AppDelegate.swift          Sesión de audio (segundo plano)
├── SceneDelegate.swift        Ventana y accesos rápidos
├── Shortcuts.swift            Atajos de Siri y enlaces de fuera (tube://)
├── AppTab.swift               Las dos pestañas, sus direcciones y las claves guardadas
├── MainViewController.swift   Cápsula, pestañas y temporizador
├── MainViewController+Player.swift  Reproductor de YouTube y minirreproductor
├── MainViewController+Menus.swift   Menús de la cápsula (⋯, velocidad, calidad, compartir)
├── SearchViewController.swift Buscador propio, con sugerencias y voz
├── LyricsViewController.swift Letra sincronizada (LRCLIB)
├── WebTab.swift               Vista web configurada como Brave, enlaces, sin conexión
├── ContentRules.swift         Compila las reglas de red (en caché)
├── Info.plist                 Audio en segundo plano, accesos rápidos, micrófono
├── Assets.xcassets            Icono
└── Resources/
    ├── Shields.js             Bloqueo de anuncios y funciones de página
    └── ContentRules.json      Bloqueo de red
make_ipa.sh                    Genera el IPA para SideStore/AltStore
renew.sh                       Renueva la firma cada semana (launchd)
Signing.xcconfig               Lee tu equipo de firma de Local.xcconfig
```

## Problemas conocidos

- **Google no deja iniciar sesión**: la app se identifica como Safari, que suele bastar. Si aun así lo rechaza, inicia sesión desde la otra pestaña.
- **Un anuncio suena entero**: si va incrustado en la propia canción, no se puede saltar sin saltarse la canción, así que solo se silencia.
- **Algo se ve descolocado**: YouTube cambia su web y algunos ajustes de diseño dependen de ella. Abre una incidencia con una captura.

## Licencia

[MIT](LICENSE). Las técnicas de bloqueo se basan en las listas públicas de Brave y uBlock Origin; SponsorBlock y DeArrow usan la API pública de [sponsor.ajay.app](https://sponsor.ajay.app), y la letra viene de [LRCLIB](https://lrclib.net). Las capturas son del simulador de iOS, sin cuenta iniciada.
