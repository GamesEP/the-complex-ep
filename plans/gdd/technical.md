# Restricciones técnicas

Status: agreed

| | |
|---|---|
| Jugadores por grupo | 1 a 4 (`Config.PARTY_MAX_PLAYERS`). Se puede jugar solo. |
| Jugadores por servidor | Dos tipos de servidor. **Hub**: `<n>` jugadores (`Config.HUB_MAX_PLAYERS`), cada uno sin ver a los demás. **Run**: un servidor privado reservado por run, con solo ese grupo (1 a 4). |
| Plataformas | PC, móvil y consola. Las tres tienen que poder jugar una run completa. |
| Entrada | Teclado y ratón, táctil y mando. Ningún control puede existir en una sola de las tres. El apuntado usa dirección de movimiento + asistencia en cono de 120° en las tres plataformas (sin apuntado por cursor). |
| Cámara | Isométrica, desde arriba, fija en diagonal. Se ve a todo el grupo y a la horda a la vez. |
| Streaming | **Off** (`StreamingEnabled = false`). Las salas son cerradas y acotadas, así que la planta cabe en memoria y se evita que paredes, obstáculos o spawns desaparezcan durante el movimiento rápido. |
| Persistencia | La moneda permanente y las mejoras compradas con ella. Nada de lo ganado dentro de una run se guarda. |

## Presupuesto de rendimiento

Como el juego incluye móvil, el presupuesto se mide en el móvil más débil que queramos soportar,
no en PC.

| | |
|---|---|
| Máximo de enemigos activos simultáneos | 25 (`Config.MAX_ACTIVE_ENEMIES`) |
| Objetivo de rendimiento en móvil | 30 FPS estables (mínimo en gama baja) |
| Objetivo de rendimiento en PC | 60 FPS estables |

## Lo que deliberadamente no soportamos

- **Apuntado por cursor de ratón o mecánicas exclusivas de PC:** el combate y la elección 1 de 3
  deben ser igual de jugables en móvil, consola y PC.
- **Unión a mitad de una run:** nadie entra a una run empezada; quien quiera sumarse espera en el
  hub.
- **Mundo abierto o streaming dinámico de mapas:** la acción transcurre en salas cerradas.
- **Primera persona o VR:** el juego se diseña exclusivamente para cámara isométrica.

**Open:** cuántos jugadores por servidor de hub (`Config.HUB_MAX_PLAYERS`). Bloquea la pantalla
de la lista en el hito de Grupos; no bloquea el Corte jugable ni el Hito 2.
