-- Escaner.lua — roster y auras. Aquí se decide qué se SABE y qué no.
--
-- La regla número uno del listón es cero falsos positivos, y casi todos los
-- falsos positivos de un addon de buffs nacen del mismo error: confundir "no
-- tengo datos" con "no lo tiene". Por eso estadoBuff devuelve TRES cosas:
--   true  -> lo tiene, visto
--   false -> no lo tiene, y se le ve lo suficiente para afirmarlo
--   nil   -> SIN DATOS. Ni se anuncia, ni se cuenta, ni se adivina.
-- Un jugador da nil si está fuera de la raid, desconectado, muerto, fuera del
-- rango de visibilidad, o si su ficha no se ha refrescado desde que volvió.

local A = CoABuffs
local S = {}
A.Escaner = S

S.ficha = {}          -- nombre -> { [spellId]=true } | nil si no hay datos
S.vistoEn = {}        -- nombre -> GetTime() del último refresco

-- Unidad canónica de un índice de raid. Se usan tokens, nunca nombres: los
-- tokens funcionan siempre y los nombres sólo a veces.
function S.unidadDe(idx)
  if GetNumRaidMembers() > 0 then return "raid" .. idx end
  if idx == 1 then return "player" end
  return "party" .. (idx - 1)
end

function S.roster()
  local lista, porNombre = {}, {}
  local n = GetNumRaidMembers()
  if n == 0 then
    -- FUERA DE RAID. Antes esto devolvía SÓLO al jugador, así que en grupo de 5
    -- el addon no veía a nadie más: no escaneaba, no contaba y no avisaba. El
    -- grupo se recorre con GetNumPartyMembers y las unidades party1..party4.
    -- En party no hay rangos: manda quien lleva el addon y edita, y los demás
    -- van a rango 0 para que la regla de autoridad siga siendo la misma.
    local np = GetNumPartyMembers()
    local yo = UnitName("player")
    if yo then
      local _, token = UnitClass("player")
      local e = { nombre = yo, rank = 2, subgrupo = 1, token = token, idx = 1,
                  unidad = "player", online = true, muerto = false,
                  guid = UnitGUID("player") }
      lista[1] = e; porNombre[yo] = e
    end
    for i = 1, np do
      local unidad = "party" .. i
      local nombre = UnitName(unidad)
      if nombre then
        local _, token = UnitClass(unidad)
        local e = {
          nombre = nombre, rank = 0, subgrupo = 1, token = token,
          idx = #lista + 1, unidad = unidad,
          online = UnitIsConnected(unidad) and true or false,
          muerto = UnitIsDeadOrGhost(unidad) and true or false,
          guid = UnitGUID(unidad),
        }
        lista[#lista + 1] = e
        porNombre[nombre] = e
      end
    end
    return lista, porNombre
  end
  for i = 1, n do
    local nombre, rank, subgrupo, _, _, token, _, online, muerto = GetRaidRosterInfo(i)
    if nombre then
      local unidad = S.unidadDe(i)
      local e = {
        nombre = nombre, rank = rank or 0, subgrupo = subgrupo or 1,
        token = token, idx = i, unidad = unidad,
        online = online and true or false,
        muerto = muerto and true or false,
        guid = UnitGUID and UnitGUID(unidad) or nil,
      }
      lista[#lista + 1] = e
      porNombre[nombre] = e
    end
  end
  return lista, porNombre
end

-- Presente = en la raid, conectado y vivo. NO implica que se le vean las auras.
function S.presente(e)
  return e ~= nil and e.online and not e.muerto
end

-- Observable = presente Y dentro del rango de visibilidad. Única condición bajo
-- la que este addon se permite afirmar algo de alguien.
function S.observable(e)
  if not S.presente(e) then return false end
  return UnitIsVisible(e.unidad) and true or false
end

-- Relee las auras de una unidad y rehace su ficha. Es lo que llama UNIT_AURA.
function S.refrescar(e)
  if not e then return end
  if not S.observable(e) then
    S.ficha[e.nombre] = nil
    S.vistoEn[e.nombre] = nil
    return
  end
  local f, vistos = {}, {}
  local i = 1
  while i <= 40 do
    -- El icono viene en la posición 3 y hasta ahora se tiraba. No hay que
    -- consultar nada para tenerlo: llega en la misma llamada que el nombre y el
    -- spellId. Es lo que pinta el panel.
    local nombre, _, icono, _, _, _, _, caster, _, _, spellId = UnitBuff(e.unidad, i)
    if not nombre then break end
    if spellId then
      f[spellId] = true
      vistos[#vistos + 1] = spellId
      A.Catalogo.observar(e, spellId, nombre, caster, icono)
    end
    i = i + 1
  end
  A.Catalogo.observarConjunto(vistos)
  S.ficha[e.nombre] = f
  S.vistoEn[e.nombre] = GetTime()
end

function S.barrer()
  local lista = S.roster()
  for i = 1, #lista do S.refrescar(lista[i]) end
  A.Catalogo.recalcular(#lista)
end

-- true / false / nil. Un buff cuenta como presente si está cualquiera de sus
-- spellIds equivalentes: incluir de más sólo puede hacernos callar, e incluir
-- de menos es lo que produce falsos positivos. La asimetría es deliberada.
--
-- La ficha NO basta como permiso para afirmar. Una ficha se hace cuando se
-- refresca, y entre un refresco y el siguiente el jugador puede haberse muerto,
-- desconectado o alejado: morir no dispara UNIT_AURA. Por eso se vuelve a mirar
-- el roster, que sí está siempre fresco, antes de responder nada.
function S.estadoBuff(entradaRoster, entrada)
  if type(entradaRoster) == "string" then
    local _, porNombre = S.roster()
    entradaRoster = porNombre[entradaRoster]
  end
  if not entradaRoster then return nil end
  if not S.observable(entradaRoster) then return nil end
  local f = S.ficha[entradaRoster.nombre]
  if f == nil then return nil end
  if f[entrada.spellId] then return true end
  local eq = entrada.equiv
  if eq then
    for i = 1, #eq do if f[eq[i]] then return true end end
  end
  return false
end

-- Qué alcanza a ver este cliente. Es lo que se declara en modo degradado:
-- no "creo que todo está bien", sino "de estos N no tengo ni idea".
function S.cobertura()
  local lista = S.roster()
  local vistos, sinDatos, nombresSinDatos = 0, 0, {}
  for i = 1, #lista do
    local e = lista[i]
    if S.ficha[e.nombre] ~= nil and S.observable(e) then
      vistos = vistos + 1
    else
      sinDatos = sinDatos + 1
      nombresSinDatos[#nombresSinDatos + 1] = e.nombre
    end
  end
  return vistos, sinDatos, nombresSinDatos, #lista
end
