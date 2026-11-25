# Contenido

Status: drafted

> The data, not the systems that read it. If a table here would be better as a real table in
> `Config`, put it in Config and link it — this section then names what exists and why, and the
> game reads the same list the design does.

## Mapas

| Nombre | Tamaño | Notas |
|---|---|---|
| Hub | <...> | Donde aparece el jugador y arma su grupo. Cada jugador lo ve vacío. |
| The Complex | 5 plantas × 5 salas | El edificio de la run. Ver [loop.md](loop.md). |

> Maps live as tracked models under `assets/`. Spawns on one are offsets from the model's
> pivot, never world positions — see [CLAUDE.md](../../CLAUDE.md#two-kinds-of-world-and-which-rule-applies).

**Open:** ¿las salas son fijas, o se eligen al azar de un conjunto de salas en cada run? Bloquea
cómo se construye el mapa de la run.

## Jefes

Por ahora hay un solo jefe: **OhMyGon**. Se pelea por partes a lo largo de la run y entero al
final.

| Jefe | Dónde aparece | Notas |
|---|---|---|
| Oh | <planta> | Primera parte de OhMyGon, peleada sola. |
| My | <planta> | Segunda parte, peleada sola. |
| Gon | <planta> | Tercera parte, peleada sola. |
| OhMyGon | Planta 5 (la última) | Oh, My y Gon fusionados. Dos fases. |

Pelear las tres partes por separado antes enseña al grupo los ataques de cada una, para que en la
fusión reconozca lo que está viendo.

**Open:** ¿en qué planta aparece cada parte? (Propuesta: Oh al final de la planta 2, My al final
de la 3, Gon al final de la 4, y la planta 1 sin jefe para calentar.) Bloquea la estructura de
plantas.

El jefe de una planta ocupa la última de sus 5 salas; no hay sala extra.

**Open:** qué cambia de la fase 1 a la fase 2 de OhMyGon, y qué ataques tiene cada parte.
Bloquea el diseño de los jefes; no bloquea el resto de la run.

## Enemigos

Cada tipo obliga al grupo a hacer algo distinto; una sala se diseña mezclándolos.

| Tipo | Qué hace | Qué le pide al jugador |
|---|---|---|
| Cuerpo a cuerpo | Se acerca y golpea. | Esquivar el golpe y castigar. |
| A distancia | Dispara desde lejos. | Ir a por él o cubrirse. |
| En área | Ataca una zona marcada en el suelo. | Salir de la zona a tiempo. |
| Por contacto | Hace daño al tocarlo. | No chocar con él; atacarlo sin pegarse. |
| Explosivo | Se acerca y explota. Su explosión daña tanto a jugadores cercanos como a otros enemigos dentro del radio (`Config.ENEMY_KINDS.exploder.enemyDamage`). | Matarlo de lejos, alejarse antes de que explote o atraerlo hacia un grupo de enemigos para usar su explosión a favor. |
| Agarrador | Avisa con un telegraph breve (`windup` + alerta en HUD) y, si el jugador no usa Dash, lo agarra e inmoviliza quitándole 8 de vida por segundo (`Config.ENEMY_KINDS.grabber.grabDamagePerSecond`). | Esquivar con Dash durante el aviso; si queda atrapado, pulsar el botón de ataque 10 veces (`Config.GRAB_ESCAPE_PRESSES`) o recibir ayuda de compañeros atacando al agarrador. |

Los números de cada tipo (vida, velocidad, daño, alcance, tiempos) están en
`Config.ENEMY_KINDS`, y las oleadas de la sala de prueba en `Config.WAVES` (5 oleadas; el agarrador
aparece a partir de la oleada 4). Por ahora existen cuatro tipos en el corte de combate: cuerpo a
cuerpo, a distancia, explosivo y agarrador.

El agarrador es el caso extremo: el único enemigo que castiga ir solo, porque un compañero puede
salvarte. En los tres controles (PC, mando y móvil) se escapa pulsando el mismo botón de ataque
(`Attack` -> remoto `GrabEscape`).

- **Ayuda en paralelo:** los compañeros pueden atacar al agarrador en cualquier momento (pulse el
  botón el jugador atrapado o no). Cada golpe de un compañero daña al agarrador y además suma
  progreso de liberación (`Config.GRAB_ALLY_HIT_PROGRESS`); matarlo libera de inmediato.
- **Escape y castigo:** hacen falta **10 pulsaciones** (`Config.GRAB_ESCAPE_PRESSES`) para soltarse,
  y mientras está sujeto pierde **8 HP/s** (`Config.ENEMY_KINDS.grabber.grabDamagePerSecond`). Mientras
  el jugador está atrapado, **el resto de enemigos lo ignoran** (en solitario esperan y en cooperativo
  cambian de objetivo a los compañeros libres) para evitar muertes instantáneas injustas. Tras
  liberarse hay 1 s de inmunidad (`Config.GRAB_IMMUNITY_SECONDS`) y el agarrador entra en `recover`.
- **Fuego amigo del explosivo:** al detonar, daña a cualquier jugador dentro de `blastRadius` y también a los demás enemigos dentro de `blastRadius + enemy.radius` (`Config.ENEMY_KINDS.exploder.enemyDamage`), permitiendo al jugador usar su explosión como ventaja táctica. Los enemigos eliminados por la explosión pueden soltar drops normalmente.
