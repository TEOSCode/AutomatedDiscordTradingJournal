# Automated Discord Trading Journal
Un EA de MT5 que envía automaticamente los trades a Discord, Apertura (con Screenshot), Ajustes de SL y TP, cierre (con Screenshot). Convierte cada operación en un registro visual y automático, directo en un canal de Discord — sin tener que tomar capturas ni escribir nada a mano.

## ¿Qué hace?

Cada vez que abro una operación, el bot:

Toma una captura del chart en el momento exacto de la entrada.
Crea un thread nuevo en un canal tipo foro, titulado con el símbolo, la dirección (compra/venta) y la fecha y hora local (ej. "EURUSD COMPRA - Lunes 20 Jul 2026 09:30am").
Publica ahí mismo el precio de entrada, volumen, y el Stop Loss y Take Profit convertidos a dinero real — no solo en pips, sino en cuánto representa en la cuenta si se toca cada nivel.

**Mientras la operación sigue abierta:**

Si ajusto el SL o el TP manualmente (por ejemplo, moviendo el stop a break-even o corriendo un trailing), el bot detecta el cambio y publica una actualización en el mismo thread con el nuevo riesgo/beneficio en dinero, indicando si es positivo o negativo.

**Al cerrar la operación:**

Toma una segunda captura del chart en el momento del cierre.
Publica el resultado en el mismo thread: precio de cierre, profit, y el motivo del cierre (si fue manual, por Stop Loss, Take Profit, o incluso un Stop Out por margen).
Etiqueta el thread automáticamente como Win, Loss o BE (break-even) según el resultado — así el foro queda organizado y filtrable de un vistazo, sin tener que abrir cada thread para saber cómo cerró.

## ¿Para qué sirve?

Es básicamente una bitácora de trading que se escribe sola. Cada operación queda documentada con evidencia visual y datos objetivos en tiempo real, sin depender de que me acuerde de tomar screenshots o llevar notas manuales. Con el tiempo, esto se convierte en un historial fácil de revisar — útil tanto para análisis personal como para compartir el proceso de forma transparente.

## Cómo funciona por dentro

El EA corre directo en MetaTrader 5 (MQL5) y se conecta a Discord de dos formas:

Un webhook del canal foro para crear el thread inicial con la captura.
Un bot de Discord (con su propio token) para poder seguir posteando actualizaciones dentro de ese mismo thread conforme avanza la operación.

Toda la lógica corre localmente, sin servicios intermedios ni suscripciones — solo MT5 y Discord.
