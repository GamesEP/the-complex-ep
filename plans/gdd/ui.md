# Pantallas

Status: agreed

Este documento cubre en detalle las pantallas del corto plazo (**Corte jugable** y **Hito 2: Una
planta**). Las pantallas de hitos posteriores (Hub, Lista de jugadores, Árbol de progresión y
Revivir del grupo) se diseñarán cuando arranque su hito.

---

## CombatHud

`client/features/combat/ui/`

**En pantalla cuando:** el jugador está dentro de una sala o run activa.

**Muestra:**
- Barra de vida roja del jugador en la esquina superior izquierda (valor actual / máximo) y debajo los indicadores temporales de buffs recogidos solo mientras están activos.
- Progreso de la sala actual: planta/sala (en Hito 2) y oleada o enemigos restantes en la parte superior central (los avisos de habilidades enemigas —Coloso y Paso Fantasma— aparecen como un icono triangular amarillo con `!` directamente sobre la cabeza de cada enemigo, sin carteles de texto invasivos).
- Barra de vida del jefe en la parte superior central cuando la sala actual tiene jefe.
- Iconos recargables de las 3 habilidades activas (`Config.ABILITY_SLOTS`) en la esquina inferior izquierda, intercambiables con `1`, `2` y `3` (o clic/toque / cruceta en mando) y lanzables con `E` / `Y` / `R1`: **`1` Giro** (`4 s`), **`2` Stinger** (`5,5 s`) y **`3` Over Drive** (definitiva, `14 s`), cada uno con barrido de recarga y cuenta atrás. Sin barras para el Dash ni para Bloqueo/Parry por su recarga rápida.

**El jugador puede:**
- Leer su vida, sus recargas y el avance de la sala de un vistazo sin quitar la vista del centro.
- En móvil, usar los controles táctiles dedicados (ataque, salto, dash y hasta 3 botones de
  habilidad activa) dispuestos en arco en la esquina inferior derecha, sin solaparse entre sí ni
  con el joystick izquierdo.

**En pantalla pequeña (móvil):**
- El texto secundario y los nombres largos de habilidades se ocultan: quedan iconos + número de
  recarga.
- El indicador de sala/oleada se compacta en una pastilla arriba respetando el `inset` superior de
  Roblox (`Layout.inset()`).
- Los botones táctiles de acción ocupan el cuadrante inferior derecho con área de toque amplia y
  dejan libre la parte superior para `UpgradeChoice`.

---

## UpgradeChoice

`client/features/upgrades/ui/`

**En pantalla cuando:** el jugador tiene al menos una elección de 1 de 3 pendiente (al iniciar la
run o al limpiar una sala). Nunca pausa el juego ni bloquea el movimiento ni los ataques.

**Muestra:**
- Un **banner compacto en la parte superior** con 3 tarjetas cortas en horizontal: cada tarjeta
  muestra icono, nombre corto, efecto en pocas palabras (ej. `+20% daño`, `Doble dash`, `Giratorio
  Nv.2`) y el atajo de selección (`1` / `2` / `3` en PC, cruceta/botón en mando).
- Un indicador de cola (`+N`) junto al banner cuando hay más elecciones pendientes detrás de la
  actual.
- Si el jugador elige reemplazar una habilidad activa con los 3 huecos llenos, el banner pasa
  momentáneamente a mostrar los 3 huecos actuales para elegir cuál sustituir (con los mismos
  atajos `1` / `2` / `3` o toque).

**El jugador puede:**
- Elegir una de las 3 opciones al instante con `1` / `2` / `3` (PC), cruceta/botón (mando) o
  tocando directamente la tarjeta (móvil), mientras sigue corriendo, esquivando y atacando.
- Ignorar el banner temporalmente y seguir peleando: la elección permanece en cola hasta que el
  jugador la resuelva o pase de planta (donde las pendientes se resuelven al azar).

**En pantalla pequeña (móvil):**
- Las 3 tarjetas se mantienen en una sola fila estrecha arriba (bajo el `inset` superior), usando
  icono + título corto + dato numérico, sin párrafos descriptivos.
- Nunca invade la mitad inferior de la pantalla para no estorbar el joystick ni los botones de
  combate.

---

## RunResult

`client/features/run/ui/`

**En pantalla cuando:** el jugador completa la planta (victoria en Hito 2) o cae en solitario
(derrota).

**Muestra:**
- Estado claro (**Planta completada** o **Derrota**).
- Resumen breve de la run: salas superadas, tiempo y enemigos derrotados.
- Botón principal **Reintentar** (y, a partir del hito de Hub, botón **Volver al hub**).

**El jugador puede:**
- Reiniciar la run/planta inmediatamente con un toque o botón de confirmación, sin pasos extra.

**En pantalla pequeña (móvil):**
- Panel centrado compacto con el resumen en 3 datos clave y botón **Reintentar** grande en la
  parte inferior del panel.

---

## ClassSelect

`client/features/classes/ui/`

**En pantalla cuando:** el jugador acaba de entrar (o reaparece en una sala nueva) y todavía no ha
elegido clase. Mientras está abierta, los enemigos están quietos.

**Muestra:**
- Las 3 clases (Tanque, Daño, Apoyo) como tarjetas, cada una con su arma, sus estadísticas en
  pocas cifras, sus 3 habilidades y su pasiva.

**El jugador puede:**
- Elegir una clase con clic, toque o mando, y empezar a pelear.

**En pantalla pequeña (móvil):**
- Las 3 tarjetas pasan de estar en fila a apiladas en columna, con desplazamiento vertical.
  Todavía no se ha visto en un teléfono.

---

## Pantallas de hitos posteriores (pendientes)

- **Hub y Lista de jugadores** (`client/features/party/ui/`): se diseñará en el hito de **Grupos**
  (bloqueada por `Config.HUB_MAX_PLAYERS` y reglas de solicitudes privadas).
- **Cartel de revivir del grupo (10 Robux)** (`client/features/revive/ui/`): se diseñará en el
  hito de **Grupos**.
- **Árbol de progresión permanente y tienda** (`client/features/progression/ui/`): se diseñará en
  el hito de **v1**.
