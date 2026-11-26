# Alcance

Status: agreed

## El corte jugable más pequeño

Estado: programado, ampliado más allá de lo planeado y con las pruebas automáticas en verde
(`make check`); falta jugarlo y ajustarlo en Studio. Cómo está hecho:
[docs/combat.md](../../docs/combat.md).

Solo combate. Sirve para responder una pregunta antes de construir nada alrededor: **¿pelear en
The Complex es divertido y se siente rápido?** Si no lo es, ningún hub, árbol ni jefe lo arregla.

Lo que se planeó:

- Un jugador, una sala, con cámara isométrica.
- Movimientos básicos: correr, saltar, dash y ataque básico con combo. Son lo que este corte
  pone a prueba, porque son lo que define la alta velocidad.
- 1 habilidad: el ataque giratorio.
- 3 tipos de enemigo: cuerpo a cuerpo, a distancia y explosivo (hoy Centinela, Cazador y Detonante).
- Vida del jugador y de los enemigos; si el jugador muere, la sala se reinicia.
- Controles de teclado y ratón, táctil y mando desde el principio, porque añadirlos después
  obliga a rehacer los controles.

Lo que se añadió después, durante el desarrollo del corte:

- **Kit del jugador:** ataque cargado de 2 s, bloqueo con ventana de parry (aturde a los cuerpo a
  cuerpo y devuelve los disparos), apuntado con "pegado" al objetivo y un pequeño avance al atacar.
- **3 habilidades intercambiables** en lugar de 1: Giro, Stinger y Over Drive (ver
  [systems.md](systems.md)).
- **4 tipos de enemigo** en lugar de 3: se sumó el Coloso (el agarrador), y Centinelas y Cazadores
  tienen variantes por arma con ataques propios (ver [content.md](content.md)). 5 oleadas.
- **Recompensas en la sala:** los enemigos sueltan curación o buffs temporales de daño y velocidad
  (el de velocidad permite el dash doble), y aparece periódicamente un escudo de defensa. No son
  las mejoras de 1 de 3 de la run: duran segundos y no se eligen.
- **Presentación:** la arena industrial, modelos con animaciones, sonidos, música y tonemapping.
- **3 clases de prueba** (Tanque, Daño y Apoyo) elegidas en una pantalla al empezar, cada una con
  sus estadísticas, arma, 3 habilidades y pasiva (ver Clases en [systems.md](systems.md)).

Sigue fuera de este corte: hub, grupos, plantas, mejoras de 1 de 3, jefes, moneda, Robux y
guardado.

En el corte las tres habilidades están disponibles desde el principio para poder probarlas. En la
run completa no será así: se elige 1 de 3 al empezar y las demás llegan como mejoras al limpiar
salas (Combate y Mejoras de run en [systems.md](systems.md)), que es lo que pide el pilar 1.

**Open:** los números de todo el kit (recargas, radios, daños). No bloquean nada: se ajustan
jugando en Studio.

## v1

Lo que se publica:

- Hub con lista de jugadores, grupos abiertos y privados.
- Run en servidor privado: 5 plantas × 5 salas.
- Combate completo y los seis tipos de enemigo.
- Elección de 1 de 3 al empezar y al limpiar salas, con cola.
- Jefe OhMyGon: Oh, My y Gon por separado, y la fusión de dos fases en la planta 5.
- Revivir entre compañeros y revivir del grupo por 10 Robux.
- Moneda permanente, árbol de estadísticas, habilidades desbloqueables y ventajas de run.
- Venta de moneda y del duplicador (y otros "buffos").
- PC, móvil y consola.

## Fuera de la v1, a propósito

- Cosméticos: se venderán cuando el juego tenga jugadores que los quieran; antes es trabajo de
  arte que no prueba si el juego funciona.

## Hitos

| | |
|---|---|
| Corte jugable | Un jugador limpia una sala contra 2-3 tipos de enemigo en PC, móvil y mando. *(Completado)* |
| Una planta | 5 salas seguidas en orden fijo con elección de 1 de 3 sin pausa y el jefe Oh en la sala 5 (`RunFlow`, `RunService`, `UpgradePool`, `UpgradeService`, `UpgradeChoice`, `RunResult`). *(Implementado y verificado en `make check` + Studio; pendiente playtest manual en móvil/mando y subida de SFX a Open Cloud)* |
| Run en solitario | 5 plantas, las tres partes del jefe y OhMyGon. Se gana y se pierde. |
| Grupos | Hub, lista, grupos y la run en servidor privado para 1 a 4 jugadores, con revivir. |
| v1 | Progresión permanente, guardado y productos de Robux. |
