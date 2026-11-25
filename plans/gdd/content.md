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
| Agarrador | Agarra a un jugador y lo inmoviliza. | Pulsar una tecla repetidamente para liberarse; los compañeros pueden liberarlo atacando al agarrador. |

Los números de cada tipo (vida, velocidad, daño, alcance, tiempos) están en
`Config.ENEMY_KINDS`, y las oleadas de la sala de prueba en `Config.WAVES`. Por ahora existen los
tres del corte de combate: cuerpo a cuerpo, a distancia y explosivo.

El agarrador es el caso extremo: el único enemigo que castiga ir solo, porque un compañero puede
salvarte. En móvil, "pulsar una tecla" es tocar repetidamente un botón en pantalla; en mando, un
botón.

**Open:** "el escuadrón puede contribuir atacándolo solo si el jugador no presiona la tecla":
¿significa que el ataque de los compañeros es la alternativa para quien no puede liberarse, o que
los golpes de los compañeros solo cuentan mientras el atrapado no pulsa? (Propuesta: ambas vías
suman a la vez, y la que llegue antes libera.) Bloquea el agarrador.

**Open:** cuántas pulsaciones hacen falta para liberarse (`Config.GRAB_ESCAPE_PRESSES`), y qué
pasa si nadie lo libera (¿daño continuo?). Bloquea el agarrador.

- **Fuego amigo del explosivo:** al detonar, daña a cualquier jugador dentro de `blastRadius` y también a los demás enemigos dentro de `blastRadius + enemy.radius` (`Config.ENEMY_KINDS.exploder.enemyDamage`), permitiendo al jugador usar su explosión como ventaja táctica. Los enemigos eliminados por la explosión pueden soltar drops normalmente.
