# Alcance

Status: agreed

## El corte jugable más pequeño

Estado: programado y con las pruebas automáticas en verde; falta probarlo y ajustarlo en Studio.
Cómo está hecho: [docs/combat.md](../../docs/combat.md).

Solo combate. Sirve para responder una pregunta antes de construir nada alrededor: **¿pelear en
The Complex es divertido y se siente rápido?** Si no lo es, ningún hub, árbol ni jefe lo arregla.

- Un jugador, una sala.
- Cámara isométrica.
- Movimientos básicos: correr, saltar, dash y ataque básico con combo. Son lo que este corte
  pone a prueba, porque son lo que define la alta velocidad.
- 1 habilidad: el ataque giratorio, que golpea a todos los enemigos alrededor del jugador. Es la
  habilidad que más se nota frente a una horda, así que es la que mejor prueba el combate.
- 3 tipos de enemigo: cuerpo a cuerpo, a distancia y explosivo. Son tres maneras distintas de
  obligar al jugador a moverse.
- Vida del jugador y de los enemigos; si el jugador muere, la sala se reinicia.
- Controles de teclado y ratón, táctil y mando desde el principio, porque añadirlos después
  obliga a rehacer los controles.

Queda fuera de este corte: hub, grupos, plantas, mejoras, jefes, moneda, Robux y guardado.

**Open:** recarga y radio del ataque giratorio (`Config.SPIN_COOLDOWN`, `Config.SPIN_RADIUS`).
No bloquea el corte: se empieza con valores de prueba y se ajustan jugando.

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
| Corte jugable | Un jugador limpia una sala contra 2-3 tipos de enemigo en PC, móvil y mando. |
| Una planta | 5 salas seguidas en orden fijo con elección de 1 de 3 y el jefe Oh en la sala 5 (en la run completa de 5 plantas, la Planta 1 es sin jefe y Oh va en la Planta 2; aquí se incluye a Oh para validar salas + jefe juntos). |
| Run en solitario | 5 plantas, las tres partes del jefe y OhMyGon. Se gana y se pierde. |
| Grupos | Hub, lista, grupos y la run en servidor privado para 1 a 4 jugadores, con revivir. |
| v1 | Progresión permanente, guardado y productos de Robux. |
