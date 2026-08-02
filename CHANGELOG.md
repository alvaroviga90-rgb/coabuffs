# Registro de cambios

## 2.3.0

Ronda del repintado y el refresco de la ventana abierta.

- La ventana de reparto se repinta mientras está visible, con un techo de **2 repintados
  por segundo y por vista**, y con barrido a 1,5 s mientras haya algo abierto: la pantalla
  deja de depender por completo de que llegue `UNIT_AURA`.
- **Un repintado ya no te tira el scroll ni te cierra un desplegable abierto.** Las filas que
  existen se siguen pintando por `spellId`, y las nuevas se añaden al final sin liberar nada.
- **Defecto de reparto corregido**: un relevo podía llevarse por delante al nominal de otro
  buff habiendo alternativa libre. Ahora `Asig.derivar` va en dos pasadas — primero reserva
  todos los nominales disponibles, después resuelve los relevos.
- Los dos avisos manuales comparten suelo de espaciado: ya no pueden salir dos susurros en
  el mismo fotograma.
- El configurador cachea propuestas, equivalencias y lista de clases contra la revisión del
  catálogo, en vez de recorrer el histórico entero dos veces por segundo.
- Arreglada una fuga de fondo y de fuente sobre el pool de widgets de AceGUI, que acababa
  tiñendo ventanas de otros addons.
- El repintado va protegido: un error dentro del pintado ya no se convierte en un error de
  Lua por segundo mientras la ventana esté abierta.

**Conocido, sin arreglar:** `Const.lua` declara `A.VERSION = "2.2.0"`. El `.toc` y esta
release dicen 2.3.0, pero la línea del chat al entrar y el latido del protocolo siguen
anunciando 2.2.0. No afecta a la compatibilidad — `X-Protocolo` no ha cambiado — pero los
dos números no coinciden.

## 2.2.0 y anteriores

El número 2.2.0 cubrió más de una compilación: se marcó antes de la última tanda de cambios
y no se subió al terminarla. La bitácora completa del desarrollo, ronda a ronda, está fuera
de este repositorio.

Lo que ya venía cerrado de rondas anteriores: convergencia bajo pérdida hasta el 70 %,
anti-inanición de la cola de avisos, relevo del anunciante, modo grupo de 5, tope de
equivalencias por mensaje, persistencia de la lista cerrada, candado real contra el spam
público y apagado limpio si falta alguna API del cliente.
