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
| loop | agreed | run de 5 plantas × 5 salas (15–20 min), momento, run y motivos de sesión cerrados; solo queda abierto escalado por abandono (hito Grupos) |
| systems | drafted | Combate y Mejoras de run cerrados para el corto plazo; quedan abiertas decisiones de Hub, Grupos y Muerte/revivir (hitos posteriores) |
| progression | drafted | fuentes de moneda, árbol, habilidades, ventajas y Robux decididos; faltan cantidades y detalle de nodos (hito v1) |
| content | drafted | estructura de salas, plantas de Oh/My/Gon/OhMyGon y Detonante cerrados; faltan ataques de jefes (Oh bloquea cierre de Hito 2) y reglas del Coloso |
| ui | agreed | CombatHud, UpgradeChoice (banner superior 1-de-3 sin pausa) y RunResult cerrados para Corte jugable y Hito 2; pantallas de Hub/Árbol pendientes de sus hitos |
| technical | agreed | 25 enemigos simultáneos, 30 FPS móvil / 60 FPS PC, Streaming OFF, entrada unificada y descartes técnicos cerrados; solo falta `Config.HUB_MAX_PLAYERS` (hito Grupos) |
| scope | agreed | Corte jugable (programado y ampliado: 4 tipos de enemigo, 3 habilidades, bloqueo/parry, drops), Hito 2 (Una planta con Oh alineado con content.md), v1 e hitos cerrados |

## Preguntas abiertas

### Corto plazo (Corte jugable → Hito 2)
- **Open:** ataques concretos del jefe **Oh** en [content.md](content.md). Bloquea el cierre del
  Hito 2 (no bloquea pulir el Corte jugable ni construir salas y mejoras 1-de-3).
- **Open:** los números de ajuste del combate (velocidad, dash, combo, vida, daño). No bloquean el
  código: se ajustan jugando en Studio.

- **Decidido y programado:** 3 clases de prueba (Tanque, Daño, Apoyo) elegidas en una pantalla
  previa ([systems.md](systems.md), sección Clases).
- **Open:** cómo conviven las clases con las mejoras de 1 de 3 de la run
  ([pillars.md](pillars.md)). Bloquea Mejoras de run.

### Hitos posteriores (Run completa, Grupos y v1)
- **Open:** ataques de My, Gon y fases 1/2 de OhMyGon ([content.md](content.md)). Bloquea Run en
  solitario.
- **Open:** reglas del enemigo Coloso ([content.md](content.md)). Bloquea Run en solitario /
  Grupos.
- **Open:** `Config.HUB_MAX_PLAYERS`, solicitudes de grupo privado, expulsión/traspaso de líder,
  reconexión, escalado por abandono y detalles de revivir ([systems.md](systems.md),
  [loop.md](loop.md), [technical.md](technical.md)). Bloquea el hito de Grupos.
- **Open:** nombre y cantidades de moneda permanente, ramas del árbol y tipo de duplicador/buffos
  de Robux ([progression.md](progression.md)). Bloquea el hito de v1.
