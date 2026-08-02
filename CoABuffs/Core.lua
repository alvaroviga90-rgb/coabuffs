-- Core.lua — arranque, eventos y pegamento.
--
-- Modelo por eventos con barrido de respaldo, decidido y justificado en la
-- fase 1: UNIT_AURA es el mecanismo principal, y cada 30 s hay un barrido
-- completo porque UNIT_AURA no llega de quien está fuera de rango, no cubre a
-- quien acaba de entrar y se pierde lo que pasa mientras el cliente zonea.

local A = CoABuffs

A.yo         = nil
A.arrancado  = 0
A.enGrupoDesde = 0
A.enGrupo    = false
A.apagadoPorAPI = false
A.iniciado   = false
A.apiFaltante= {}
A.debugOn    = false

function A.log(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  if not ok then s = tostring(fmt) end
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff" .. A.NOMBRE .. "|r: " .. s)
  else
    print(A.NOMBRE .. ": " .. s)
  end
end

function A.log_debug(fmt, ...)
  if A.debugOn then A.log(fmt, ...) end
end

-- Auditoría de la API en tiempo de ejecución. Si algo de lo que este addon usa
-- no existe en el cliente, se dice en voz alta al arrancar en vez de reventar
-- a mitad de un pull. Nada de C_*, IsInRaid ni RegisterAddonMessagePrefix.
-- Ojo: "invocable" no es lo mismo que "function". LibStub es una TABLA con
-- __call, y comprobar type(x)=="function" la daba por ausente y apagaba el
-- addon entero. Se comprueba que se pueda llamar, que es lo que importa.
local function invocable(v)
  if type(v) == "function" then return true end
  if type(v) == "table" then
    local mt = getmetatable(v)
    return mt ~= nil and mt.__call ~= nil
  end
  return false
end

function A.auditarAPI()
  A.apiFaltante = {}
  for i = 1, #A.API_USADA do
    local n = A.API_USADA[i]
    if not invocable(_G[n]) then A.apiFaltante[#A.apiFaltante + 1] = n end
  end
  return A.apiFaltante
end

function A.miRango()
  local _, porNombre = A.Escaner.roster()
  local e = porNombre[A.yo]
  return e and e.rank or 0
end

function A.puedoEditar()
  return A.miRango() >= 1
end

-- Único punto de edición de la lista. Comprueba el rango SIEMPRE, venga de
-- donde venga: del panel, de una macro o de una consola.
function A.editar(spellId, campos)
  if not A.puedoEditar() then
    A.log("solo el lider y los asistentes pueden tocar la lista.")
    return false
  end
  spellId = tonumber(spellId)
  if not spellId then return false end
  -- No se edita a ciegas. Un cliente que acaba de entrar y todavía no ha oído a
  -- nadie no sabe por qué revisión va la raid: su edición nacería por debajo,
  -- la rechazarían los 25 y se le desharía sola veinte segundos después, sin
  -- que nadie le dijera nada. Antes que eso, se le pide que espere.
  local enGrupo = (GetNumRaidMembers() > 0) or (GetNumPartyMembers() > 0)
  if enGrupo and A.Protocolo.desincronizado then
    A.log("|cffff8800vas por detras de la raid: espera a sincronizar antes de tocar la lista. " ..
          "Tu cambio se perderia.|r")
    return false
  end
  if enGrupo and not A.Estado.sincronizado
     and (GetTime() - math.max(A.arrancado, A.enGrupoDesde or 0)) < 20 then
    A.log("todavia sincronizando con la raid; espera unos segundos y vuelve a intentarlo.")
    return false
  end
  if campos.estado and not A.ESTADOS_VALIDOS[campos.estado] then return false end
  if campos.asignado and campos.asignado ~= false then
    local _, porNombre = A.Escaner.roster()
    local e = porNombre[campos.asignado]
    campos.guid = e and e.guid or nil
  end
  -- NINGUNA EQUIVALENCIA SE APLICA SOLA. Antes se rellenaban aquí desde el
  -- catálogo: Ancestral Fury entró con doce equivalentes inventados por conteo,
  -- y basta que esté uno de los doce para que el addon dé el buff por puesto y
  -- calle. Ahora se proponen en el panel y las confirma un oficial, una a una.
  if campos.nombre == nil and A.Catalogo.reg[spellId] then
    campos.nombre = A.Catalogo.reg[spellId].nombre
  end
  -- Recorte duro: una entrada que no cabe en un mensaje no se replica nunca.
  if campos.equiv and #campos.equiv > A.MAX_EQUIV then
    local rec = {}
    for i = 1, A.MAX_EQUIV do rec[i] = campos.equiv[i] end
    A.log("aviso: %d equivalencias propuestas para %d, se guardan las %d primeras.",
          #campos.equiv, spellId, A.MAX_EQUIV)
    campos.equiv = rec
  end
  if campos.nombre and #campos.nombre > 40 then
    campos.nombre = campos.nombre:sub(1, 40)
  end
  local e = A.Estado.editar(spellId, campos, A.yo)
  A.Protocolo.empujarEntradas({ e })
  A.alCambiarEstado()
  return true
end

-- REFRESCO DIFERIDO. Refrescar en el acto significaría llamar a
-- ReleaseChildren() sobre el mismo widget de AceGUI que está ejecutando su
-- propio callback: se devuelve al pool mientras la librería sigue trabajando
-- con él. Se marca y se repinta en el siguiente tick, ya fuera del callback.
A.refrescoPendiente = false

-- Lo que abre el boton del minimapa. Lo VEN todos; lo que abre depende del
-- rango, y la decision vive aqui, no en el boton: el boton no sabe de rangos.
function A.abrirVistaPropia(porJugador)
  local pest = porJugador and "jugadores" or "buffs"
  A.Reparto.abrir(pest)
  A.Reparto.pestana = pest
  A.refrescoPendiente = true
end

-- Confirmación explícita de una equivalencia por un oficial. Es el único camino
-- por el que un spellId entra en el conjunto que da un buff por puesto.
function A.confirmarEquivalencia(spellId, otro)
  if not A.puedoEditar() then
    A.log("solo el lider y los asistentes pueden confirmar equivalencias.")
    return false
  end
  local e = A.Estado.get(spellId)
  if not e then return false end
  local eq = {}
  for i = 1, #(e.equiv or {}) do
    if e.equiv[i] == otro then return true end
    eq[#eq + 1] = e.equiv[i]
  end
  eq[#eq + 1] = otro
  return A.editar(spellId, { equiv = eq })
end

function A.alCambiarEstado()
  A.refrescoPendiente = true
end

-- Icono de un buff, con caida elegante. Un spellId anadido desde un perfil o
-- llegado por el cable puede no estar en el catalogo de ESTE cliente todavia, y
-- entonces la fila salia sin icono y parecia rota.
function A.iconoDe(spellId)
  local r = A.Catalogo.reg[spellId]
  return (r and r.icono) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- UN RELOJ POR VISTA, no uno global. Con las dos ventanas abiertas, un reloj
-- compartido hacia que la que repinta bien le empujara el reloj a la otra: la
-- atascada nunca llegaba a vencer su plazo y la red de seguridad no saltaba
-- nunca para ella. Cada vista tiene el suyo y se estrangula sola.
local reloj = {}
local function relojDe(clave)
  local r = reloj[clave]
  if not r then r = { prox = 0, ultimo = 0 }; reloj[clave] = r end
  return r
end

-- TODO repintado pasa por aqui, venga de donde venga: del estrangulador o de
-- abrir la ventana. Dos cosas:
--   * cuenta (diagnostico, sale por /cab estado y lo contrasta el arnes con su
--     propia medida, que es independiente);
--   * REARMA EL RELOJ DE ESA VISTA. Si no lo hiciera, abrir el panel pintaria
--     una vez y el estrangulador pintaria otra en el mismo fotograma: dos
--     repintados en el mismo instante y el techo roto por la puerta de atras. El
--     techo tiene que valer para todos los caminos, no solo para el periodico.
A.medidaRepintado = {}

function A.anotarRepintado(clave)
  local t = GetTime()
  local r = relojDe(clave)
  r.prox, r.ultimo = t + A.REFRESCO_PANEL, t
  local m = A.medidaRepintado[clave]
  if not m then m = { n = 0, pico = 0, marcas = {} }; A.medidaRepintado[clave] = m end
  m.n = m.n + 1
  local q = m.marcas
  q[#q + 1] = t
  while #q > 0 and q[1] <= t - 1 do table.remove(q, 1) end
  if #q > m.pico then m.pico = #q end
  return m
end

function A.vistaAbierta()
  if A.Panel and A.Panel.ventana then return true end
  if A.Reparto and A.Reparto.ventana then return true end
  return false
end

-- Las dos vistas, en orden fijo. Se recorre en varios sitios y duplicar la
-- lista es la forma segura de que un dia una de ellas se quede fuera.
local function vistas()
  return { { "panel", A.Panel }, { "reparto", A.Reparto } }
end

-- EL ESTRANGULADOR DE REPINTADO.
--
-- La bandera dice QUE HAY QUE REPINTAR. No autoriza a saltarse el intervalo, y
-- ese era el bug: `UNIT_AURA` la ponia en cada evento y en una raid de 25 eso
-- son decenas de repintados por segundo. El cliente iba a tirones con el panel
-- abierto y fluido al cerrarlo. Un evento no puede forzar un repintado
-- inmediato: marca, y el reloj decide cuando.
--
-- La bandera NO se pierde si toca esperar: se queda puesta y el repintado sale
-- en cuanto vence el intervalo. Y no se borra hasta que han repintado TODAS las
-- vistas abiertas: si una esta estrangulada y la otra no, la bandera sigue
-- puesta por la que falta. Peor latencia de pintado = A.REFRESCO_PANEL (0,5 s),
-- la cuarta parte del plazo congelado de 2 s.
local ultimoAvisoPintado = 0

function A.repintarSiToca()
  if not A.vistaAbierta() then A.refrescoPendiente = false; return end
  if not A.refrescoPendiente then return end
  local t = GetTime()
  local queda = false
  local v = vistas()
  for i = 1, #v do
    local clave, mod = v[i][1], v[i][2]
    if mod and mod.ventana and mod.refrescar then
      if t < relojDe(clave).prox then
        queda = true
      else
        -- PROTEGIDO. Un error dentro de una funcion de pintado, sin esto, se
        -- convierte en un error de Lua por segundo mientras la ventana este
        -- abierta: la red de seguridad vuelve a levantar la bandera y se
        -- reintenta para siempre. Se avisa como mucho una vez cada 10 s.
        local ok, err = pcall(mod.refrescar)
        if not ok then
          if (t - ultimoAvisoPintado) > 10 then
            ultimoAvisoPintado = t
            A.log("|cffff0000error al repintar %s: %s|r", clave, tostring(err))
          end
          -- Se rearma igual: si no, se reintentaria en cada fotograma.
          local r = relojDe(clave)
          r.prox, r.ultimo = t + A.REFRESCO_PANEL, t
        end
      end
    end
  end
  if not queda then A.refrescoPendiente = false end
end

-- Red de seguridad, en el tick de trabajo. Si una vista abierta lleva
-- A.REFRESCO_SEGURIDAD sin repintar, se levanta la bandera. Solo la levanta: el
-- repintado sigue pasando por el techo.
local function repintadoDeSeguridad(t)
  local v = vistas()
  for i = 1, #v do
    local clave, mod = v[i][1], v[i][2]
    if mod and mod.ventana and (t - relojDe(clave).ultimo) >= A.REFRESCO_SEGURIDAD then
      A.refrescoPendiente = true
    end
  end
end

-- Lo que el arnés lee para comprobar la convergencia. Datos en crudo, no un
-- veredicto: quien juzga es el arnés, no el addon.
function A.volcarEstado()
  local out = {}
  local ids = A.Estado.lista()
  for i = 1, #ids do
    local e = A.Estado.get(ids[i])
    out[#out + 1] = { spellId = e.spellId, estado = e.estado, asignado = e.asignado,
                      rev = e.rev, autor = e.autor }
  end
  return out, A.Estado.digest()
end

-- ------------------------------------------------------------- eventos -----

local f = CreateFrame("Frame", "CoABuffsFrame")
A.frame = f
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("UNIT_AURA")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")

local proxTrabajo, proxBarrido, proxLatido = 0, 0, 0

function A.iniciar()
  if A.iniciado then return end
  A.iniciado = true
  A.yo = UnitName("player")
  A.arrancado = GetTime()

  CoABuffsDB = CoABuffsDB or {}
  CoABuffsDB.catalogo = CoABuffsDB.catalogo or {}
  A.Catalogo.cargar(CoABuffsDB.catalogo)
  local n = A.Estado.cargarCrudo(CoABuffsDB.lista)
  A.Declaraciones.cargarCrudo(CoABuffsDB.declaraciones)
  -- Una declaración recuperada del disco hay que VOLVER A DECIRLA. Nadie puede
  -- reemitirla por ti, así que tras un /reload o un relog la raid no sabe nada
  -- y te vuelve a asignar lo que dijiste que no tienes. Se arma el reloj de
  -- repetición si hay algo propio guardado.
  if A.Declaraciones.datos[A.yo] and next(A.Declaraciones.datos[A.yo]) then
    A.Protocolo.proxDecl = GetTime() + A.ASENTAR_LOGIN
  end
  if n > 0 then A.log("lista cerrada recuperada: %d entradas.", n) end
  local aviso = A.Perfiles.revisarCuenta()
  if aviso then A.log("|cffff8800%s|r", aviso) end

  -- EL NUMERO 3 CONGELADO TIENE QUE GOBERNAR, no ser un comentario. El peor
  -- caso de pintado es un intervalo de repintado mas una espera de la red de
  -- seguridad; si esa suma no cabe en A.REFRESCO_PLAZO, la vista puede tardar
  -- mas de lo congelado en dejar de mentir. Se dice al arrancar, no se descubre
  -- en una raid.
  local peorPintado = A.REFRESCO_PANEL + A.REFRESCO_SEGURIDAD
  if peorPintado > A.REFRESCO_PLAZO then
    A.log("|cffff0000el ritmo de repintado (%.2f s de intervalo + %.2f s de red) no cabe " ..
          "en el plazo congelado de %.0f s: la vista puede tardar mas de lo debido.|r",
          A.REFRESCO_PANEL, A.REFRESCO_SEGURIDAD, A.REFRESCO_PLAZO)
  end

  -- La auditoría de API NO es cosmética: si falta algo, el addon se calla del
  -- todo. Un addon que sigue hablando con la API rota es peor que uno mudo.
  local faltan = A.auditarAPI()
  if #faltan > 0 then
    A.apagadoPorAPI = true
    A.log("|cffff0000faltan funciones de API en este cliente: %s. " ..
          "CoABuffs se queda en silencio para no reventar en mitad de una raid.|r",
          table.concat(faltan, ", "))
  end

  A.Protocolo:RegisterComm(A.PREFIJO)
  if A.Minimapa then A.Minimapa.crear() end
  A.Escaner.barrer()
  proxLatido = GetTime() + 3
  A.log("v%s cargado. /coabuffs para el panel (solo lider y asistentes).", A.VERSION)
end

f:SetScript("OnEvent", function(self, evento, arg1)
  if evento == "PLAYER_LOGIN" then
    A.iniciar()

  elseif evento == "PLAYER_ENTERING_WORLD" then
    if not A.iniciado then A.iniciar() end
    -- Zonear vacía el depósito de ChatThrottleLib y lo estrangula 5 s. Meter
    -- aquí una sincronización sólo llena la cola: se espera.
    A.Escaner.barrer()
    A.refrescoPendiente = true
    proxLatido  = GetTime() + A.ASENTAR_ZONING
    proxBarrido = GetTime() + A.BARRIDO_CADA
    A.Avisos.ultimoChat = GetTime() - A.ANUNCIO_CADA + A.ASENTAR_ZONING

  elseif evento == "UNIT_AURA" then
    if not A.iniciado or not arg1 then return end
    local nombre = UnitName(arg1)
    if not nombre then return end
    local _, porNombre = A.Escaner.roster()
    A.Escaner.refrescar(porNombre[nombre])
    -- Una vista abierta tiene que enterarse de esto: es el evento que dice que
    -- un buff se ha caido.
    A.refrescoPendiente = true

  elseif evento == "RAID_ROSTER_UPDATE" or evento == "PARTY_MEMBERS_CHANGED" then
    if A.iniciado then
      -- Entrar en un grupo rearma el reloj del relevo de anunciante. Si no, un
      -- cliente con una hora de sesión entra en raid con el plazo ya vencido y
      -- se cree anunciante antes de haber oído a nadie.
      local enGrupo = (GetNumRaidMembers() > 0) or (GetNumPartyMembers() > 0)
      if enGrupo and not A.enGrupo then A.enGrupoDesde = GetTime() end
      A.enGrupo = enGrupo
      A.Escaner.barrer()
      A.refrescoPendiente = true
    end

  elseif evento == "PLAYER_REGEN_DISABLED" then
    A.Avisos.enCombate = true
    A.Avisos.cola = {}

  elseif evento == "PLAYER_REGEN_ENABLED" then
    A.Avisos.enCombate = false
  end
end)

-- Firma barata del conjunto de OBSERVABLES. Morir, desconectarse o salir de
-- rango no dispara ningun evento, asi que sin esto una vista abierta no se
-- entera hasta el siguiente repintado periodico.
local firmaObs = ""
local function vigilarObservables()
  if not (A.Panel and A.Panel.ventana) and not (A.Reparto and A.Reparto.ventana) then return end
  local lista = A.Escaner.roster()
  local partes = {}
  for i = 1, #lista do
    partes[#partes + 1] = A.Escaner.observable(lista[i]) and "1" or "0"
  end
  local f = table.concat(partes)
  if f ~= firmaObs then
    firmaObs = f
    A.refrescoPendiente = true
  end
end

f:SetScript("OnUpdate", function(self, elapsed)
  if not A.iniciado then return end
  local t = GetTime()
  -- El repintado se mira en cada fotograma pero SALE como mucho una vez cada
  -- A.REFRESCO_PANEL. Mirarlo aqui es lo que hace que, cuando vence el
  -- intervalo, el repintado pendiente salga en el fotograma siguiente y no al
  -- ritmo del tick de trabajo.
  A.repintarSiToca()
  if t < proxTrabajo then return end
  proxTrabajo = t + A.ESCANEO_CADA
  vigilarObservables()
  repintadoDeSeguridad(t)
  -- Al abrir una vista, el barrido puede estar programado a 30 s vista. Se
  -- adelanta: si no, el ritmo rapido no empieza hasta media hora despues, que es
  -- justo cuando no sirve de nada.
  if A.vistaAbierta() and proxBarrido > t + A.BARRIDO_VISTA then
    proxBarrido = t + A.BARRIDO_VISTA
  end

  if t >= proxBarrido then
    -- Con una vista abierta el barrido va a A.BARRIDO_VISTA: es el unico modo
    -- de que la pantalla no dependa por completo de que UNIT_AURA llegue.
    -- Cerrado todo, vuelve a los 30 s y no se paga sondeo.
    proxBarrido = t + (A.vistaAbierta() and A.BARRIDO_VISTA or A.BARRIDO_CADA)
    A.Escaner.barrer()
    -- El barrido rehace TODAS las fichas: lo que se pinta puede haber cambiado
    -- sin que haya llegado un solo evento. Marca, no repinta.
    A.refrescoPendiente = true
    if CoABuffsDB then
      CoABuffsDB.catalogo = A.Catalogo.volcar()
      CoABuffsDB.lista = A.Estado.volcarCrudo()
      CoABuffsDB.declaraciones = A.Declaraciones.volcarCrudo()
    end
  end

  if t >= proxLatido then
    proxLatido = t + A.HEARTBEAT_CADA
    A.Protocolo.latido()
  end

  A.Protocolo.tick()
  A.Avisos.tick()
end)

-- -------------------------------------------------------------- slash ------

SLASH_COABUFFS1 = "/coabuffs"
SLASH_COABUFFS2 = "/cab"
SlashCmdList = SlashCmdList or {}
SlashCmdList["COABUFFS"] = function(msg)
  msg = tostring(msg or ""):lower()
  if msg == "debug" then
    A.debugOn = not A.debugOn
    A.log("debug %s", A.debugOn and "on" or "off")
  elseif msg == "estado" then
    local vistos, sinDatos, _, total = A.Escaner.cobertura()
    A.log("rev %d digest %s | veo %d de %d, sin datos %d | con addon: %d | anunciante: %s",
      A.Estado.revMax(), A.Estado.digest(), vistos, total, sinDatos,
      A.Protocolo.companeros() + 1, tostring(A.Avisos.anunciante))
    for clave, m in pairs(A.medidaRepintado) do
      A.log("repintados de %s: %d en total, pico %d en 1 s (techo %d/s)",
            clave, m.n, m.pico, A.TECHO_REPINTADO)
    end
  elseif msg == "reparto" then
    A.Reparto.alternar()
  elseif msg == "jugadores" then
    A.abrirVistaPropia(true)
  elseif msg == "minimapa" then
    A.Minimapa.alternarVisible()
  elseif msg:match("^perfil ") then
    local n = msg:match("^perfil (.+)$")
    A.Perfiles.cargar(n)
  elseif msg:match("^guardar ") then
    A.Perfiles.guardar(msg:match("^guardar (.+)$"))
  elseif msg == "perfiles" then
    local l = A.Perfiles.lista()
    A.log("perfiles: %s", (#l > 0) and table.concat(l, ", ") or "(ninguno)")
    if A.Perfiles.avisoCuenta then A.log("|cffff8800%s|r", A.Perfiles.avisoCuenta) end
  elseif msg == "cuenta" then
    local s = A.Perfiles.sellar()
    A.log("sello de esta base de datos: %s · personajes vistos: %d · perfiles: %d",
          tostring(s.id), s.nPersonajes or 0, A.Perfiles.nPerfiles())
  else
    -- Cada uno abre lo suyo: el que manda, el configurador; el resto, su panel
    -- de reparto. No es la misma ventana con permisos.
    if A.puedoEditar() then A.Panel.alternar() else A.Reparto.alternar() end
  end
end
