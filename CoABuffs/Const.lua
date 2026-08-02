-- Const.lua — constantes y números congelados.
-- Los dos números de docs/PRESUPUESTO_CONGELADO.md NO se tocan. Si aprietan, se
-- arregla el addon, que es justo lo que se ha hecho aquí.

CoABuffs = CoABuffs or {}
local A = CoABuffs

A.NOMBRE   = "CoABuffs"
A.PREFIJO  = "CoABuffs"          -- 8 bytes; AceComm parte en 254-8 = 246
A.VERSION  = "2.2.0"             -- tiene que coincidir con el .toc: viaja en cada latido
A.PROTO    = 1                   -- versión del protocolo, en TODOS los mensajes

-- ---------------------------------------------------- NUMEROS CONGELADOS ----
A.PRESUP_BPS      = 100          -- 12,5% de los 800 B/s de ChatThrottleLib
A.PRESUP_VENTANA  = 10           -- medidos sobre 10 s => 1000 B
A.PRESUP_RAFAGA   = 500          -- 12,5% del BURST de 4000, en 1 s
A.ANUNCIOS_MIN    = 6            -- anuncios por minuto
A.ANUNCIOS_RAFAGA = 3            -- y como mucho 3 en 10 s

-- Ritmo propio, por debajo del techo congelado y con margen medido.
A.ANUNCIO_CADA    = 12           -- 5/min < 6/min
A.HEARTBEAT_CADA  = 20           -- digest de estado
A.ESCANEO_CADA    = 0.5          -- trabajo periódico
A.BARRIDO_CADA    = 30           -- respaldo del modelo por eventos
-- (A.BARRIDO_VISTA se define mas abajo: sale del plazo congelado.)

-- Anti-falso-positivo. El criterio que manda: ante ambigüedad, callarse.
A.CONFIRMA        = 3            -- s que un buff tiene que llevar ausente
A.ASENTAR_LOGIN   = 12           -- s de silencio tras entrar
A.ASENTAR_ZONING  = 6            -- s extra de silencio tras zonear
-- Silencio tras cambiar el anunciante: una ronda ENTERA de latidos. Si he
-- tomado el mando por error (porque los latidos del bueno se han perdido), en
-- esos 20 s me llega uno suyo y me aparto antes de haber hablado.
A.ASENTAR_ELECCION= 20
-- Rondas de latidos sin oír a nadie mejor antes de tomar el mando. Con 2 rondas
-- y pérdida alta, perder dos latidos seguidos del líder pasa demasiado a menudo.
A.RONDAS_RELEVO   = 5
-- Con 70 s (3,5 latidos) y pérdida alta, perder todos los latidos de alguien
-- que sigue ahí pasa demasiado. 130 s son 6,5 latidos.
A.PRESENCIA_TTL   = 130          -- s sin heartbeat => ese cliente ya no cuenta
-- Si no oigo a NADIE puedo estar solo... o sordo. Ante la duda, callarse. La
-- barra para tomar el mando sin haber oído a un alma es mucho más alta.
A.ESPERA_SORDO    = 210

A.REASIGNA_PLAZO  = 20           -- s para que el relevo tenga efecto
A.MSG_OVERHEAD    = 40           -- lo que cobra ChatThrottleLib por mensaje

-- PRESUPUESTO APARTE PARA LO QUE DISPARA UN HUMANO.
-- Siete asignaciones no caben en 255 caracteres: salen cuatro líneas, y a
-- 6/min congelados un solo clic se comería cuatro de los seis. Los dos números
-- congelados gobiernan lo AUTOMÁTICO, que es lo que se puede ir de las manos
-- solo. El botón lo pulsa una persona que está mirando: tiene su propio cupo y
-- su propio enfriamiento para que dos clics seguidos no lo revienten.
-- Calibrado tras la auditoria: con 20 s de enfriamiento y 1,5 s de espaciado
-- salian 6 lineas en 7,5 s (el doble de la rafaga congelada) y 18/min por
-- oficial, o 54/min con el RL y dos asistentes pulsando a la vez. Presupuesto
-- propio no es barra libre: 4 lineas espaciadas 3,5 s son 3 en cualquier
-- ventana de 10 s, y 60 s de enfriamiento dejan como mucho 4 lineas/min por
-- oficial. Ademas hay enfriamiento DE RAID (ver A.REPARTO_RAID): si alguien
-- acaba de anunciar, el siguiente no puede repetirlo.
A.MANUAL_ENFRIA   = 60           -- s entre dos pulsaciones del boton
A.MANUAL_MAX_LINEAS = 4          -- tope de lineas que puede soltar un clic
A.MANUAL_ESPACIO  = 3.5          -- s entre lineas de la misma rafaga
A.REPARTO_RAID    = 45           -- s tras oir un reparto ajeno antes de anunciar
-- Los susurros del boton de recordar son N mensajes de golpe, y SendChatMessage
-- resta del mismo deposito de 800 B/s: se espacian igual.
A.SUSURRO_ESPACIO = 1.5
A.SUSURRO_ENFRIA  = 30
-- Cada cuánto repite uno sus propias declaraciones. Nadie puede reenviarlas por
-- él, así que si se pierde la única emisión, quien no la oyó le seguirá
-- asignando un hechizo que ha dicho que no tiene.
A.DECL_REPETIR    = 25
-- Enfriamiento POR BUFF del aviso publico. El techo global de 6/min existia,
-- pero nada impedia repetir el MISMO buff una y otra vez mientras siguiera
-- caido: en juego el aviso se repetia sin parar.
A.PUBLICO_BUFF_ENFRIA = 90

-- NUMERO 3 CONGELADO (docs/PRESUPUESTO_CONGELADO.md): una vista abierta deja de
-- pintar como activo un buff caido en menos de 2 s. No se toca; si no se llega,
-- se arregla el codigo.
A.REFRESCO_PLAZO  = 2

-- TECHO DE REPINTADO, declarado en la ronda del 2026-08-02 y COMPROBADO:
-- 2 repintados por segundo y por vista abierta.
-- No es un comentario decorativo: A.REFRESCO_PANEL SALE de este numero, asi que
-- el techo es lo que gobierna el codigo y no al reves. Subirlo afloja el
-- estrangulador de verdad; bajarlo lo aprieta. (Leccion de la ronda 9: una
-- constante que no lee nadie no es un limite, es una promesa.)
--
-- Por que 2/s: en una raid de 25, UNIT_AURA llega decenas de veces por segundo.
-- Repintar por evento hacia el cliente injugable. 2/s deja la peor latencia de
-- pintado en 0,5 s, la cuarta parte del plazo congelado de 2 s, y acota el coste
-- pase lo que pase en la raid: el ritmo de repintado ya no depende de cuantas
-- auras cambien, solo del reloj.
-- La guardia no es paranoia: en Lua 5.1 `1/0` NO da error, da `inf`, y con
-- A.REFRESCO_PANEL = inf el estrangulador no dejaria pintar nunca. Ventana
-- abierta, contenido congelado y ni un solo error de Lua que lo delate.
A.TECHO_REPINTADO = 2
if type(A.TECHO_REPINTADO) ~= "number" or A.TECHO_REPINTADO <= 0 then
  A.TECHO_REPINTADO = 2
end
A.REFRESCO_PANEL  = 1 / A.TECHO_REPINTADO     -- 0,5 s

-- CON UNA VISTA ABIERTA, el barrido va mucho mas rapido. El plazo congelado de
-- 2 s descansa entero en que UNIT_AURA llegue: si no llega —y que llegue es un
-- riesgo ABIERTO de docs/ARNES.md, modelado y no medido—, el techo real de la
-- pantalla no es 2 s sino A.BARRIDO_CADA, o sea medio minuto. Repintar mas a
-- menudo no arregla eso: repinta la misma ficha rancia.
-- SALE DEL PLAZO CONGELADO, como todo lo demas de este bloque: se le resta el
-- intervalo de repintado, de modo que barrido + repintado caben justo en
-- A.REFRESCO_PLAZO. Asi el numero congelado se cumple TAMBIEN sin UNIT_AURA, y
-- deja de descansar sobre una suposicion que nadie ha medido en el cliente.
-- Se paga sondeo (25 jugadores x sus auras) solo mientras hay alguien mirando;
-- con todo cerrado el respaldo vuelve a ser el de 30 s y no se paga nada.
A.BARRIDO_VISTA   = A.REFRESCO_PLAZO - A.REFRESCO_PANEL

-- Con un desplegable abierto no se reconstruye la ventana, y eso NO tiene
-- plazo: el liston dice que un repintado no cierra un desplegable abierto, y
-- "salvo que lleve mucho rato" no es "nunca". Lo que si tiene plazo es el
-- AVISO. En AceGUI un pullout no se cierra al pulsar fuera, y uno vacio (el de
-- perfiles cuando no hay ninguno) se queda abierto sin que haya nada que
-- elegir; pasados estos segundos el panel dice en la cabecera que hay filas
-- esperando, para que nadie se quede mirando una ventana que parece rota.
-- Lo que se aplaza es MONTAR WIDGETS. Todo lo que ya esta en pantalla se sigue
-- actualizando mientras tanto: aplazar no es dejar de decir la verdad.
A.APLAZO_AVISO    = 5

-- Red de seguridad: con una vista abierta, si en este plazo NADIE ha pedido
-- repintar, se pide igual. No es un repintado periodico a ritmo alto —lo que
-- hacia el codigo viejo—: solo levanta la bandera, y el repintado sigue pasando
-- por el techo de arriba. Cubre el caso de que se escape una fuente de cambio
-- sin evento (morir, salir de rango, una ficha que caduca).
--
-- SALE DEL NUMERO 3 CONGELADO, no de un numero suelto. Media el plazo: asi el
-- peor caso de pintado (un intervalo de repintado + una espera de la red) cabe
-- con holgura dentro de A.REFRESCO_PLAZO, y si alguien toca el plazo congelado
-- esto se mueve con el en vez de quedarse descolgado.
A.REFRESCO_SEGURIDAD = A.REFRESCO_PLAZO / 2

-- Estados de la lista cerrada
A.REQ  = "req"
A.OPC  = "opc"
A.PROH = "proh"
A.NONE = "none"                  -- lápida: estuvo en la lista y se quitó

A.ESTADOS_VALIDOS = { req = true, opc = true, proh = true, none = true }

-- Alcance deducido por el catálogo (propone, nunca decide)
A.ALC_RAID     = "raid"
A.ALC_GRUPO    = "grupo"
A.ALC_PERSONAL = "personal"
A.ALC_DUDA     = "?"

-- Cada global de la API que toca este addon. Se audita en tiempo de ejecución
-- contra el entorno: si alguna no existe, el addon lo dice y no la usa.
-- TODAS tienen que existir en 3.3.5a. Nada de C_*, IsInRaid ni firmas de retail.
-- La lista es EXACTAMENTE lo que se invoca, ni una de más ni una de menos.
-- Declarar de más también miente: hace creer que se comprueba algo que no se usa.
A.API_USADA = {
  "CreateFrame", "GetTime", "GetRealmName",
  "UnitName", "UnitClass", "UnitBuff", "UnitGUID",
  "UnitIsVisible", "UnitIsConnected", "UnitIsDeadOrGhost", "UnitAffectingCombat",
  "GetNumRaidMembers", "GetNumPartyMembers", "GetRaidRosterInfo",
  "SendChatMessage", "LibStub", "GetCursorPosition",
}

-- Tope de equivalencias por entrada. Una entrada tiene que caber SIEMPRE en un
-- solo mensaje: si no cabe, no se replica, y un cliente se queda divergente para
-- siempre sin más traza que una línea de chat. 12 IDs son ~84 B de los ~238
-- disponibles, con el resto de campos holgados.
A.MAX_EQUIV = 12
