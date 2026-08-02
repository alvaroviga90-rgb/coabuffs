# CoABuffs

Addon de reparto de buffs para **Conquest of Azeroth** (Ascension, cliente 3.3.5a).

Dice quién tiene que poner cada buff, quién lo tiene puesto y a quién le falta.
No lanza hechizos, no toca barras de acción y no decide nada por ti.

**[→ Guía de uso](https://USUARIO.github.io/coabuffs/)**

---

## Instalación

1. Descarga el `.zip` de la [última release](../../releases/latest).
2. Extrae la carpeta `CoABuffs` dentro de `<tu ruta de Ascension>\Interface\AddOns\`.
   La ruta la tienes en el launcher: icono de cuenta → Ajustes → Ascension → Ruta de instalación.
3. Cierra el cliente del todo y vuelve a entrar. Un `/reload` no basta.

Debe quedar así:

```
Interface\AddOns\CoABuffs\CoABuffs.toc
```

> **Toda la raid tiene que ir con la misma versión.** Los clientes se hablan por un
> protocolo propio (`X-Protocolo: 1`); el que vaya desparejado deja de contar.

## Uso rápido

| Comando | Qué hace |
|---|---|
| `/cab` | Abre el reparto. Con rango de líder o asistente, abre el configurador. |
| `/cab reparto` | Ventana de reparto, con cualquier rango. |
| `/cab jugadores` | Vista por jugador. |
| `/cab estado` | Diagnóstico: revisión, digest, cobertura, quién anuncia. |
| `/cab minimapa` | Enseña o esconde el botón del minimapa. |
| `/cab cuenta` | Sello de la base de datos local. |
| `/cab perfiles` · `/cab perfil <n>` · `/cab guardar <n>` | Perfiles. Sólo líder y asistentes. |

`/coabuffs` es equivalente a `/cab`.

## Cómo funciona, en cuatro líneas

- **Estado replicado**, último escritor gana **por entrada**. Converge bajo pérdida,
  reordenamiento y duplicados sin negociar nada.
- **La reasignación no se habla, se deriva**: es una función determinista del estado y del
  roster que todos los clientes calculan igual. Cero mensajes.
- **La autoridad va en el remitente**, no en el mensaje. Ningún campo del cuerpo da permisos.
- **Tres candados contra el falso positivo**: sólo cuenta quien es observable, la ausencia
  tiene que llevar 3 s confirmada, y la línea se reconstruye entera en el instante de emitirla.

## Reportar un fallo

Abre un *issue* con:

- Qué esperabas y qué pasó
- Una captura con la ventana abierta
- La salida de `/cab estado`
- Cuánta gente había en la raid y si estabais en combate

## Créditos y licencias

`CoABuffs/Libs/` son copias sin modificar de las librerías **Ace3** (LibStub,
CallbackHandler-1.0, ChatThrottleLib, AceComm-3.0, AceSerializer-3.0, AceGUI-3.0).
Su licencia está en [`CoABuffs/Libs/LICENSE.txt`](CoABuffs/Libs/LICENSE.txt).

La tabla de clases de CoA sale de la lista del servidor que distribuye AtlasLoot
(`serverClasses.COA`): el cliente no define `RAID_CLASS_COLORS` para ellas.
