# Contenido

Status: drafted

## Mapas

| Nombre | Tamaño | Notas |
|---|---|---|
| Hub | <...> | Donde aparece el jugador y arma su grupo. Cada jugador lo ve vacío. |
| The Complex (Sala de combate) | 140 × 140 studs (`Config.ROOM_SIZE`), 5 plantas × 5 salas en v1 | Complejo industrial sci-fi (`assets/models/ComplexArena.rbxmx`): hormigón oscuro, acero, franjas de peligro amarillas, puerta blindada de sector en el muro norte, ventanal de observación en el muro oeste, tuberías elevadas, plataforma de elevador central y bordes frontales recortados para visibilidad isométrica. Ver [loop.md](loop.md). |

> Maps live as tracked models under `assets/`. Spawns on one are offsets from the model's
> pivot, never world positions — see [CLAUDE.md](../../CLAUDE.md#two-kinds-of-world-and-which-rule-applies).

**Estructura de salas por planta:**
- En el **Hito 2 (MVP de una planta)**, las 5 salas se juegan en **orden fijo**, diseñadas a mano
  para validar ritmo, combate, elecciones de 1 de 3 y jefe.
- En la **run completa (5 plantas)**, las salas normales de cada planta se eligen al azar de un
  pool propio de la planta, manteniendo la sala 5 reservada al jefe cuando esa planta tiene jefe.

## Jefes

Por ahora hay un solo jefe: **OhMyGon**. Se pelea por partes a lo largo de la run y entero al
final. La **Planta 1 no tiene jefe** (sirve para calentar y armar las primeras mejoras de la run),
y cada jefe ocupa la última de las 5 salas de su planta (no hay sala extra).

| Jefe | Dónde aparece | Notas |
|---|---|---|
| Oh | Planta 2 | Primera parte de OhMyGon, peleada sola. También cierra la planta de prueba del Hito 2 para validar salas + jefe juntos (ver [scope.md](scope.md)). |
| My | Planta 3 | Segunda parte, peleada sola. |
| Gon | Planta 4 | Tercera parte, peleada sola. |
| OhMyGon | Planta 5 (la última) | Oh, My y Gon fusionados. Dos fases. |

Pelear las tres partes por separado antes enseña al grupo los ataques de cada una, para que en la
fusión reconozca lo que está viendo.

**Open:** qué ataques tiene cada parte (Oh, My, Gon) y qué cambia de la fase 1 a la fase 2 de
OhMyGon. Los ataques de Oh bloquean el cierre del Hito 2; los de My, Gon y OhMyGon bloquean el
hito de Run en solitario.

## Enemigos

Cada tipo obliga al grupo a hacer algo distinto; una sala se diseña mezclándolos.

| Tipo | Qué hace | Qué le pide al jugador |
|---|---|---|
| **Centinela** (cuerpo a cuerpo) | Unidades de asalto blindadas del Complejo en 4 variantes de arma (`EnemyMelee` espada + escudo, `EnemyMeleeDual` espadas dobles, `EnemyMeleeAxe` hacha pesada y `EnemyMeleeMace` mazo triturador), con animaciones procedurales de caminar, ataque según el arma y muerte. Las unidades con **una sola espada (`EnemyMelee`)** activan **Paso Fantasma**: muestran un icono triangular amarillo (`!`) sobre la cabeza, encadenan al menos **3 desplazamientos ultrarrápidos en distintas direcciones** dejando estelas neón de silueta para rodear y lanzar un **tajo sorpresa inesquivable** (`15` de daño, ignora i-frames de Dash, salto y bloqueo pasivo; **solo puede evitarse haciendo Parry** a tiempo tras el destello). Las unidades con **espadas dobles** ejecutan un **ataque giratorio DPS** periódico (`1,6 s`, ticks de 6 de daño cada `0,25 s` en radio de 8 studs). Las unidades con **mazo (`EnemyMeleeMace`)** alzan el mazo por encima de la cabeza (`0,78 s`, anillo sísmico de aviso en el suelo) y **golpean el suelo** desatando una onda de `15,5` studs (`14` de daño) que **tambalea y aturde** a los jugadores alcanzados durante `1,6 s` (`0,7 s` al bloquear). | Hacer **Parry obligatorio** al remate de Paso Fantasma para aturdir al atacante; **saltar** o usar **Dash** para evitar la onda sísmica del mazo; esquivar o hacer Parry al resto de golpes y al giro de espadas dobles. |
| **Cazador** (a distancia) | Tiradores blindados del Complejo en 4 variantes: rifle de plasma (`EnemyRanged`) y cañón de plasma (`EnemyRangedCarbine`), capaces de **cargar al máximo poder su arma con un láser guía cilíndrico que fija su línea en rojo (`0,4 s` antes de disparar) y lanza un rayo cilíndrico devastador** (`32`/`28` de daño); escopeta de energía (`EnemyRangedShotgun`, **disparo doble** por ataque); y variante ocasional con **metralleta rotativa** (`EnemyRangedMinigun`) que dispara **ráfagas repetidas de 6 líneas trazadoras rápidas**. Si el jugador se acerca a menos de `11` studs, **retroceden dando un salto evasivo rápido** (`20` studs, enfriamiento de `5,5 s`). | Salir lateralmente, saltar o usar Dash al fijarse el rayo cargado (o bloquearlo), ir a por el tirador tras forzar su salto evasivo, saltar disparos normales o devolver bolas/trazadoras con Parry. |
| En área | Ataca una zona marcada en el suelo. | Salir de la zona a tiempo. |
| Por contacto | Hace daño al tocarlo. | No chocar con él; atacarlo sin pegarse. |
| **Detonante** (explosivo) | Corredor rápido con carga C4 y cartuchos de TNT pegados al cuerpo (`EnemyExploder`), con animación de carrera frenética, mecha temblorosa y muerte. Su explosión ovalada daña tanto a jugadores cercanos como a otros enemigos dentro del radio (`Config.ENEMY_KINDS.exploder.enemyDamage`). | Matarlo de lejos, alejarse (o saltar cerca del borde), o atraerlo hacia un grupo de enemigos para usar su explosión a favor. |
| **Coloso** (agarrador) | Juggernaut grande y musculoso (`EnemyGrabber`, 6,2 studs) con animación de pisada pesada, carga de embestida, **embestida rápida para atrapar** (`lunge`), abrazo opresivo al sujetar y muerte. Avisa con un **icono triangular amarillo (`!`)** sobre la cabeza y embiste; si atrapa al jugador, lo inmoviliza quitándole 8 de vida por segundo (`Config.ENEMY_KINDS.grabber.grabDamagePerSecond`). Si el jugador se mantiene fuera de su alcance de agarre (entre `16` y `34` studs), hace una **embestida de toro**: se agacha bajando el hombro con brillo rojo y el icono `!` (`0,7 s`), y luego carga en línea recta (`0,6 s`, dirección fijada al arrancar); a quien atropella le quita `12` de vida, lo **lanza unos 18 studs** y lo **aturde `1,3 s`** (enfriamiento de `6,5 s`). Bloquear reduce el daño y deja el empuje y el aturdimiento a la mitad; el Parry no sirve contra un placaje. | Esquivar la embestida con Dash al ver el icono de alerta sobre su cabeza; si queda atrapado, pulsar el botón de ataque 10 veces (`Config.GRAB_ESCAPE_PRESSES`) o recibir ayuda de compañeros atacando al agarrador. Contra la embestida de toro (brillo rojo), **salir de la línea de carga** con un Dash lateral o bloquearla. |

### Vida

Unos enemigos tienen que aguantar más que otros, para que cada tipo tenga su papel: los peligrosos
pero frágiles caen rápido, los Centinelas aguantan más cuanto más pesada es su arma, y
el Coloso es el muro de la oleada. Como retiene a un compañero, derribarlo tiene que ser una
decisión del grupo, no un golpe suelto. Valores de partida, a ajustar jugando:

| Enemigo | Vida | Contra el combo básico (40 de daño) |
|---|---|---|
| Detonante | 15 | 1 golpe |
| Cazador: rifle / escopeta / plasma / minigun | 22 / 26 / 26 / 34 | 1 combo |
| Centinela: espada / doble hoja / hacha / maza | 30 / 36 / 42 / 50 | 1 combo, la maza algo más |
| Coloso | 100 | unos 2,5 combos |

Cada variante de arma puede tener su propia vida (`health` en su entrada de
`Config.ENEMY_KINDS`); si no la define, usa la de su tipo.

**Open:** después de una embestida que acierta, el Coloso puede quedar a distancia de agarre
y agarrar justo cuando termina su recuperación. El aturdimiento (`1,3 s`) acaba antes, así que se
puede esquivar con Dash, pero la combinación embestida + agarre es fuerte. Decidir si se quiere o
si la embestida debe bloquear el agarre durante unos segundos. Bloquea el ajuste del Coloso.

Los números de cada tipo (vida, velocidad, daño, alcance, tiempos) están en
`Config.ENEMY_KINDS`, y las oleadas de la sala de prueba en `Config.WAVES` (5 oleadas; el Coloso
aparece a partir de la oleada 4). Por ahora existen cuatro tipos en el corte de combate: cuerpo a
cuerpo (Centinela), a distancia (Cazador), explosivo (Detonante) y agarrador (Coloso).

El Coloso es el caso extremo: el único enemigo que castiga ir solo, porque un compañero puede
salvarte. En los tres controles (PC, mando y móvil) se escapa pulsando el mismo botón de ataque
(`Attack` -> remoto `GrabEscape`).

- **Ayuda en paralelo:** los compañeros pueden atacar al Coloso en cualquier momento (pulse el
  botón el jugador atrapado o no). Cada golpe de un compañero daña al Coloso y además suma
  progreso de liberación (`Config.GRAB_ALLY_HIT_PROGRESS`); matarlo libera de inmediato.
- **Escape y castigo:** hacen falta **10 pulsaciones** (`Config.GRAB_ESCAPE_PRESSES`) para soltarse,
  y mientras está sujeto pierde **8 HP/s** (`Config.ENEMY_KINDS.grabber.grabDamagePerSecond`). Mientras
  el jugador está atrapado, **el resto de enemigos lo ignoran sin quedarse quietos** (en cooperativo
  siguen persiguiendo a los demás jugadores libres; en solitario merodean por la sala esquivando al
  jugador atrapado) para evitar muertes instantáneas injustas sin congelar la escena. Tras
  liberarse hay 1 s de inmunidad (`Config.GRAB_IMMUNITY_SECONDS`) y el Coloso entra en `recover`.
- **IA táctica de escuadrón y anti-agrupación:** en lugar de lanzarse todos juntos o dejarse
  "hacer bolita" fácilmente, los enemigos se reparten los **360° alrededor del jugador** en
  sectores angulares distintos con cambios impredecibles de flanco cada pocos segundos:
  - **Dispersión y ataque en pinza (melee):** como máximo 2 Centinelas atacan a un
    mismo jugador simultáneamente (`Config.AI_MAX_MELEE_ATTACKERS`), curvando su aproximación
    desde lados opuestos; el resto ocupa sectores distintos en el anillo de flanqueo
    (`Config.AI_FLANK_RADIUS`) y toma el relevo cuando un atacante entra en `recover` (retroceso
    diagonal táctico) o muere. La repulsión cuadrática (`Config.ENEMY_SPACING = 9.5`) impide que
    se apilen en un solo bloque.
  - **Fuego cruzado y cadencia escalonada (Cazadores):** se reparten en sectores opuestos a
    gran separación (`Config.AI_RANGED_SPACING = 16`) y escalonan sus disparos
    (`Config.AI_RANGED_STAGGER_SECONDS`).
  - **Intercepción en arco y emboscada (Detonante y Coloso):** el Detonante combina predicción
    de trayectoria con aproximación curva por su propio sector para cortar el paso, y el Coloso
    rodea hacia el punto ciego antes de embestir.
  - **Reparto cooperativo:** en grupos de 2 a 4 jugadores, los enemigos reparten presión entre el
    equipo (`Config.AI_COOP_CROWD_PENALTY`) en lugar de hacer fila detrás de un único jugador.
- **Fuego amigo del Detonante:** al detonar en un volumen ovalado (`blastRadius` × `blastHeight`),
  daña a cualquier jugador dentro del óvalo y también a los demás enemigos cercanos
  (`Config.ENEMY_KINDS.exploder.enemyDamage`), permitiendo al jugador usar su explosión como ventaja
  táctica. Los enemigos eliminados por la explosión pueden soltar drops normalmente.
