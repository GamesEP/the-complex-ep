# The loop

Status: drafted

> Three scales. Most games only need the first two written down carefully.

## The moment

> The thing a player does over and over, measured in seconds. Aim, hide, place, jump, trade. If
> this is not fun on its own with no progression attached, nothing further down saves it.

Pelear contra una horda en una sala: encadenar el combo del ataque básico, esquivar con el dash
y lanzar habilidades cuando salen de recarga. Ver Combate en [systems.md](systems.md).

La alta velocidad la definen **el movimiento del personaje y sus ataques**: correr, saltar,
hacer dash y encadenar golpes tiene que ser rápido y fluido. El dash es un movimiento básico, como
el ataque, no una habilidad: está siempre disponible desde el primer segundo.

## The round

> One complete unit of play, start to end, as a numbered sequence. Every duration names its
> Config key. This is the section a round-loop implementation is built from, so it has to be
> unambiguous about who decides what, and when.

1. Hub: el jugador aparece solo, sin grupo. Desde la lista de jugadores del servidor entra a un
   grupo abierto, invita a otros o acepta una invitación (ver Grupos en
   [systems.md](systems.md)). También puede salir solo.
2. El líder inicia la run. El grupo se cierra y se teletransporta a un servidor privado para la
   run.
3. La run recorre The Complex planta a planta. En cada planta el grupo limpia una o varias salas
   de combate. Al limpiar una sala, cada jugador elige 1 de 3 mejoras al azar (ver Mejoras de
   run en [systems.md](systems.md)). Todos empiezan la run iguales: la variedad sale de esas
   elecciones.
   - Al empezar la run, cada jugador elige 1 de 3 habilidades al azar
     (`Config.START_ABILITY_CHOICES`). Es la primera decisión de la run y la que hace que dos
     runs no empiecen igual.
   - Una run tiene 5 plantas (`Config.FLOORS_PER_RUN`). Es un valor de prueba, pensado para
     testear la run completa rápido; no es el tamaño definitivo.
   - El juego nunca se pausa para elegir: ni al empezar ni al limpiar una sala. Los enemigos
     siguen activos mientras se elige, para que el ritmo no se corte. Las elecciones que el
     jugador no hace se guardan en cola; al pasar de planta, las que sigan pendientes se
     resuelven al azar (ver Mejoras de run en [systems.md](systems.md)).
   - Cada planta tiene 5 salas (`Config.ROOMS_PER_FLOOR`).
   - El jefe es OhMyGon: sus tres partes (Oh, My, Gon) se pelean por separado en plantas
     anteriores, y en la planta 5 se fusionan en una pelea de dos fases (ver
     [content.md](content.md)).
   - Un jugador que cae puede ser revivido por sus compañeros (ver Muerte y revivir en
     [systems.md](systems.md)).
   - <Duración objetivo de una run completa.>
4. La run termina con **victoria** al derrotar a OhMyGon en la planta 5, o con **derrota** cuando
   todo el grupo ha caído y nadie paga el revivir del grupo en 20 segundos.
5. El grupo vuelve al hub con la moneda permanente ganada.

La moneda permanente se gana por lo avanzado, se gane o se pierda la run. Lo que importa es que
siempre haya progresión: una run fallida nunca es tiempo tirado.

**What a player who joins mid-round sees:** nadie se une a una run empezada. Quien quiera jugar
con ese grupo espera en el hub a que vuelva.

**What happens when too few players remain:** la run sigue mientras quede al menos un jugador en
pie, aunque sea uno solo. **Open:** si un jugador abandona la run (se sale del juego), ¿la
dificultad de las salas siguientes baja para los que quedan? Bloquea el escalado de enemigos.

## The session

> Why somebody plays a second round, and a fifth. If the honest answer is "they do not", the
> game ends after one round and that is a finding worth having now rather than at launch.

<...>
