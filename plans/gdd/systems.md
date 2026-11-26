# Sistemas

Status: drafted

## Hub

`server/features/hub/`

**Qué hace:** es el mundo donde aparece el jugador al entrar al juego y desde donde arma su grupo.

**Reglas:**

- En el hub cada jugador está solo: no ve los avatares de los demás jugadores del servidor. Los
  demás existen para él únicamente en la lista de jugadores. Así el hub se siente como su
  espacio propio, y el grupo es algo que elige formar, no gente que se le cruza.
- La lista muestra a los jugadores conectados a ese mismo servidor de hub, nada más. Ver
  jugadores de otros servidores no está en la v1.

**Números:**

| | |
|---|---|
| Jugadores por servidor de hub | <n> (`Config.HUB_MAX_PLAYERS`) |

**Habla con el cliente mediante:** la lista se arma con los jugadores del servidor; el estado de
grupo de cada uno se publica como atributos del jugador (ver Grupos).

**Open:** cuántos jugadores caben en un servidor de hub. Con pocos, la lista está vacía y no hay
con quién formar grupo; con muchos, la lista es difícil de leer en móvil. Bloquea
`Config.HUB_MAX_PLAYERS` y el diseño de la pantalla de la lista.

---

## Grupos

`server/features/party/`

**Qué hace:** permite formar un grupo de 1 a 4 jugadores en el hub y llevarlo a una run.

**Reglas:**

- Todo jugador empieza sin grupo. Si inicia una run sin grupo, juega solo: un grupo de 1.
- Quien crea el grupo es el líder. Solo el líder inicia la run.
- Un grupo es **abierto** o **privado**, y lo elige el líder.
  - **Abierto:** cualquier jugador del hub puede entrar sin pedir permiso mientras haya sitio.
  - **Privado:** solo se entra por invitación del líder, que el invitado acepta o rechaza.
- El grupo tiene un máximo de 4 jugadores (`Config.PARTY_MAX_PLAYERS`). Un grupo lleno no acepta
  a nadie más, sea abierto o privado.
- Cuando empieza la run, el grupo queda cerrado: nadie entra a mitad de una run. Quien quiera
  sumarse espera a que el grupo vuelva al hub.
- Al iniciar la run, todo el grupo se teletransporta a un servidor privado reservado solo para
  esa run, y vuelve al hub cuando la run termina. Cada run tiene el servidor entero para sus
  hordas, que es lo que deja mantener la velocidad también en móvil.

**Números:**

| | |
|---|---|
| Máximo de jugadores por grupo | 4 (`Config.PARTY_MAX_PLAYERS`) |
| Tiempo para responder a una invitación | <n> segundos (`Config.PARTY_INVITE_SECONDS`) |

**Habla con el cliente mediante:** el grupo de cada jugador, su rol (líder o miembro) y si el
grupo es abierto o privado, como atributos en el jugador. Invitar, aceptar, rechazar, entrar,
salir, expulsar e iniciar la run son remotos declarados en el contrato.

**Open:** ¿un grupo privado también acepta solicitudes de entrada ("pedir unirse"), o solo
invitaciones del líder? Bloquea la pantalla de la lista.

**Open:** ¿el líder puede expulsar a un miembro? ¿Qué pasa con el grupo si el líder se va del
juego? (Propuesta: el liderazgo pasa al miembro que lleva más tiempo.) Bloquea las reglas del
grupo; no bloquea el combate.

**Open:** cuánto dura una invitación sin respuesta antes de caducar. Bloquea
`Config.PARTY_INVITE_SECONDS`.

**Open:** si un jugador se desconecta durante la run, ¿puede volver a esa misma run? Bloquea el
servidor de run.

---

## Combate

`server/features/combat/`

**Qué hace:** decide los golpes del jugador y de los enemigos, y el daño que hacen.

**Reglas:**

- Movimientos básicos, que todo jugador tiene siempre: moverse, saltar, dash, **bloqueo / parry**,
  el ataque básico que encadena un combo y el **ataque pesado cargado** (manteniendo pulsado el
  botón de ataque durante 3 segundos). Son los que definen la alta velocidad del juego, así que su
  rapidez y fluidez son lo primero que se ajusta.
- **Ataque pesado cargado:** pulsar rápido Atacar ejecuta el combo normal sin demora; mantener
  pulsado Atacar durante **3 segundos** (`Config.HEAVY_CHARGE_SECONDS`) carga un corte frontal
  amplio de alto daño (`Config.HEAVY_ATTACK_DAMAGE`, arco de `160°` y `13` studs de alcance) que se
  libera automáticamente al completarse la carga. Durante la carga el jugador se desplaza más
  despacio (`Config.HEAVY_CHARGE_MOVE_MULTIPLIER`), muestra barra de progreso en el HUD y puede
  cancelar soltando antes o usando Dash/Bloqueo.
- **Bloqueo y Parry:** mantener pulsado Bloquear (clic derecho / `F` / `L1` / botón táctil
  `"Bloquear"`) reduce el daño entrante en un 70% (`Config.BLOCK_DAMAGE_REDUCTION`) a cambio de
  moverse más despacio (`Config.BLOCK_MOVE_MULTIPLIER`). Si se levanta la guardia justo antes de un
  impacto (`Config.PARRY_WINDOW`), ejecuta un **Parry**: anula todo el daño, aturde a enemigos
  cuerpo a cuerpo (`Config.PARRY_STUN_SECONDS`) y **devuelve los disparos de enemigos a distancia**
  hacia los enemigos a mayor velocidad (`Config.PARRY_PROJECTILE_DAMAGE`). Soltar el bloqueo tiene
  una breve recarga (`Config.BLOCK_COOLDOWN`) para evitar spam infinito de parry.
- **Saltar tiene rol defensivo:** además de servir para movilidad y obstáculos, saltar permite
  esquivar proyectiles y ataques rasos del suelo (la detección de impacto comprueba la altura `Y`).
- **Sin fuego amigo:** los ataques y habilidades de un jugador nunca dañan a sus compañeros.
- Las habilidades son de dos tipos:
  - **Habilidades activas de ataque:** ocupan uno de los 3 huecos activos (`Config.ABILITY_SLOTS`)
    y funcionan con tiempo de recarga (por ejemplo, el ataque giratorio).
  - **Mejoras de movimiento (pasivas):** siempre están activas y no ocupan hueco de habilidad
    activa. Cada una es una mejora separada que puede combinarse con las demás (por ejemplo, doble
    salto y doble dash son dos pasivas distintas que combinan juntas).
- Todos los jugadores empiezan la run con el mismo personaje y el mismo kit. No se elige clase
  ni arma antes de la run.
- Al empezar la run, cada jugador elige 1 de 3 habilidades al azar. Esa es su primera habilidad;
  las siguientes llegan como mejoras de run (1 de 3 al limpiar una sala; ver Mejoras de run).
- Cada control (ataque, dash, cada habilidad) tiene que poder usarse con teclado y ratón, con
  táctil y con mando (ver [technical.md](technical.md)).
- En los tres controles por igual (teclado/ratón, mando y táctil), el ataque básico toma como
  referencia la dirección en la que se mueve o mira el personaje (nunca el cursor del ratón),
  engancha al enemigo más alineado con esa dirección dentro de un cono frontal de 120° (±60° a
  izquierda y derecha de la dirección pulsada) y da un impulso corto para pegarse a él durante el
  combo.
- Una vez elegido un enemigo al usar un ataque básico o una habilidad por primera vez, continuar el
  combo mantiene el objetivo pegado a ese mismo enemigo mientras siga vivo, en alcance y el jugador
  siga dirigiéndose hacia él.
- En el corte de prueba, el personaje lleva equipada una espada (`Config.TEST_SWORD_MODEL`).
- Al morir por daño del jugador, cada enemigo tiene un 30% de probabilidad (`Config.DROP_CHANCE`)
  de soltar un objeto recogible en el suelo:
  - **Curación (`heal`):** restaura vida (`Config.DROP_HEAL_AMOUNT`); si el jugador tiene la vida
    llena, no lo consume para que pueda usarlo más tarde o un compañero.
  - **Buff de ataque (`damage`):** aumenta el daño de ataques básicos y habilidades durante unos
    segundos (`Config.BUFF_DAMAGE_MULTIPLIER`, `Config.BUFF_DAMAGE_DURATION`).
  - **Buff de velocidad (`speed`):** aumenta la velocidad de movimiento durante unos segundos
    (`Config.BUFF_SPEED_MULTIPLIER`, `Config.BUFF_SPEED_DURATION`).
- **Buff de defensa en el mapa (`defense`):** cada cierto tiempo durante el combate
  (`Config.DEFENSE_SPAWN_INTERVAL`) aparece un escudo recogible en el suelo (máximo 1 activo a la
  vez) que otorga un **50% de defensa** (`Config.BUFF_DEFENSE_REDUCTION`) durante
  `Config.BUFF_DEFENSE_DURATION` segundos, acumulable con el bloqueo.

**Números:**

Valores de prueba del corte de combate, para ajustar jugando:

| | |
|---|---|
| Vida del jugador | 100 (`Config.PLAYER_MAX_HEALTH`) |
| Golpes del combo básico | 3, con daño 10 / 10 / 20: el último es el fuerte (`Config.COMBO_HITS`, `Config.COMBO_DAMAGE`) |
| Ataque pesado cargado | Mantener Atacar 3 s (`Config.HEAVY_CHARGE_SECONDS`): 55 de daño en arco frontal de 160° y 13 studs (`Config.HEAVY_ATTACK_DAMAGE`, `Config.HEAVY_ATTACK_RANGE`, `Config.HEAVY_ATTACK_ARC`) |
| Tiempo para encadenar el combo | 0,6 s (`Config.COMBO_WINDOW`) |
| Enganche frontal del ataque básico | Cono de 120° (±60° desde la dirección pulsada) hasta 15 studs (retención en combo de 110°), con impulso de hasta 8 studs a 90 studs/s (`Config.AIM_ASSIST_CONE`, `Config.TARGET_LOCK_CONE`, `Config.AIM_ASSIST_RANGE`, `Config.ATTACK_LUNGE_MAX_DISTANCE`, `Config.ATTACK_LUNGE_SPEED`) |
| Velocidad al correr | 26 studs/s; la de Roblox por defecto es 16 (`Config.MOVE_SPEED`) |
| Distancia del dash | 18 studs en 0,18 s (`Config.DASH_DISTANCE`, `Config.DASH_DURATION`) |
| Recarga del dash | 0,7 s (`Config.DASH_COOLDOWN`) |
| Invulnerabilidad del dash | 0,25 s: se puede atravesar un ataque con el dash (`Config.DASH_IFRAMES`) |
| Ataque giratorio (`1`) | 25 de daño, radio 12, recarga 4 s (`Config.SPIN_DAMAGE`, `Config.SPIN_RADIUS`, `Config.SPIN_COOLDOWN`) |
| Stinger (`2`) | Embestida perforante de 26 studs en 0,24 s, 35 de daño en corredor de 6,5 studs, recarga 5,5 s (`Config.STINGER_DAMAGE`, `Config.STINGER_DISTANCE`, `Config.STINGER_COOLDOWN`) |
| Over Drive (`3`, Definitiva) | Carga energía 0,75 s y desata 3 ondas crecientes a distancia (56 studs, ancho 9, daño 38 / 42 / 55), recarga 14 s (`Config.OVERDRIVE_COOLDOWN`, `Config.OVERDRIVE_WAVE_DAMAGE`) |
| Probabilidad de drop al matar enemigo | 30% (`Config.DROP_CHANCE`), reparto 40/30/30 entre curación, daño y velocidad (`Config.DROP_WEIGHTS`) |
| Curación de drop | +25 vida (`Config.DROP_HEAL_AMOUNT`) |
| Buff de ataque | ×1,5 daño durante 10 s (`Config.BUFF_DAMAGE_MULTIPLIER`, `Config.BUFF_DAMAGE_DURATION`) |
| Buff de velocidad | ×1,35 velocidad durante 10 s (`Config.BUFF_SPEED_MULTIPLIER`, `Config.BUFF_SPEED_DURATION`) |
| Buff de defensa (mapa) | 50% de reducción de daño durante 12 s; aparece cada 22 s (`Config.BUFF_DEFENSE_REDUCTION`, `Config.BUFF_DEFENSE_DURATION`, `Config.DEFENSE_SPAWN_INTERVAL`) |
| Bloqueo y Parry | 70% de reducción al bloquear (`Config.BLOCK_DAMAGE_REDUCTION`), ventana de Parry de 0,25 s (`Config.PARRY_WINDOW`), disparo reflejado 25 de daño (`Config.PARRY_PROJECTILE_DAMAGE`), recarga al soltar 0,45 s (`Config.BLOCK_COOLDOWN`) |
| Huecos de habilidades activas por jugador | 3 (`Config.ABILITY_SLOTS`) |
| Habilidades ofrecidas al empezar la run | 3 (`Config.START_ABILITY_CHOICES`) |

**Habla con el cliente mediante:** los remotos `Attack`, `Dash` y `Spin` (eventos del jugador) y
atributos en el jugador para la vida y las recargas. Ver [docs/combat.md](../../docs/combat.md).

---

## Mejoras de run

`server/features/upgrades/`

**Qué hace:** da al jugador mejoras que duran solo esa run.

**Reglas:**

- Al limpiar una sala, cada jugador recibe sus propias 3 mejoras al azar y elige 1 por su cuenta,
  en paralelo al resto del grupo para no frenar el ritmo.
- Las mejoras de run se pierden al terminar la run, se gane o se pierda. Lo único que se conserva
  es la moneda permanente (ver [progression.md](progression.md)).
- Entre las 3 opciones puede haber habilidades nuevas (activas o pasivas de movimiento) o mejoras
  de estadísticas. Si el jugador ya tiene llenos los 3 huecos de habilidad activa
  (`Config.ABILITY_SLOTS`), una opción de habilidad activa nueva se convierte al azar en una de
  estas tres variantes (mezcladas dentro del pool de las 3 tarjetas):
  - una mejora de una habilidad activa que ya tiene;
  - la habilidad nueva, reemplazando una que ya tiene (el jugador elige cuál);
  - una mejora de estadísticas (vida, daño, velocidad...).
- El juego no se pausa mientras se elige. Los enemigos siguen activos; elegir rápido es parte del
  ritmo.
- Las elecciones sin hacer se acumulan en una cola **sin tope dentro de la misma planta**: si el
  jugador limpia varias salas sin elegir, tiene todas esas elecciones pendientes y las resuelve en
  orden cuando quiera.
- Al pasar de planta, todas las elecciones que sigan en la cola se resuelven al azar. Así nadie
  arrastra elecciones de una planta a otra, y quien no tuvo tiempo de elegir no se queda atrás.

**Números:**

| | |
|---|---|
| Mejoras ofrecidas por elección | 3 (`Config.UPGRADE_CHOICES`) |

**Habla con el cliente mediante:** las ofertas activas y el contador de cola se replican por
jugador (atributos o evento servidor→cliente al generarse una oferta); elegir una opción usa un
remoto `PickUpgrade` declarado en el contrato (y `ReplaceAbility` o parámetro de hueco cuando
corresponde reemplazar). Ver pantalla `UpgradeChoice` en [ui.md](ui.md).

---

## Muerte y revivir

`server/features/revive/`

**Qué hace:** decide qué pasa cuando un jugador cae y cuándo se pierde la run.

**Reglas:**

- Un jugador que se queda sin vida cae, pero no sale de la run. Un compañero en pie puede
  revivirlo.
- Mientras quede al menos un jugador en pie, la run sigue.
- Para revivir a un compañero caído hay que quedarse a su lado 5 segundos. Exige parar de pelear
  en medio de la horda: es el riesgo de salvar a alguien.
- Si todo el grupo cae, la partida muestra un cartel a todos: pagar **10 Robux** para revivir al
  grupo, o rendirse. El cartel dura 20 segundos.
  - Cualquier jugador del grupo puede pagar. Un solo pago revive a todo el grupo.
  - Se puede pagar cada vez que el grupo entero cae, y el precio nunca sube.
  - Si alguien paga, el grupo revive y la run continúa.
  - Si nadie paga en 20 segundos, o todos se rinden, la run se pierde y el grupo vuelve al hub.

**Números:**

| | |
|---|---|
| Precio del revivir del grupo | 10 Robux (producto de desarrollador; su id va en `Config.ENV_IDS`, no en el código) |
| Tiempo del cartel de revivir | 20 segundos (`Config.WIPE_REVIVE_SECONDS`) |
| Tiempo junto a un compañero para revivirlo | 5 segundos (`Config.ALLY_REVIVE_SECONDS`) |

**Habla con el cliente mediante:** <pendiente>.

**Open:** a qué distancia cuenta como "al lado" (`Config.ALLY_REVIVE_RADIUS`), y si recibir daño
mientras revives reinicia los 5 segundos. Bloquea el revivir entre compañeros.

**Open:** ¿hay un máximo de pagos por run? Pagar sin límite deja comprar la victoria. Bloquea el
producto de desarrollador.

**Open:** al revivir pagando, ¿con cuánta vida vuelve el grupo, y qué pasa con los enemigos que
había en la sala? Bloquea las reglas de revivir.
