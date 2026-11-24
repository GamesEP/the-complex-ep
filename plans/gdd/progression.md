# Progresión

Status: drafted

## Moneda permanente

Cada run da una moneda que se conserva entre runs y compra mejoras permanentes. Se gana por lo
avanzado, se gane o se pierda la run: lo importante es que siempre haya progresión.

Se gana de cuatro fuentes, cada una con su propia cantidad:

| | |
|---|---|
| Por enemigo derrotado | <n> (`Config.CURRENCY_PER_ENEMY`) |
| Por sala limpiada | <n> (`Config.CURRENCY_PER_ROOM`) |
| Por planta superada | <n> (`Config.CURRENCY_PER_FLOOR`) |
| Por jefe derrotado (Oh, My, Gon, OhMyGon) | <n> (`Config.CURRENCY_PER_BOSS`) |

**Open:** nombre de la moneda. No bloquea nada salvo los textos de la interfaz.

**Open:** las cantidades. La regla que deberían cumplir: de menor a mayor, enemigo < sala < planta
< jefe, para que avanzar valga más que alargar la run matando enemigos. Bloquea esta tabla.

**Open:** en grupo, ¿cada jugador gana la moneda completa, o se reparte? (Propuesta: cada uno la
completa, para que jugar en grupo nunca salga peor que jugar solo.) Bloquea el reparto.

## Qué se compra con la moneda

Tres cosas, todas funcionales:

- **Estadísticas base** (vida, daño, velocidad...), organizadas como un **árbol de habilidades**:
  cada nodo comprado abre los siguientes.
- **Habilidades nuevas:** desbloquearlas las añade a las que pueden salir en las elecciones de 1
  de 3 durante la run.
- **Ventajas de run:** por ejemplo, una opción extra al elegir, volver a tirar las opciones o
  revivir más rápido a un compañero.

**Open:** las ramas y los nodos del árbol, y qué ventajas de run existen. Bloquea la pantalla del
árbol.

## Robux

Los cosméticos se consiguen **solo con Robux**; la moneda permanente nunca compra cosméticos.

| Producto | Tipo |
|---|---|
| Revivir al grupo entero cuando cae todo | 10 Robux, sin límite y sin subir el precio (ver Muerte y revivir en [systems.md](systems.md)) |
| Cosméticos | <pase o producto por cosmético> |
| Moneda permanente | Producto de desarrollador, en paquetes |
| Duplicador de moneda permanente y otros "buffos" parecidos | <pase de juego permanente, o producto con duración> |

Todos los ids de estos productos van en `Config.ENV_IDS`, nunca escritos en el código: son
distintos en la experiencia de pruebas y en la de producción.

Comprar moneda y el duplicador son ventajas que se pagan. Se aceptan porque el juego es
cooperativo: nadie pierde contra quien pagó, y lo que se compra es velocidad de progresión, no
contenido exclusivo. Lo que no debe pasar es que algo del árbol solo se pueda conseguir pagando.

**Open:** ¿el duplicador es permanente (pase de juego) o dura un tiempo (producto)? ¿Qué otros
"buffos" hay? Bloquea la tabla de productos.

## Persistencia

Se guarda: la moneda permanente, los nodos del árbol comprados, las habilidades desbloqueadas,
las ventajas de run compradas y los cosméticos.

No se guarda: nada de lo conseguido dentro de una run (habilidades elegidas, mejoras de run).
