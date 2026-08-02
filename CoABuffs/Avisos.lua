-- Avisos.lua — las dos vías de aviso, y todo lo que impide que sean un fallo.
--
-- GRAMÁTICA CONGELADA (el arnés la parsea; salirse de ella es un defecto):
--   público  CoABuffs: FALTA <buff> x<n>[; <buff> x<n>]*[ -- sin datos: <k>]
--            CoABuffs: PROHIBIDO <buff> x<n>[; ...][ -- sin datos: <k>]
--            CoABuffs: OK -- sin datos: <k>
--   (el separador NO lleva "|": en chat abre un código de escape y el cliente
--    rechaza el mensaje entero. Ver seguroParaChat más abajo.)
--   susurro  CoABuffs: te toca <buff> :: <nombre>[,<nombre>]*
--            CoABuffs: quitate <buff>
--
-- EN PÚBLICO NUNCA VA UN NOMBRE. El resumen a la raid es agregado: cuántos,
-- no quiénes. Señalar a alguien delante de 24 personas es lo que hace que un
-- addon de buffs se desinstale, y además no aporta: quien tiene que actuar es
-- el asignado, y a ese se le susurra.
--
-- TRES CANDADOS CONTRA EL FALSO POSITIVO, que es el criterio que manda:
--   1. sólo entra en la cuenta quien es observable y tiene ficha fresca
--   2. la ausencia tiene que llevar CONFIRMA segundos seguida
--   3. SE VUELVE A COMPROBAR justo antes de emitir, y se cae del mensaje quien
--      ya lo tenga. Entre que se decide anunciar y que sale la línea pasan
--      segundos, y en esos segundos alguien puede haber buffeado.

local A = CoABuffs
local V = {}
A.Avisos = V

V.faltaDesde   = {}     -- "nombre|spellId" -> t
V.cola         = {}     -- {prio, texto, dist, destino, clave}
V.ultimoChat   = -999
V.ultimoPublico= -999
V.ultimoSusurro= {}     -- nombre -> t
V.anunciante   = nil
V.anuncianteDesde = 0
V.efectivoPrevio = {}   -- spellId -> ultimo asignado efectivo visto
V.ultimaVia    = nil    -- "RAID" | "WHISPER", para que ninguna ahogue a la otra
-- SUELO COMPARTIDO POR LAS DOS VIAS. La automatica y la manual llevaban cada
-- una su reloj (V.ultimoChat / V.proximoManual) y ninguna miraba a la otra: en
-- el mismo tick podian salir dos lineas de chat con 0,00 s entre ellas, que es
-- justo lo que A.SUSURRO_ESPACIO dice evitar. El deposito de bytes ya era
-- comun; el espaciado en el tiempo no lo era.
V.ultimaLinea  = 0
V.enCombate    = false
V.emitidos     = 0

local function ahora() return GetTime() end

-- NADA CON "|" PUEDE ACABAR EN SendChatMessage.
-- En WoW la barra abre un código de escape de interfaz (|cAARRGGBB, |r, |H..|h,
-- |T..|t, |n, ||). Un "| " suelto no es ninguno de ésos y el cliente rechaza el
-- MENSAJE ENTERO con "Invalid escape code in chat message". Pasó en juego: 306
-- rechazos seguidos, porque el separador " | sin datos: N" del resumen llevaba
-- una barra. Se limpia en el único sitio por el que sale texto al chat, no en
-- cada sitio donde se construye, que es como se vuelve a colar.
-- Ojo: esto NO aplica al cable. A.Protocolo.enviar acaba en SendAddonMessage,
-- que no valida escapes, y ahí la barra es el separador del protocolo.
local function seguroParaChat(t)
  return (tostring(t or ""):gsub("|", ""))
end
V.seguroParaChat = seguroParaChat
V.rechazados = 0

-- ------------------------------------------------------------ combate ------
-- Estricto a propósito: basta con que se vea a alguien en combate para callarse.
function V.raidEnCombate()
  if UnitAffectingCombat("player") then return true end
  if V.enCombate then return true end
  local lista = A.Escaner.roster()
  for i = 1, #lista do
    local e = lista[i]
    if A.Escaner.observable(e) and UnitAffectingCombat(e.unidad) then return true end
  end
  return false
end

-- --------------------------------------------------------- anunciante ------
-- Elección determinista. Habla UNO. Si hablaran los 25, la raid vería 25 veces
-- la misma línea y el addon duraría un pull.
local function mejorDe(a, b)
  if not a then return b end
  if not b then return a end
  if a.rank ~= b.rank then return (a.rank > b.rank) and a or b end
  return (a.idx <= b.idx) and a or b
end

function V.elegirAnunciante()
  local lista, porNombre = A.Escaner.roster()
  local t = ahora()

  -- Mejor candidato entre los que SE SABE que llevan el addon (incluido yo).
  -- Se mira la memoria larga, no la presencia reciente: perder unos latidos no
  -- significa que a alguien se le haya desinstalado el addon. Si se ha ido de
  -- la raid o está desconectado, eso ya lo dice el roster y lo filtra presente().
  for nombre, visto in pairs(A.Protocolo.tieneAddon) do
    if (t - visto) > A.Protocolo.TTL_ADDON then A.Protocolo.tieneAddon[nombre] = nil end
  end
  local conAddon = porNombre[A.yo]
  for nombre in pairs(A.Protocolo.tieneAddon) do
    local e = porNombre[nombre]
    if e and A.Escaner.presente(e) then conAddon = mejorDe(conAddon, e) end
  end

  -- Mejor candidato de TODO el roster, lleve addon o no.
  local mejorRoster
  for i = 1, #lista do
    if A.Escaner.presente(lista[i]) then mejorRoster = mejorDe(mejorRoster, lista[i]) end
  end

  local nuevo = conAddon and conAddon.nombre or A.yo
  if nuevo ~= V.anunciante then
    V.anunciante = nuevo
    V.anuncianteDesde = t
  end
  V.mejorRoster = mejorRoster and mejorRoster.nombre or nil
  return V.anunciante
end

-- CARRERA DE ARRANQUE. Al principio nadie ha recibido ningún latido, así que
-- los 25 clientes se creen el anunciante y la raid ve la misma línea 25 veces.
-- La regla que lo corta sin negociar nada:
--   * si soy el mejor candidato de TODO el roster (líder, o el de índice más
--     bajo a igual rango), hablo ya: por encima de mí no hay nadie que pueda
--     aparecer más tarde y quitarme el turno.
--   * si no lo soy, me callo hasta que hayan pasado dos rondas de latidos. Si
--     en ese tiempo no he oído a nadie mejor que yo, es que no llevan el addon
--     y entonces sí me toca.
-- Determinista, sin mensajes extra y converge sola.
function V.soyAnunciante()
  local elegido = V.elegirAnunciante()
  if elegido ~= A.yo then return false end
  if V.mejorRoster == A.yo then return true end
  -- El reloj cuenta desde que se entró EN EL GRUPO, no desde el login: un
  -- cliente con una hora de sesión que entra en raid tendría el plazo ya
  -- vencido y hablaría antes de haber oído a nadie.
  local desde = math.max(A.arrancado, A.enGrupoDesde or 0)
  -- "No oigo a nadie mejor" NO es lo mismo que "no hay nadie mejor". Un cliente
  -- incomunicado deduce lo segundo de lo primero y se pone a hablar encima del
  -- anunciante bueno: eso es el susurro duplicado que aparece a partir de los
  -- ~190 s con pérdida alta. Si oigo a alguien, el silencio del mejor sí es
  -- prueba de que no lleva el addon. Si no oigo a nadie, el sordo puedo ser yo.
  if A.Protocolo.companeros() > 0 then
    return (ahora() - desde) > (A.RONDAS_RELEVO * A.HEARTBEAT_CADA)
  end
  return (ahora() - desde) > A.ESPERA_SORDO
end

-- TECHO CONGELADO, HECHO CUMPLIR.
-- El espaciado de 12 s / 24 s ya deja el ritmo muy por debajo del tope, pero eso
-- lo cumple la aritmética, no el código: si alguien toca A.ANUNCIO_CADA no salta
-- nada. Esto es el candado que sí mira los números congelados de verdad, con la
-- misma ventana deslizante con la que los mide el arnés. Si alguna vez se
-- rozara el tope, el addon se calla en vez de pasarse.
V.publicos = {}

function V.cabeOtroPublico()
  local t = ahora()
  for i = #V.publicos, 1, -1 do
    if (t - V.publicos[i]) > 60 then table.remove(V.publicos, i) end
  end
  local c60, c10 = 0, 0
  for i = 1, #V.publicos do
    local dt = t - V.publicos[i]
    if dt < 60 then c60 = c60 + 1 end
    if dt < 10 then c10 = c10 + 1 end
  end
  return (c60 < A.ANUNCIOS_MIN) and (c10 < A.ANUNCIOS_RAFAGA)
end

-- Canal público según dónde estemos. Estando solo NO se habla: mandar a RAID
-- fuera de raid produce un error rojo de interfaz.
function V.canalPublico()
  if GetNumRaidMembers() > 0 then return "RAID" end
  if GetNumPartyMembers() > 0 then return "PARTY" end
  return nil
end

-- ------------------------------------------------------------ conteo -------
-- Devuelve, por entrada requerida: cuántos observables no lo tienen (estable),
-- y la lista de nombres (que sólo se usa en susurro, jamás en público).
function V.faltantes()
  local lista, porNombre = A.Escaner.roster()
  local t = ahora()
  local porBuff = {}
  local ids = A.Estado.lista()
  for k = 1, #ids do
    local entrada = A.Estado.get(ids[k])
    if entrada.estado == A.REQ or entrada.estado == A.PROH then
      local nombres = {}
      for i = 1, #lista do
        local e = lista[i]
        local tiene = A.Escaner.estadoBuff(e, entrada)
        local clave = e.nombre .. "|" .. entrada.spellId
        local mal
        if tiene == nil then
          mal = nil                                   -- SIN DATOS: no se cuenta
        elseif entrada.estado == A.REQ then
          mal = (tiene == false)
        else
          mal = (tiene == true)
        end
        if mal then
          V.faltaDesde[clave] = V.faltaDesde[clave] or t
          if (t - V.faltaDesde[clave]) >= A.CONFIRMA then
            nombres[#nombres + 1] = e.nombre
          end
        else
          V.faltaDesde[clave] = nil
        end
      end
      if #nombres > 0 then
        porBuff[#porBuff + 1] = { entrada = entrada, nombres = nombres }
      end
    end
  end
  table.sort(porBuff, function(a, b) return a.entrada.spellId < b.entrada.spellId end)
  return porBuff, porNombre
end

-- Recomprobación en el momento de emitir. Tercer candado.
local function siguenMal(entrada, nombres)
  local out = {}
  local _, porNombre = A.Escaner.roster()
  for i = 1, #nombres do
    local tiene = A.Escaner.estadoBuff(porNombre[nombres[i]], entrada)
    if tiene ~= nil then
      if (entrada.estado == A.REQ and tiene == false)
      or (entrada.estado == A.PROH and tiene == true) then
        out[#out + 1] = nombres[i]
      end
    end
  end
  return out
end

-- ------------------------------------------------------------- cola --------
local function encolar(prio, texto, dist, destino, clave, spellId)
  for i = 1, #V.cola do if V.cola[i].clave == clave then return end end
  V.cola[#V.cola + 1] = { prio = prio, texto = texto, dist = dist,
                          destino = destino, clave = clave, spellId = spellId }
  table.sort(V.cola, function(a, b) return a.prio < b.prio end)
end

function V.planificar()
  if A.apagadoPorAPI then V.cola = {}; return end
  if not V.canalPublico() then V.cola = {}; return end
  if not V.soyAnunciante() then V.cola = {}; return end
  if (ahora() - A.arrancado) < A.ASENTAR_LOGIN then return end
  if (ahora() - V.anuncianteDesde) < A.ASENTAR_ELECCION then return end
  if V.raidEnCombate() then V.cola = {}; return end

  local porBuff = V.faltantes()
  local _, sinDatos = A.Escaner.cobertura()
  local efectivos = A.Asignacion.derivar(A.Escaner.roster())

  -- vía 1: susurro al asignado efectivo (prioridad: es quien tiene que actuar)
  for i = 1, #porBuff do
    local b = porBuff[i]
    if b.entrada.estado == A.REQ then
      local quien = efectivos[b.entrada.spellId]
      local id = b.entrada.spellId
      -- RELEVO. Si el asignado efectivo ha cambiado (se ha muerto, se ha ido,
      -- se ha desconectado), el aviso al sustituto no espera turno detrás de
      -- los recordatorios de rutina: adelanta y se salta su propio enfriamiento.
      -- Un relevo que llega tarde es un buff que no se pone.
      local cambio = (V.efectivoPrevio[id] ~= nil) and (V.efectivoPrevio[id] ~= quien)
      V.efectivoPrevio[id] = quien
      if quien and (cambio or (ahora() - (V.ultimoSusurro[quien] or -999)) > 30) then
        encolar(cambio and 0 or 1,
                string.format("%s: te toca %s :: %s", A.NOMBRE, b.entrada.nombre,
                              table.concat(b.nombres, ",")),
                "WHISPER", quien, "w" .. id .. quien, id)
      end
    else
      for k = 1, #b.nombres do
        local quien = b.nombres[k]
        if (ahora() - (V.ultimoSusurro[quien] or -999)) > 30 then
          encolar(1, string.format("%s: quitate %s", A.NOMBRE, b.entrada.nombre),
                  "WHISPER", quien, "p" .. b.entrada.spellId .. quien, b.entrada.spellId)
        end
      end
    end
  end

  -- vía 2: resumen agregado a la raid, sin un solo nombre.
  -- Se encola un HUECO, no un texto. El texto se construye en el momento de
  -- emitir: entre encolar y emitir pasan hasta 12 s, y en 12 s de raid cambia
  -- todo. Un resumen construido al encolar es un falso positivo esperando.
  if (ahora() - V.ultimoPublico) > 24 and V.textoPublico() then
    encolar(2, "", V.canalPublico(), nil, "publico")
  end
end

-- Construye el resumen público AHORA. Devuelve nil si no hay nada que decir.
-- Ni un solo nombre propio: cuántos, no quiénes.
V.ultimoPublicoBuff = {}

-- Devuelve texto, ids. Los ids son SOLO los que acaban dentro de la cadena que
-- se devuelve: antes se enfriaban los 12 candidatos y la linea nombraba 6, asi
-- que seis buffs de raid caidos se quedaban 90 s sin que nadie los mencionara.
-- Y el marcado se hace fuera, DESPUES de enviar de verdad.
function V.textoPublico()
  local porBuff = V.faltantes()
  local faltan, prohibidos = {}, {}
  local t = ahora()
  for i = 1, #porBuff do
    local b = porBuff[i]
    local vivos = siguenMal(b.entrada, b.nombres)
    -- ENFRIAMIENTO POR BUFF. El techo global de 6/min no impedia repetir el
    -- MISMO buff sin parar mientras siguiera caido, y eso es lo que se veia en
    -- juego. Cada buff calla lo suyo aunque haya hueco en el ritmo global.
    local ultimo = V.ultimoPublicoBuff[b.entrada.spellId] or -999
    if #vivos > 0 and (t - ultimo) > A.PUBLICO_BUFF_ENFRIA then
      local trozo = { txt = string.format("%s x%d", b.entrada.nombre, #vivos),
                      id = b.entrada.spellId }
      if b.entrada.estado == A.REQ then faltan[#faltan + 1] = trozo
      else prohibidos[#prohibidos + 1] = trozo end
    end
  end
  -- La cobertura ("sin datos: N") YA NO va al canal publico: ensuciaba cada
  -- linea con algo que solo le importa al RL. Sigue en /cab estado y en su panel.
  -- TOPE DE LONGITUD. Con 16 buffs requeridos la linea llegaba a 574 B: el chat
  -- corta en 255 y la raid leia una cuenta a medias, ademas de cobrarse 614 B de
  -- golpe contra la rafaga congelada. Se recorta por trozos ENTEROS, nunca a
  -- media palabra, que romperia la gramatica. Y se devuelven los ids que SI han
  -- entrado, que son los unicos que pueden enfriarse.
  local function juntar(lista)
    local acum, ids, largo = {}, {}, #A.NOMBRE + 10
    for i = 1, #lista do
      if largo + #lista[i].txt + 2 > 230 then break end
      acum[#acum + 1] = lista[i].txt
      ids[#ids + 1] = lista[i].id
      largo = largo + #lista[i].txt + 2
    end
    return table.concat(acum, "; "), ids
  end
  if #faltan > 0 then
    local s, ids = juntar(faltan)
    return string.format("%s: FALTA %s", A.NOMBRE, s), ids
  elseif #prohibidos > 0 then
    local s, ids = juntar(prohibidos)
    return string.format("%s: PROHIBIDO %s", A.NOMBRE, s), ids
  end
  return nil
end

-- Se llama SOLO tras haber enviado de verdad.
function V.marcarEnfriamiento(ids)
  local t = ahora()
  for i = 1, #(ids or {}) do V.ultimoPublicoBuff[ids[i]] = t end
end

function V.emitir()
  if #V.cola == 0 then return end
  if (ahora() - V.ultimaLinea) < A.SUSURRO_ESPACIO then return end
  if A.apagadoPorAPI then V.cola = {}; return end
  if not V.canalPublico() then V.cola = {}; return end
  if not V.soyAnunciante() then V.cola = {}; return end
  if V.raidEnCombate() then V.cola = {}; return end
  if (ahora() - V.ultimoChat) < A.ANUNCIO_CADA then return end

  -- ANTI-INANICIÓN. Con prioridad estricta, los susurros de rutina no dejan
  -- salir nunca el resumen público: siempre hay un susurro pendiente y siempre
  -- va delante. Así que si lo último que salió fue un susurro y hay resumen
  -- esperando, le toca al resumen. Los relevos (prio 0) sí pasan por encima:
  -- son urgentes por definición.
  local idx = 1
  if V.ultimaVia == "WHISPER" and V.cola[1] and V.cola[1].prio > 0 then
    for i = 1, #V.cola do
      if V.cola[i].dist ~= "WHISPER" then idx = i; break end
    end
  end
  local m = table.remove(V.cola, idx)

  -- Tercer candado: rehacer la cuenta ahora mismo. Puede haber quedado vacía.
  if m.dist == "WHISPER" then
    -- La entrada se recupera por spellId, que viaja con el mensaje en la cola.
    -- Antes se sacaba parseando el propio texto y buscando por nombre visible:
    -- dos buffs con el mismo nombre daban el equivocado, y un nombre de aura con
    -- " :: " o una coma rompía el parseo. En un servidor con contenido custom
    -- eso no se puede descartar.
    local entrada = m.spellId and A.Estado.get(m.spellId)
    -- Y el DESTINATARIO también se recomprueba. Entre encolar y emitir pasan
    -- segundos, y en esos segundos el asignado efectivo puede haber cambiado:
    -- se ha muerto, se ha ido, o ha declarado que no tiene el hechizo. Mandarle
    -- el recordatorio igual es pedirle algo que no puede hacer.
    if entrada then
      local lista, porNombre = A.Escaner.roster()
      local efectivos = A.Asignacion.derivar(lista, porNombre)
      if efectivos[m.spellId] ~= m.destino then return end
    end
    local nombres = m.texto:match(":: (.+)$")
    if entrada and nombres then
      local lista = {}
      for n in nombres:gmatch("[^,]+") do lista[#lista + 1] = n end
      local vivos = siguenMal(entrada, lista)
      if #vivos == 0 then return end
      m.texto = string.format("%s: te toca %s :: %s", A.NOMBRE, entrada.nombre,
                              table.concat(vivos, ","))
    end
  else
    -- Tercer candado, también aquí: se rehace la línea entera con los datos de
    -- este instante. Si ya no hay nada que decir, no se dice nada.
    if not V.cabeOtroPublico() then return end
    local txt, ids = V.textoPublico()
    if not txt then return end
    m.texto = txt
    m.idsEnfriar = ids
  end

  -- Y la via AUTOMATICA tambien pregunta antes de gastar. Estaba al reves de lo
  -- que decia su propio comentario: la manual consultaba el deposito y esta no.
  m.texto = seguroParaChat(m.texto)
  local coste = #m.texto + #tostring(m.destino or "") + A.MSG_OVERHEAD
  if not A.Protocolo.cabeGastar(coste) then
    table.insert(V.cola, idx, m)   -- falta presupuesto: se devuelve a la cola
    return
  end

  -- EL INTENTO SE CONTABILIZA PASE LO QUE PASE, y la llamada va protegida.
  -- Si SendChatMessage falla y no se apunta el gasto ni se mueve el reloj del
  -- ritmo, el siguiente tick regenera el mismo texto y lo reintenta: es
  -- exactamente el bucle de 306 rechazos seguidos. Un mensaje que el cliente
  -- rechaza se DESCARTA con registro; ya está fuera de la cola.
  -- SUSURRARSE A UNO MISMO NO. Si el destinatario soy yo, mensaje local: el
  -- servidor no manda susurros a tu propio nombre y ademas queda ridiculo.
  local ok, err = true, nil
  if m.dist == "WHISPER" and m.destino == A.yo then
    A.log("%s", m.texto)
  else
    ok, err = pcall(SendChatMessage, m.texto, m.dist, nil, m.destino)
  end
  A.Protocolo.apuntarGasto(coste)
  V.ultimoChat = ahora()
  V.ultimaLinea = ahora()
  V.ultimaVia = m.dist
  V.emitidos = V.emitidos + 1
  if m.dist == "WHISPER" then
    V.ultimoSusurro[m.destino] = ahora()
  else
    V.ultimoPublico = ahora()
    V.publicos[#V.publicos + 1] = ahora()
  end
  if ok then V.marcarEnfriamiento(m.idsEnfriar) end
  if not ok then
    V.rechazados = V.rechazados + 1
    A.log("|cffff8800el cliente ha rechazado un mensaje y se descarta: %s|r", tostring(err))
  end
end

-- ======================================================================
-- LO QUE DISPARA UNA PERSONA. Presupuesto aparte, declarado y con su propio
-- enfriamiento. Los dos números congelados siguen gobernando lo automático.
-- ======================================================================

V.colaManual   = {}
V.ultimoManual = -999
V.ultimoSusurroManual = -999
V.proximoManual = 0

-- Reparto completo, en lineas de <=255 caracteres. Aqui SI van nombres: el
-- reparto es precisamente quien pone que. Lo que no se hace nunca en publico es
-- señalar a quien le FALTA algo; eso sigue yendo agregado y por susurro.
function V.lineasReparto()
  local lista, porNombre = A.Escaner.roster()
  local efectivos = A.Asignacion.derivar(lista, porNombre)
  local ids, trozos = A.Estado.lista(), {}
  for i = 1, #ids do
    local e = A.Estado.get(ids[i])
    if e.estado == A.REQ then
      trozos[#trozos + 1] = string.format("%s = %s", e.nombre,
                                          efectivos[e.spellId] or "(sin asignar)")
    end
  end
  local lineas, actual = {}, nil
  for i = 1, #trozos do
    local cand = actual and (actual .. "; " .. trozos[i])
                 or (A.NOMBRE .. ": REPARTO " .. trozos[i])
    if #cand > 250 then
      lineas[#lineas + 1] = actual
      actual = A.NOMBRE .. ": REPARTO " .. trozos[i]
    else
      actual = cand
    end
  end
  if actual then lineas[#lineas + 1] = actual end
  return lineas
end

function V.anunciarReparto()
  -- HABLA UNO SOLO, aunque el boton lo tengan varios. El enfriamiento de raid
  -- no puede funcionar con pulsaciones simultaneas: el aviso de "ya lo he
  -- anunciado yo" viaja por la misma cola pausada y llega tarde. Asi que el
  -- boton SIEMPRE pide el reparto por el cable, y las lineas las emite el
  -- anunciante electo, que es uno y el mismo para los 25. Cuatro oficiales
  -- pulsando a la vez producen un reparto, no cuatro.
  if not A.puedoEditar() then
    A.log("solo el lider y los asistentes pueden anunciar el reparto.")
    return false
  end
  if not V.soyAnunciante() then
    local canal = V.canalPublico()
    if not canal then A.log("no estas en grupo."); return false end
    A.Protocolo.enviar(string.format("%d|R", A.PROTO), canal, nil, "ALERT")
    A.log("reparto pedido; lo anuncia %s.", tostring(V.anunciante))
    return true
  end
  if V.raidEnCombate() then
    A.log("en combate no. Vuelve a intentarlo al salir.")
    return false
  end
  if not V.canalPublico() then A.log("no estas en grupo."); return false end
  local t = ahora()
  if (t - V.ultimoManual) < A.MANUAL_ENFRIA then
    A.log("espera %d s antes de volver a anunciar.",
          math.ceil(A.MANUAL_ENFRIA - (t - V.ultimoManual)))
    return false
  end
  -- Enfriamiento DE RAID: si alguien acaba de anunciar el reparto, el resto de
  -- oficiales no lo repiten. Sin esto, tres oficiales pulsando a la vez triplican
  -- lo que sale al canal aunque cada uno respete su propio cupo.
  if (t - (V.ultimoRepartoOido or -999)) < A.REPARTO_RAID then
    A.log("alguien acaba de anunciar el reparto hace %d s.",
          math.floor(t - V.ultimoRepartoOido))
    return false
  end
  local lineas = V.lineasReparto()
  if #lineas == 0 then A.log("no hay nada asignado que anunciar."); return false end
  if #lineas > A.MANUAL_MAX_LINEAS then
    A.log("el reparto ocupa %d lineas; se mandan las %d primeras.",
          #lineas, A.MANUAL_MAX_LINEAS)
    for i = #lineas, A.MANUAL_MAX_LINEAS + 1, -1 do table.remove(lineas, i) end
  end
  V.ultimoManual = t
  V.ultimoRepartoOido = t
  local canal = V.canalPublico()
  -- Se AÑADE a la cola, no se pisa: si había recordatorios pendientes de
  -- drenar, tirarlos en silencio sería perder avisos que alguien pidió.
  V.colaManual = V.colaManual or {}
  for i = 1, #lineas do
    V.colaManual[#V.colaManual + 1] = { texto = lineas[i], dist = canal }
  end
  -- Y se le dice a todo el mundo que abra su panel de reparto.
  A.Protocolo.enviar(string.format("%d|R", A.PROTO), canal, nil, "ALERT")
  return true
end

-- Lo que ejecuta el anunciante electo cuando alguien pide reparto por el cable.
-- Comparte enfriamiento y cupo con la pulsación directa: no hay puerta trasera.
function V.emitirReparto()
  local t = ahora()
  if V.raidEnCombate() then return false end
  local canal = V.canalPublico()
  if not canal then return false end
  if (t - V.ultimoManual) < A.MANUAL_ENFRIA then return false end
  local lineas = V.lineasReparto()
  if #lineas == 0 then return false end
  for i = #lineas, A.MANUAL_MAX_LINEAS + 1, -1 do table.remove(lineas, i) end
  V.ultimoManual = t
  V.ultimoRepartoOido = t
  V.colaManual = V.colaManual or {}
  for i = 1, #lineas do
    V.colaManual[#V.colaManual + 1] = { texto = lineas[i], dist = canal }
  end
  return true
end

-- Recordatorio dirigido. Son N mensajes en rafaga y SendChatMessage resta del
-- mismo deposito de 800 B/s que el cable: se espacian igual que el reparto.
function V.recordarPorSusurro()
  if not A.puedoEditar() then
    A.log("solo el lider y los asistentes pueden mandar recordatorios.")
    return false
  end
  local t = ahora()
  if (t - V.ultimoSusurroManual) < A.SUSURRO_ENFRIA then
    A.log("espera %d s antes de volver a recordar.",
          math.ceil(A.SUSURRO_ENFRIA - (t - V.ultimoSusurroManual)))
    return false
  end
  local lista, porNombre = A.Escaner.roster()
  local efectivos = A.Asignacion.derivar(lista, porNombre)
  local ids, n = A.Estado.lista(), 0
  V.colaManual = V.colaManual or {}
  for i = 1, #ids do
    local e = A.Estado.get(ids[i])
    local quien = e.estado == A.REQ and efectivos[e.spellId]
    -- TOPE, igual que el reparto. Con 16 buffs requeridos eran 16 susurros a
    -- 1,5 s = 24 s de rafaga con la cola manual bloqueada, y el enfriamiento de
    -- 30 s dejaba volver a pulsar antes de que drenara.
    if n >= A.MANUAL_MAX_LINEAS then break end
    if quien then
      -- UN SOLO FORMATO. Antes convivian "te toca X (reparto de Fulano)" y
      -- "te toca X :: Fulano": el mismo aviso escrito de dos maneras.
      local faltan = {}
      for k = 1, #lista do
        if A.Escaner.estadoBuff(lista[k], e) == false then faltan[#faltan + 1] = lista[k].nombre end
      end
      V.colaManual[#V.colaManual + 1] = {
        texto = string.format("%s: te toca %s :: %s", A.NOMBRE, e.nombre,
                              (#faltan > 0) and table.concat(faltan, ",") or "todos al dia"),
        dist = "WHISPER", destino = quien, spellId = e.spellId,
      }
      n = n + 1
    end
  end
  if n == 0 then A.log("no hay a quien recordarle nada."); return false end
  V.ultimoSusurroManual = t
  A.log("recordatorio a %d asignados, espaciado %.1f s.", n, A.SUSURRO_ESPACIO)
  return true
end

-- Aviso dirigido desde la vista por jugador. El susurro va al ASIGNADO del buff
-- que falta, NO al jugador que aparece en rojo: el que tiene que actuar es quien
-- lo pone. Y va por la misma via manual, con su espaciado y su presupuesto: no
-- se abre una tercera via.
function V.recordarBuffs(faltan)
  if not A.puedoEditar() then
    A.log("solo el lider y los asistentes pueden avisar.")
    return false
  end
  local t = ahora()
  if (t - V.ultimoSusurroManual) < A.SUSURRO_ENFRIA then
    A.log("espera %d s antes de volver a avisar.",
          math.ceil(A.SUSURRO_ENFRIA - (t - V.ultimoSusurroManual)))
    return false
  end
  -- Se agrupa por (asignado, buff) y se acumulan LOS NOMBRES de a quien le
  -- falta: un susurro por buff, con la lista, en vez de uno por jugador.
  local grupos, orden = {}, {}
  for i = 1, #(faltan or {}) do
    local f = faltan[i]
    if f.asignado and f.jugador then
      local k = f.asignado .. "\0" .. f.spellId
      if not grupos[k] then
        grupos[k] = { asignado = f.asignado, spellId = f.spellId,
                      nombre = f.nombre, quienes = {} }
        orden[#orden + 1] = k
      end
      local g = grupos[k]
      g.quienes[#g.quienes + 1] = f.jugador
    end
  end
  local n = 0
  V.colaManual = V.colaManual or {}
  for i = 1, #orden do
    local g = grupos[orden[i]]
    if n < A.MANUAL_MAX_LINEAS then
      V.colaManual[#V.colaManual + 1] = {
        texto = string.format("%s: te toca %s :: %s", A.NOMBRE, g.nombre,
                              table.concat(g.quienes, ",")),
        dist = "WHISPER", destino = g.asignado, spellId = g.spellId,
      }
      n = n + 1
    end
  end
  if n == 0 then A.log("no hay a quien avisar."); return false end
  V.ultimoSusurroManual = t
  A.log("aviso a %d asignado(s), espaciado %.1f s.", n, A.SUSURRO_ESPACIO)
  return true
end

function V.drenarManual()
  if #V.colaManual == 0 then return end
  if A.apagadoPorAPI then V.colaManual = {}; return end
  -- SE VUELVE A COMPROBAR TODO AL EMITIR, no sólo al pulsar. Entre el clic y la
  -- última línea pasan segundos, y en esos segundos puede empezar el pull o
  -- puede uno salirse del grupo: mandar a RAID fuera de raid es un error rojo.
  if V.raidEnCombate() then V.colaManual = {}; return end
  local canal = V.canalPublico()
  if not canal then V.colaManual = {}; return end
  local t = ahora()
  if t < V.proximoManual then return end
  if (t - V.ultimaLinea) < A.SUSURRO_ESPACIO then return end
  local m = V.colaManual[1]
  if m.dist ~= "WHISPER" then m.dist = canal end
  -- Y también se respeta el depósito compartido de bytes: si no cabe, espera.
  m.texto = seguroParaChat(m.texto)
  local coste = #m.texto + #tostring(m.destino or "") + A.MSG_OVERHEAD
  if not A.Protocolo.cabeGastar(coste) then return end
  table.remove(V.colaManual, 1)
  -- Mismo trato que la vía automática: intento contabilizado siempre, llamada
  -- protegida, y lo que el cliente rechace se descarta con registro.
  -- SUSURRARSE A UNO MISMO NO. Si el destinatario soy yo, mensaje local: el
  -- servidor no manda susurros a tu propio nombre y ademas queda ridiculo.
  local ok, err = true, nil
  if m.dist == "WHISPER" and m.destino == A.yo then
    A.log("%s", m.texto)
  else
    ok, err = pcall(SendChatMessage, m.texto, m.dist, nil, m.destino)
  end
  A.Protocolo.apuntarGasto(coste)
  V.ultimaLinea = t
  if m.dist == "WHISPER" and m.destino then V.ultimoSusurro[m.destino] = t end
  V.proximoManual = t + (m.dist == "WHISPER" and A.SUSURRO_ESPACIO or A.MANUAL_ESPACIO)
  if not ok then
    V.rechazados = V.rechazados + 1
    A.log("|cffff8800el cliente ha rechazado un mensaje y se descarta: %s|r", tostring(err))
  end
end

function V.tick()
  V.planificar()
  V.emitir()
  V.drenarManual()
end
