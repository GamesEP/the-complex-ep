# Restricciones técnicas

Status: drafted

> The decisions that are expensive to reverse. Each one here is a thing that, changed in month
> four, invalidates work — which is exactly why they are written down in week one.

| | |
|---|---|
| Jugadores por grupo | 1 a 4 (`Config.PARTY_MAX_PLAYERS`). Se puede jugar solo. |
| Jugadores por servidor | Dos tipos de servidor. **Hub**: <n> jugadores (`Config.HUB_MAX_PLAYERS`), cada uno sin ver a los demás. **Run**: un servidor privado reservado por run, con solo ese grupo (1 a 4). |
| Plataformas | PC, móvil y consola. Las tres tienen que poder jugar una run completa. |
| Entrada | Teclado y ratón, táctil y mando. Ningún control puede existir en una sola de las tres. |
| Cámara | Isométrica, desde arriba, fija en diagonal. Se ve a todo el grupo y a la horda a la vez. |
| Streaming | <on/off, and why> |
| Persistencia | La moneda permanente y las mejoras compradas con ella. Nada de lo ganado dentro de una run se guarda. |

## Presupuesto de rendimiento

> What must hold on the weakest device on the platform list. A budget nobody wrote down is a
> budget nobody is holding to.

Como el juego incluye móvil, el presupuesto se mide en el móvil más débil que queramos soportar,
no en PC.

**Open:** cuántos enemigos en pantalla a la vez como máximo, y a cuántos FPS en móvil. Bloquea el
sistema de oleadas/enemigos.

## Lo que deliberadamente no soportamos

<...>

**Open:** cuántos jugadores por servidor de hub (`Config.HUB_MAX_PLAYERS`). Bloquea la pantalla
de la lista.
