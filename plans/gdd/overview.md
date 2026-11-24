# The Complex

Status: drafted

> Replace everything in angle brackets. Delete the quoted guidance blocks as you fill each one
> in — they are here to be deleted. [README.md](README.md) is how to write this well, and is
> the one file in this folder that stays.

## Qué es

Un hack&slash cooperativo de alta velocidad para 1 a 4 jugadores (`Config.PARTY_MAX_PLAYERS`),
con cámara isométrica, que se juega en PC, móvil y consola. Es semi-roguelite: cada run empieza
desde cero y las mejoras conseguidas dentro de ella se pierden al terminar, pero la run da una
moneda que compra mejoras permanentes.

**Open:** qué lo diferencia de la comparación obvia (Hades, Diablo, otros hack&slash de Roblox).
Pospuesto a propósito; bloquea los pilares.

## La idea, en una línea

Hasta cuatro jugadores se abren paso a toda velocidad por The Complex, destrozando hordas en cada
planta y volviendo más fuertes después de cada run.

**Open:** esta frase la propuso Claude, no el equipo. Hasta que alguien la confirme o la
reescriba, no es una decisión. (Que The Complex es un edificio que se recorre por plantas sí
está decidido.)

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
| pillars | drafted | sin escribir |
| loop | drafted | run de 5 plantas × 5 salas (valor de prueba), victoria y derrota decididas; falta duración |
| systems | drafted | Hub, Grupos, Combate, Mejoras de run y Muerte y revivir; faltan números y enemigos |
| progression | drafted | fuentes de moneda, árbol de estadísticas, habilidades, ventajas y productos de Robux decididos; faltan cantidades |
| content | drafted | jefe OhMyGon y seis tipos de enemigo; falta en qué planta va cada parte del jefe |
| ui | drafted | sin escribir |
| technical | drafted | grupo, plataformas, cámara y entrada decididos |
| scope | drafted | corte jugable: solo combate en una sala; v1 e hitos escritos |

## Preguntas abiertas

- **Decidido:** hub donde cada jugador está solo y ve a los demás solo en una lista; grupos
  abiertos o privados; la run se juega en un servidor privado por grupo. Ver Hub y Grupos en
  [systems.md](systems.md).
- **Open:** cuántos jugadores por servidor de hub. Bloquea la pantalla de la lista.
- **Open:** qué lo diferencia de la comparación obvia. Bloquea los pilares.
- **Decidido:** la alta velocidad está en el movimiento y los ataques básicos (correr, saltar,
  dash, combo). El corte jugable usa enemigos cuerpo a cuerpo, a distancia y explosivo.
- **Decidido:** la habilidad del corte jugable es el ataque giratorio.
- **Open:** los números del movimiento y del combate (velocidad, dash, combo, vida, daño). No
  bloquean el código: se empieza con valores de prueba y se ajustan jugando.
