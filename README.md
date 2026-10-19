# Tube: YouTube y YouTube Music sin anuncios en el iPhone

App propia para iPhone que abre **YouTube** y **YouTube Music** a pantalla completa, en dos pestañas, con el mismo bloqueo de anuncios que aplica Brave Shields y con audio en segundo plano.

No es Brave, pero hace lo mismo que Brave en estas dos webs: usa la misma vista web de WebKit y las mismas técnicas de bloqueo, sacadas de sus listas de filtros por defecto.

> **Proyecto personal, sin relación con YouTube ni Google.** Se compila e instala en tu propio iPhone con tu Apple ID; no se distribuye en la App Store. Bloquear anuncios o reproducir en segundo plano puede ir contra las condiciones de uso de YouTube: úsalo bajo tu responsabilidad. Si quieres apoyar a los creadores, YouTube Premium es la vía oficial.

## Qué hace

| Función | Cómo |
|---|---|
| Pantalla completa, icono propio | App nativa, sin barras de navegador |
| YouTube y Music en una sola app | Cápsula negra que amplía la isla dinámica: ▶︎ ♪ a la izquierda; cambiar de pestaña no recarga ni corta la música |
| Accesos rápidos | Mantén pulsado el icono: «Abrir Music» o «Abrir YouTube» |
| Recuerda dónde estabas | Al abrir vuelve a la pestaña y a la página (vídeo, canción, búsqueda) de cada pestaña |
| Bloqueo de anuncios | `Shields.js`: los mismos scriptlets que Brave/uBlock (`set` y `json-prune` sobre `adPlacements`, `playerAds`, `adSlots`) más un plan B que silencia y salta anuncios |
| Bloqueo de red | `ContentRules.json`: vídeos de anuncio de googlevideo (regla de Brave para iOS) y dominios de publicidad de Google |
| Audio con el iPhone bloqueado | Modo de audio en segundo plano + el script de Brave que reanuda lo que iOS pausa al bloquear |
| Controles en la pantalla de bloqueo | Los da WebKit a partir de los datos que publica YouTube Music |
| Sin avisos de Premium | Oculta los pop-ups de «Prueba Premium» de YouTube Music |
| Una sola sesión | Inicias sesión en Google una vez y vale para las dos pestañas |
| Imagen en imagen | Activada en los vídeos de YouTube |
| Siguiente / anterior en la pantalla bloqueada | En Music, en lugar de los saltos de 10 segundos |
| SponsorBlock | Salta patrocinios, autopromoción y «suscríbete» en YouTube, y las partes sin música en Music. Solo se envía un prefijo del hash del vídeo |
| Sin Shorts | Ocultos en portada, búsquedas y barra inferior; un enlace a un Short se abre como vídeo normal |
| Temporizador para dormir | Luna a la derecha de la isla: 15/30/45/60 min (con cuenta atrás) o al acabar la canción |
| Sin cabeceras | YouTube y Music sin barra de arriba: buscar (🔍), cuenta, secciones, compartir y subtítulos están en la cápsula de la isla |
| Velocidad y calidad | Menú ⋯: velocidad 0,75×–2× (YouTube y Music) y calidad Automática/720p/1080p/1440p/2160p/Máxima (YouTube, hasta 4K60 HDR sin Premium). Music ya recibe el mejor audio gratuito (Opus, formato 251); el de 256 kbps es solo para Premium |
| Ahorro de datos | Con datos móviles (o Modo de datos reducidos) los vídeos van a 480p; con wifi, la calidad elegida. Cambia solo, también a mitad de vídeo. Se desactiva en ⋯ › Calidad |
| Pantalla completa del vídeo | El botón de pantalla completa de YouTube usa su propio reproductor (controles, subtítulos, SponsorBlock) |
| Sin «Abrir app» | Ocultos los «Open App» / «Abrir aplicación» y los banners de descarga de la app |
| Gestos en Music | En el reproductor completo: deslizar la carátula = siguiente/anterior; tocarla = letras en grande; deslizar hacia abajo = minirreproductor |
| Siri y Atajos | «Oye Siri, pon mi música en Tube», «Abre Music en Tube», «Temporizador de Tube» (también en la app Atajos) |
| Compartir en el minuto | Menú ⋯ › «Compartir en este minuto»: enlace youtu.be que empieza donde vas |
| Subtítulos | Desactivados por defecto (también en las vistas previas); menú ⋯ › Subtítulos los activa y se recuerda |
| AirPlay | Menú ⋯ › AirPlay: enviar a la tele o a un altavoz |
| Minirreproductor | Los vídeos se abren en un reproductor encima de la lista (como en la app de YouTube), así la lista nunca se recarga. Arrastra el vídeo hacia abajo (recto o en diagonal): sigue sonando en una ventanita que puedes mover a donde quieras, con tu lista justo donde la dejaste. Tócala para volver, botón central para pausar, × o lánzala a la derecha para cerrar |
| Buscador | 🔍 abre un buscador propio con búsquedas recientes y micrófono; mantener 🔍 pulsado busca por voz |
| Pantalla completa | Gira el iPhone en un vídeo y se pone a pantalla completa; vertical, sale. Al salir sigue sonando |
| Más cómodo | Vibración suave al tocar, mantener ♪ para reanudar la última canción, deslizar hacia abajo para recargar, pantalla «Sin conexión» que se recarga sola |
| Volver atrás | Gesto del borde izquierdo. Si no hay página anterior (la app se abrió en ese vídeo), vuelve a la última búsqueda o al inicio; en Music baja primero el reproductor completo |

## Instalación

Necesitas un Mac con **Xcode** (gratis en la App Store del Mac) y tu Apple ID normal. No hace falta pagar.

### Opción A: instalar directamente desde Xcode (para probar)

La firma dura **7 días**. Pasado ese plazo la app no abre hasta que repites el paso 5, pero no pierdes la sesión ni los ajustes.

1. Abre `TubeShell.xcodeproj` con doble clic.
2. En Xcode › Ajustes › Cuentas, añade tu Apple ID si no está.
3. Indica tu equipo de firma: crea en la carpeta del proyecto un archivo `Local.xcconfig` (no se sube a git) con
   ```
   DEVELOPMENT_TEAM = TU_ID_DE_EQUIPO
   ```
   El ID está en Xcode › Ajustes › Cuentas › tu Apple ID (Personal Team). También puedes elegir **Team** en **Signing & Capabilities**, pero entonces no subas ese cambio del proyecto.
   - **Bundle Identifier**: si Xcode dice que ya existe, cámbialo por algo tuyo, por ejemplo `es.tunombre.tube`.
4. Conecta el iPhone por cable y desbloquéalo. La primera vez:
   - En el iPhone: **Ajustes › Privacidad y seguridad › Modo de desarrollador** › activar y reiniciar.
   - Arriba en Xcode, elige tu iPhone como destino.
5. Pulsa **▶ (Run)**.
6. Si el iPhone dice «Desarrollador no fiable»: **Ajustes › General › VPN y gestión de dispositivos** › tu Apple ID › **Confiar**.

### Renovación automática desde el Mac

`renew.sh` vuelve a firmar e instalar la app antes de que caduque. Una tarea de launchd lo ejecuta cada hora; cuando quedan menos de 2 días, pide a Apple un perfil nuevo de 7 días, compila e instala en el iPhone. Necesita que el iPhone esté conectado por cable o en la misma wifi que el Mac, y que el Mac esté encendido. Si el último día no lo encuentra, avisa con una notificación.

Primero indica tu iPhone en un archivo `renew.local` (no se sube a git):

```bash
xcrun devicectl list devices                     # copia el identificador de tu iPhone
echo 'DEVICE=TU_IDENTIFICADOR' > renew.local
```

```bash
./renew.sh --install-agent   # activar (una vez)
./renew.sh --force           # renovar ya
./renew.sh --remove-agent    # desactivar
```

Registro en `~/Library/Logs/TubeShell-renew.log`.

### Opción B: SideStore o AltStore (renovación automática)

Para olvidarte de los 7 días, instala la app a través de SideStore o AltStore, que la vuelven a firmar solos cada semana.

1. Instala [SideStore](https://sidestore.io) (renueva desde el propio iPhone) o [AltStore](https://altstore.io) (renueva cuando el iPhone y el Mac están en la misma wifi). Sigue la guía de su web.
2. En el Mac, abre Terminal en esta carpeta y ejecuta:
   ```bash
   ./make_ipa.sh
   ```
   Genera `TubeShell.ipa`, sin firmar.
3. Pasa `TubeShell.ipa` al iPhone (AirDrop o Archivos) y ábrelo con SideStore o AltStore.

Con una cuenta gratuita puedes tener hasta 3 apps instaladas así a la vez.

## Primera prueba: las tres funciones

1. **Pantalla completa**: abre la app desde su icono. No debe verse ninguna barra de navegador.
2. **Inicia sesión** en la pestaña Music (avatar › Iniciar sesión).
3. **Anuncios**: reproduce 10 o 15 canciones seguidas y algún vídeo en la pestaña YouTube. No debería sonar ni verse ningún anuncio. Si alguno se cuela, debería quedar en silencio y saltarse solo.
4. **Segundo plano**: pon una canción, bloquea el iPhone y espera un par de minutos. Debe seguir sonando y aparecer en la pantalla de bloqueo con carátula y botones. Prueba pausa, siguiente y anterior desde ahí.
5. **Cambio de pestaña**: con música sonando, abre la pestaña YouTube. La música sigue; al reproducir un vídeo, la música se pausa sola.

## Cuando vuelvan a aparecer anuncios

YouTube cambia su web de vez en cuando. Todo el bloqueo está en dos archivos de `TubeShell/Resources/`:

- **`Shields.js`**: los scripts. Es el que habrá que tocar casi siempre.
- **`ContentRules.json`**: las reglas de red.

Para ver qué pasa dentro de la app desde el Mac:

1. En Safari del Mac: **Ajustes › Avanzado › Mostrar funciones para desarrolladores web**.
2. Con el iPhone conectado y la app abierta: menú **Desarrollo › tu iPhone › music.youtube.com**.

Se abre el inspector web, igual que en un navegador de escritorio.

Las reglas de referencia son las mismas que usa Brave. Para saber qué han cambiado, mira:

- La [lista de Brave para iOS](https://github.com/brave/adblock-lists/blob/master/brave-lists/brave-ios-specific.txt).
- Los [quick-fixes de uBlock Origin](https://github.com/uBlockOrigin/uAssets/blob/master/filters/quick-fixes.txt).

Tras cambiar algo, vuelve a instalar (Run en Xcode, o `./make_ipa.sh` y reinstalar el IPA).

## Archivos

```
TubeShell/
├── AppDelegate.swift          Sesión de audio (reproducción en segundo plano)
├── SceneDelegate.swift        Ventana y accesos rápidos del icono
├── AppTab.swift               Las dos pestañas y sus direcciones
├── MainViewController.swift   Pestañas, cambio entre ellas, pausar la otra
├── WebTab.swift               Vista web configurada como Brave + gestión de enlaces
├── ContentRules.swift         Compila las reglas de red al arrancar
├── Info.plist                 Modo audio en segundo plano, accesos rápidos
├── Assets.xcassets            Icono
└── Resources/
    ├── Shields.js             Bloqueo de anuncios por scripts (lo principal)
    └── ContentRules.json      Bloqueo de red
make_ipa.sh                    Genera el IPA para SideStore/AltStore
renew.sh                       Renueva la firma e instala en el iPhone (launchd, cada hora)
Signing.xcconfig               Lee tu equipo de firma de Local.xcconfig (no versionado)
```

## Problemas conocidos

- **Google no deja iniciar sesión**: la app se identifica como Safari, que es lo que suele bastar. Si Google aun así rechaza el navegador, inicia sesión en la pestaña YouTube en lugar de en Music, o al revés.
- **Un anuncio suena entero**: si va incrustado dentro de la propia canción, el plan B no puede saltarlo sin saltarse también la canción, así que solo lo silencia.

## Licencia

[MIT](LICENSE). Las técnicas de bloqueo se basan en las listas públicas de Brave y uBlock Origin; SponsorBlock usa la API pública de [sponsor.ajay.app](https://sponsor.ajay.app).
