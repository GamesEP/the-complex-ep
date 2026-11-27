# The Complex

Status: agreed

## Qué es

Un hack&slash cooperativo de alta velocidad para 1 a 4 jugadores (`Config.PARTY_MAX_PLAYERS`),
con cámara isométrica, que se juega en PC, móvil y consola. Es semi-roguelite: cada run empieza
desde cero y las mejoras conseguidas dentro de ella se pierden al terminar, pero la run da una
moneda que compra mejoras permanentes.

Lo que lo diferencia de otros hack&slash (Hades, Diablo u otros de Roblox) es la combinación de:
- **Ritmo sin pausas:** ni pelear contra hordas ni elegir mejoras detiene la acción.
- **Todos empiezan iguales:** el mismo kit base para todo el grupo; cada build se arma desde cero
  durante la run.
- **Acción cooperativa contra un mismo obstáculo:** de 1 a 4 jugadores peleando juntos para superar
  a los jefes, con controles pensados desde el inicio para PC, móvil y consola.

## La idea, en una línea

Hasta cuatro jugadores se abren paso a toda velocidad por The Complex, destrozando hordas en cada
planta y volviendo más fuertes después de cada run.

## Secciones

| | |
|---|---|
| [pillars.md](pillars.md) | Las tres o cuatro cosas de las que trata el juego, y lo que descartan |
| [loop.md](loop.md) | Qué hace el jugador segundo a segundo, en una run y entre runs |
| [systems.md](systems.md) | Cada sistema: sus reglas, sus números, la carpeta de la feature que lo implementa |
| [progression.md](progression.md) | Economía, mejoras permanentes y qué hace volver al jugador mañana |
| [content.md](content.md) | Los datos: mapas, armas, personajes, enemigos |
| [ui.md](ui.md) | Cada pantalla y lo que muestra |
| [technical.md](technical.md) | Jugadores por servidor, plataformas, persistencia, presupuesto de rendimiento |
| [scope.md](scope.md) | Hitos: qué entra en la v1 y qué queda fuera explícitamente |

## Estado de un vistazo

| Sección | Estado | Nota |
|---|---|---|
| pillars | agreed | 3 pilares con descartes y fantasía definidos |
| loop | agreed | run de 5 plantas × 5 salas (15–20 min), momento, run, abandono (`HS-03`) y motivos de sesión cerrados |
| systems | agreed | Combate, Mejoras de run, Hub, Grupos (`HS-03`) y Abatido/Revivir (`HS-04`) cerrados; solo queda pendiente el detalle de pago de 10 Robux para monetización |
| progression | drafted | fuentes de moneda, árbol, habilidades, ventajas y Robux decididos; faltan cantidades y detalle de nodos (hito v1) |
| content | agreed | 6 arquetipos de enemigo (`HS-01`), 4 jefes Oh/My/Gon/OhMyGon (`HS-02`), estructura de salas y dificultad cerrados |
| ui | agreed | CombatHud, UpgradeChoice (banner superior 1-de-3 sin pausa) y RunResult cerrados para Corte jugable y Hito 2; pantallas de Hub/Árbol pendientes de sus hitos |
| technical | agreed | 25 enemigos simultáneos, 30 FPS móvil / 60 FPS PC, Streaming OFF, `Config.HUB_MAX_PLAYERS = 24` (`HS-03`), entrada unificada y descartes técnicos cerrados |
| scope | agreed | Corte jugable (programado y ampliado: 4 tipos de enemigo, 3 habilidades, bloqueo/parry, drops), Hito 2 (Una planta con Oh alineado con content.md), v1 e hitos cerrados |

## Preguntas abiertas

### Corto plazo (Corte jugable → Hito 2)
- **Resuelto (VS-01):** Se mantiene intacto el **Pilar 1** (*todos empiezan iguales*): se retiran las clases fijas de prueba; todos inician con la espada básica, estadísticas iguales y 0 habilidades activas, armando su build desde cero con las elecciones 1-de-3 al inicio y al limpiar cada sala (usando el pool completo de 9 habilidades activas, mejoras de stats y pasivas de movimiento).
- **Resuelto (VS-02):** El Coloso mantiene la combinación embestida → agarre inmediato (esquivable con Dash tras el aturdimiento) y el jefe **Oh** es inmune al hitstun (solo responde a stuns duros al 50% de duración).
- **Resuelto (VS-12 / VS-21):** Al limpiar una sala se abre la puerta blindada norte para pasar manualmente a la siguiente; en PC las tarjetas 1-de-3 se eligen con **`Q` / `E` / `F`** (además de clic/toque/mando).
- **Open:** los números de ajuste del combate (velocidad, dash, combo, vida, daño). No bloquean el código: se ajustan jugando en Studio.

### Hitos posteriores (Run completa, Grupos y v1)
- **Resuelto (`HS-01`–`HS-04`):** Definidos **Artillero** (`area`) y **Voltaico** (`contact`), ataques de **My**, **Gon** y **OhMyGon** (2 fases) en [content.md](content.md); `HUB_MAX_PLAYERS = 24`, `PARTY_INVITE_SECONDS = 20`, privado solo por invitación, traspaso automático de líder, re-escalado por abandono y reglas de revivir (`8` studs, `5 s`, sin reinicio por daño normal, `50%` HP) en [systems.md](systems.md), [loop.md](loop.md) y [technical.md](technical.md).
- **Open:** nombre y cantidades de moneda permanente, ramas del árbol y tipo de duplicador/buffos de Robux ([progression.md](progression.md)). Bloquea el hito de v1.
