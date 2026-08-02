-- Protocolo.lua — sincronización entre clientes. Todo por AceComm.
--
-- Versionado desde el primer byte del primer mensaje: el campo PROTO va antes
-- que nada, para que un cliente con otra versión se detecte ANTES de intentar
-- interpretar el resto. Un protocolo que se versiona en el campo 3 ya ha
-- parseado dos campos de un formato que no conoce.
--
-- Mensajes (cuerpo, sin el prefijo de AceComm):
--   <proto>|H|<revMax>|<digest>|<version>        latido: quién soy y qué tengo
--   <proto>|S|<entrada>;<entrada>;...            empujón de estado
--   <proto>|Q                                    "voy atrasado, mándamelo"
--
-- AUTORIDAD. Un empujón de estado sólo se acepta si el REMITENTE tiene rank>=1
-- en GetRaidRosterInfo AHORA MISMO. El nombre del remitente lo pone el
-- servidor en CHAT_MSG_ADDON, no el mensaje, así que no se puede falsificar
-- desde un addon. Por eso no hace falta firmar nada: basta con no fiarse de
-- ningún campo del cuerpo para decidir permisos.

local A = CoABuffs
local P = {}
A.Protocolo = P

local Comm = LibStub("AceComm-3.0")
Comm:Embed(P)

P.presencia    = {}      -- nombre -> {t, proto, version, rev, digest}
-- SABER QUE ALGUIEN LLEVA EL ADDON NO CADUCA A LOS DOS MINUTOS.
-- Usar el mismo TTL para "¿le estoy oyendo ahora?" y para "¿tiene el addon?"
-- es lo que produce el susurro duplicado con pérdida alta: se pierden seis
-- latidos seguidos del anunciante bueno, se le da por ausente, y otro cliente
-- toma el mando encima de él. Que alguien tenga el addon instalado sólo cambia
-- si se va de la raid o si desinstala; se olvida a los 10 minutos, no a los dos.
P.tieneAddon   = {}      -- nombre -> última vez que se le oyó, sin TTL corto
P.TTL_ADDON    = 600
P.incompatibles= {}      -- nombre -> proto ajeno
P.avisadoIncomp= false
P.ultimoPush   = -999
P.ultimaPeticion = -999
P.pendientePush = false
P.rechazos     = 0       -- intentos de escritura sin rango (para el panel)
P.cuarentena   = {}      -- entrada cruda -> quiénes la han repetido
P.sospechosos  = {}      -- quién ha mandado latidos con revisiones imposibles
P.qSinRespuesta = 0      -- peticiones seguidas que no han arreglado nada
P.rechazosDecl = 0       -- declaraciones sobre terceros, rechazadas

local MAX_CUERPO = 254 - #("CoABuffs")     -- 246

local function ahora() return GetTime() end

local function rangoDe(nombre)
  local _, porNombre = A.Escaner.roster()
  local e = porNombre[nombre]
  return e and e.rank or nil
end

-- ------------------------------------------------------------- salida ------

-- COLA PAUSADA. Todo sale por aquí, y el espaciado lo calcula el propio número
-- congelado: tras mandar un mensaje de S bytes, el siguiente no sale hasta
-- S/100 segundos después. Así el presupuesto deja de cumplirse "por aritmética
-- del diseño" y pasa a estar hecho cumplir por el código, que era justo lo que
-- faltaba. Y de paso, cargar un perfil de 15 buffs ya no puede ser una ráfaga.
P.colaEnvio    = {}
P.proximoEnvio = 0

-- CONTADOR ÚNICO DE GASTO. Espaciar por "lo que pesaba el mensaje anterior" no
-- basta: el chat sale por otra vía y resta del MISMO depósito de 800 B/s, y los
-- latidos van por su cuenta. Aquí se apunta todo lo que emite el addon, por el
-- cable o por chat, y la cola no suelta nada que fuera a pasarse. Con un 10% de
-- margen para no rozar el tope medido.
P.gasto = {}

function P.apuntarGasto(bytes)
  P.gasto[#P.gasto + 1] = { t = ahora(), n = bytes }
end

function P.cabeGastar(bytes)
  local t = ahora()
  while #P.gasto > 0 and (t - P.gasto[1].t) > A.PRESUP_VENTANA do table.remove(P.gasto, 1) end
  local s10, s1 = 0, 0
  for i = 1, #P.gasto do
    s10 = s10 + P.gasto[i].n
    if (t - P.gasto[i].t) <= 1.0 then s1 = s1 + P.gasto[i].n end
  end
  return (s10 + bytes) <= (A.PRESUP_BPS * A.PRESUP_VENTANA * 0.9)
     and (s1 + bytes) <= (A.PRESUP_RAFAGA * 0.9)
end

function P.enviar(cuerpo, dist, destino, prio)
  -- Cinturón: nunca se emite algo que no quepa. Si esto salta es un fallo del
  -- troceador de arriba, no del cable, y hay que verlo.
  if #cuerpo > MAX_CUERPO then
    A.log("ERROR: mensaje de %d B por encima de %d; no se envia", #cuerpo, MAX_CUERPO)
    return false
  end
  -- Sin duplicados y con tope. Una inundación de peticiones no puede convertirse
  -- en una cola de cientos de mensajes que tarda minutos en drenar.
  for i = 1, #P.colaEnvio do
    if P.colaEnvio[i].cuerpo == cuerpo and P.colaEnvio[i].destino == destino then
      return true
    end
  end
  if #P.colaEnvio >= 40 then
    A.log_debug("cola de envio llena (%d): se descarta %s", #P.colaEnvio, cuerpo:sub(1, 20))
    return false
  end
  P.colaEnvio[#P.colaEnvio + 1] = { cuerpo = cuerpo, dist = dist or "RAID",
                                    destino = destino, prio = prio or "NORMAL" }
  return true
end

-- Declaración propia: "no tengo este hechizo". El sujeto viaja en el mensaje
-- para que el que recibe pueda comprobar que coincide con el remitente.
function P.declarar(spellId, sin)
  local e = A.Declaraciones.declarar(spellId, sin)
  P.emitirDeclaracion(spellId)
  P.proxDecl = ahora() + A.DECL_REPETIR
  return e
end

function P.emitirDeclaracion(spellId)
  local e = A.Declaraciones.datos[A.yo] and A.Declaraciones.datos[A.yo][spellId]
  if not e then return end
  P.enviar(string.format("%d|D|%s|%d|%d|%d", A.PROTO, A.yo, spellId,
                         e.sin and 1 or 0, e.rev), "RAID", nil, "NORMAL")
end

-- REEMISIÓN. Una declaración se manda una vez y el cable pierde el 8%: con 25
-- clientes, siempre hay dos que no se enteran, y esos dos siguen asignándole el
-- buff a quien ha dicho que no lo tiene. Nadie más puede reenviarla por él —es
-- una afirmación sobre uno mismo—, así que la repite su dueño cada rato. Son
-- unas decenas de bytes y van por la cola con presupuesto, como todo.
P.proxDecl = 0
function P.repetirDeclaraciones()
  local mias = A.Declaraciones.datos[A.yo]
  if not mias then return end
  local ids = {}
  for spellId in pairs(mias) do ids[#ids + 1] = spellId end
  table.sort(ids)
  for i = 1, #ids do P.emitirDeclaracion(ids[i]) end
end

-- Un perfil entero, troceado. No sale de golpe: entra en la cola pausada.
function P.empujarPerfil(entradas)
  local trozos, largo = {}, 0
  local function volcar()
    if #trozos == 0 then return end
    P.enviar(string.format("%d|S|%s", A.PROTO, table.concat(trozos, ";")), "RAID")
    trozos, largo = {}, 0
  end
  for i = 1, #entradas do
    local s = A.Estado.serializarEntrada(entradas[i])
    if largo + #s + 1 > (MAX_CUERPO - 8) then volcar() end
    trozos[#trozos + 1] = s
    largo = largo + #s + 1
  end
  volcar()
  P.ultimoPush = ahora()
end

function P.latido()
  P.enviar(string.format("%d|H|%d|%s|%s", A.PROTO, A.Estado.revMax(),
                         A.Estado.digest(), A.VERSION), "RAID", nil, "BULK")
end

-- Empuja la lista entera, en bloques que caben sin trocear.
function P.empujarEstado(dist, destino)
  local bloques = A.Estado.bloques(MAX_CUERPO - 8)
  if #bloques == 0 then
    P.enviar(string.format("%d|S|", A.PROTO), dist, destino)
    return
  end
  for i = 1, #bloques do
    P.enviar(string.format("%d|S|%s", A.PROTO, table.concat(bloques[i], ";")),
             dist, destino, "NORMAL")
  end
  P.ultimoPush = ahora()
end

-- Empuja sólo lo que acaba de cambiar. Es el camino normal tras una edición:
-- una entrada son ~40 B de cuerpo, 89 B de coste.
function P.empujarEntradas(entradas)
  local trozos = {}
  for i = 1, #entradas do trozos[#trozos + 1] = A.Estado.serializarEntrada(entradas[i]) end
  local cuerpo = string.format("%d|S|%s", A.PROTO, table.concat(trozos, ";"))
  if #cuerpo <= MAX_CUERPO then
    P.enviar(cuerpo, "RAID")
  else
    P.empujarEstado("RAID")
  end
  P.ultimoPush = ahora()
end

-- ------------------------------------------------------------ entrada ------

function P:OnCommReceived(prefix, mensaje, dist, remitente)
  if prefix ~= A.PREFIJO then return end
  if remitente == A.yo then return end          -- el eco propio no aporta nada

  local proto, resto = mensaje:match("^(%d+)|(.*)$")
  proto = tonumber(proto)
  if not proto then return end                  -- basura o formato futuro

  if proto ~= A.PROTO then
    P.incompatibles[remitente] = proto
    if not P.avisadoIncomp then
      P.avisadoIncomp = true
      A.log("|cffff8800%s de %s habla el protocolo %d y este cliente el %d. " ..
            "No se sincronizara con el hasta que uno de los dos actualice.|r",
            A.NOMBRE, remitente, proto, A.PROTO)
    end
    return
  end

  local verbo, cuerpo = resto:match("^(%a)|?(.*)$")
  if not verbo then return end

  if verbo == "H" then
    local rev, digest, ver = cuerpo:match("^(%d+)|([^|]*)|(.*)$")
    if not rev then return end
    P.presencia[remitente] = { t = ahora(), proto = proto, version = ver,
                               rev = tonumber(rev), digest = digest }
    -- El reloj de Lamport también avanza con lo que se OYE, no sólo con lo que
    -- se recibe: así una edición nunca nace por debajo de lo que ya corre.
    P.tieneAddon[remitente] = ahora()
    -- OJO AL ORDEN. Antes esta línea iba ANTES del filtro de revisión imposible
    -- de más abajo: el filtro hacía return, pero el reloj ya estaba envenenado.
    -- Un solo latido forjado por un rango 0 con rev 1e20 dejaba a 24 clientes
    -- fabricando revisiones que no caben en un entero, que se serializaban mal
    -- y que todo el mundo tiraba: la lista dejaba de replicarse para siempre y
    -- sin un aviso. Se valida PRIMERO y se apunta DESPUÉS.
    local suRevN = tonumber(rev)
    if not suRevN or suRevN ~= math.floor(suRevN) or suRevN < 0 or suRevN >= 2147483647 then
      P.sospechosos[remitente] = (P.sospechosos[remitente] or 0) + 1
      return
    end
    -- Si el otro va por delante, o vamos empatados pero con listas distintas,
    -- se pide resincronización. Con espaciado: 25 clientes pidiendo a la vez
    -- son 25 mensajes que no arreglan nada.
    local miRev = A.Estado.revMax()
    local suRev = tonumber(rev)
    local miRango = rangoDe(A.yo) or 0

    -- Revisión absurda = latido forjado. Un rango 0 que anuncia rev 2^31 deja a
    -- los 25 clientes creyéndose atrasados PARA SIEMPRE, pidiendo resincronía
    -- cada 15 s el resto de la raid. Nadie salta de mil revisiones de golpe.
    if suRev > miRev + 1000 then
      P.sospechosos[remitente] = (P.sospechosos[remitente] or 0) + 1
      A.log_debug("latido con revision imposible de %s (%d frente a %d): ignorado",
                  remitente, suRev, miRev)
      return
    end
    -- Sólo AQUÍ, ya validada, entra en el reloj de Lamport.
    A.Estado.verRev(suRev)

    -- Si el otro va POR DETRÁS y yo soy oficial, se lo empujo sin que lo pida.
    -- Es lo que rescata al que entra en frío o vuelve de una desconexión: no
    -- depende de que su petición llegue, y la petición se pierde igual que todo.
    if miRango >= 1 and (suRev < miRev
        or (suRev == miRev and digest ~= A.Estado.digest())) then
      if (ahora() - P.ultimoPush) > 10 then P.pendientePush = true end
    end

    -- Si el que va por detrás soy yo, pido. A la RAID, no al remitente: sólo
    -- un oficial puede contestar algo que los demás vayan a aceptar, y el
    -- remitente del latido puede ser un rango 0.
    local desincronizado = (suRev > miRev)
                        or (suRev == miRev and digest ~= A.Estado.digest())
    -- Evidencia POSITIVA de ir por detrás. Mientras esto esté puesto, este
    -- cliente no puede editar: su revisión nacería por debajo de la que ya
    -- corre, la rechazarían los 25, y el cambio se le desharía solo sin que
    -- nadie le explicara nada.
    if suRev > miRev then P.desincronizado = true end
    -- Espera creciente. Si se pide diez veces y nadie contesta, seguir pidiendo
    -- cada 15 s es ruido: se dobla el intervalo hasta un tope de 4 minutos.
    local espera = math.min(15 * (2 ^ math.min(P.qSinRespuesta, 4)), 240)
    if desincronizado and (ahora() - P.ultimaPeticion) > espera then
      P.ultimaPeticion = ahora()
      P.qSinRespuesta = P.qSinRespuesta + 1
      P.enviar(string.format("%d|Q", A.PROTO), "RAID", nil, "BULK")
    end

  elseif verbo == "Q" then
    -- Contestan TODOS, también los de rango 0. Atar la autoridad al portador
    -- del paquete abría un agujero de convergencia: si los únicos que tienen la
    -- entrada más nueva son de rango 0 —porque el oficial que la escribió la
    -- empujó y se desconectó— no hay ningún camino por el que esa entrada
    -- vuelva a salir, y la raid se queda partida para siempre. Lo que impide la
    -- falsificación no es callar al rango 0, es exigir CORROBORACIÓN al fundir
    -- (ver abajo).
    if (ahora() - P.ultimoPush) > 10 then
      P.pendientePush = true
    end
    -- Y cada uno repite LO SUYO. Las declaraciones no las puede reenviar nadie
    -- más —sólo valen sobre uno mismo—, así que si alguien pide resincronizar,
    -- el que tiene algo declarado se lo vuelve a decir él. Con enfriamiento
    -- propio: sin él, 200 peticiones forjadas encolan cientos de mensajes y
    -- dejan la cola atascada diez minutos.
    if P.proxDecl > 0 and (ahora() - (P.ultimaRepeticion or -999)) > 20 then
      P.ultimaRepeticion = ahora()
      P.repetirDeclaraciones()
    end

  elseif verbo == "R" then
    -- El RL ha anunciado el reparto: se abre el panel de solo lectura a todo el
    -- mundo. No edita nada ni puede: es otra ventana. Pero abrirle la ventana a
    -- 25 personas tampoco puede hacerlo cualquiera ni cada dos segundos.
    local rank = rangoDe(remitente) or 0
    if rank < 1 then return end
    if (ahora() - (P.ultimoRepartoRecibido or -999)) < 20 then return end
    P.ultimoRepartoRecibido = ahora()
    A.Avisos.ultimoRepartoOido = ahora()
    if A.Reparto then A.Reparto.abrir() end
    -- Y si el anunciante electo soy yo, las líneas las suelto yo. Uno solo.
    if A.Avisos.soyAnunciante() then A.Avisos.emitirReparto() end

  elseif verbo == "D" then
    -- DECLARACIÓN "no tengo este hechizo".
    -- No hace falta rango: es una afirmación de uno sobre sí mismo. Pero POR ESO
    -- MISMO sólo vale sobre uno mismo. El sujeto viaja en el mensaje y se
    -- compara con el remitente, que lo pone el servidor y no se falsifica. Si no
    -- coinciden, a la basura: nadie declara por terceros.
    local sujeto, spellId, sin, rev = cuerpo:match("^([^|]+)|(%d+)|([01])|(%d+)$")
    if not sujeto then return end
    if sujeto ~= remitente then
      P.rechazosDecl = P.rechazosDecl + 1
      A.log_debug("rechazada declaracion de %s SOBRE %s: nadie declara por otros",
                  remitente, sujeto)
      return
    end
    if A.Declaraciones.fusionar(sujeto, tonumber(spellId), sin == "1", tonumber(rev)) then
      A.alCambiarEstado()
    end

  elseif verbo == "S" then
    -- AUTORIDAD. Aquí y sólo aquí. Dos vías, y ninguna se fía de un campo del
    -- cuerpo para decidir permisos:
    --
    --  * si el REMITENTE es oficial ahora mismo, se acepta directo. El nombre
    --    del remitente lo pone el servidor, no el mensaje: no se falsifica.
    --  * si el remitente es rango 0, sólo puede REPETIR lo que ya dijo otro:
    --    la entrada se guarda en cuarentena y no entra hasta que un SEGUNDO
    --    cliente distinto mande exactamente lo mismo, byte a byte.
    --
    -- Eso cierra el agujero de convergencia (un rango 0 puede reenviar una
    -- entrada legítima de un oficial que ya no está) sin abrir la falsificación
    -- (uno solo no puede corroborarse a sí mismo). Dos rangos 0 conchabados sí
    -- podrían: se asume, y queda escrito.
    local rank = rangoDe(remitente) or 0
    local oficial = rank >= 1

    local remotas, n = {}, 0
    for trozo in cuerpo:gmatch("[^;]+") do
      local e = A.Estado.parsearEntrada(trozo)
      if e then
        if oficial then
          remotas[e.spellId] = e; n = n + 1
        else
          local clave = trozo
          P.cuarentena[clave] = P.cuarentena[clave] or { quienes = {}, n = 0, t = ahora() }
          local q = P.cuarentena[clave]
          if not q.quienes[remitente] then
            q.quienes[remitente] = true
            q.n = q.n + 1
          end
          if q.n >= 2 then
            remotas[e.spellId] = e; n = n + 1
            A.log_debug("entrada corroborada por %d clientes sin rango: %s", q.n, clave)
          else
            P.rechazos = P.rechazos + 1
          end
        end
      end
    end
    if n == 0 then return end
    local cambio = A.Estado.fusionar(remotas)
    -- Ha servido de algo: se rearma la espera de las peticiones.
    if cambio then
      P.qSinRespuesta = 0
      P.desincronizado = false
      A.alCambiarEstado()
    end
  end
end

-- ------------------------------------------------------------- utilidad ----

function P.companeros()
  local n, t = 0, ahora()
  for _, v in pairs(P.presencia) do
    if (t - v.t) < A.PRESENCIA_TTL then n = n + 1 end
  end
  return n
end

function P.hayIncompatibles()
  return next(P.incompatibles) ~= nil
end

function P.tick()
  if P.pendientePush then
    P.pendientePush = false
    P.empujarEstado("RAID")
  end
  if ahora() >= P.proxDecl and P.proxDecl > 0 then
    P.proxDecl = ahora() + A.DECL_REPETIR
    P.repetirDeclaraciones()
  end

  -- Drenaje gobernado por el presupuesto congelado, no por un temporizador.
  if #P.colaEnvio > 0 then
    local m = P.colaEnvio[1]
    local coste = #A.PREFIJO + 1 + #m.cuerpo + A.MSG_OVERHEAD
    if P.cabeGastar(coste) then
      table.remove(P.colaEnvio, 1)
      P:SendCommMessage(A.PREFIJO, m.cuerpo, m.dist, m.destino, m.prio)
      P.apuntarGasto(coste)
    end
  end
end
