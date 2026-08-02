-- Catalogo.lua — modo aprendizaje. LEE el tooltip, no lo adivina.
--
-- Lo que cambió y por qué, con la prueba de juego que lo destapó:
--
--  * CLASE: antes se guardaba la del ÚLTIMO lanzador. En juego, Berserking
--    apareció primero como "lo pone PYROMANCER" y veinte minutos después como
--    "lo pone NECROMANCER": el mismo hechizo, dos clases, según quién lo lanzó.
--    Ahora se guarda el CONJUNTO. Más de una clase distinta = racial u objeto,
--    no habilidad de clase, y esa es una señal que antes se tiraba.
--
--  * LANZADOR NIL (ejemplo real: "No Bonus Experience" 817808) no es de clase.
--
--  * EQUIVALENCIAS: antes se declaraban por "misma clase, mismo alcance y nunca
--    vistos a la vez". Con pocos datos eso es cierto para casi todo: Ancestral
--    Fury salió con DOCE equivalentes, y como se aplicaban solas, bastaba con
--    que estuviera una para dar el buff por puesto y callar. Ahora salen del
--    "Does not stack with..." del propio tooltip, exigen un mínimo de
--    observaciones conjuntas, y NO SE APLICAN sin que las confirme un oficial.
--
--  * ALCANCE: math.max(2, tamRaid*0.6) con una raid de dos declaraba "alcance
--    raid" cualquier aura vista en dos personas. Ahora manda el texto, y el
--    conteo sólo habla si hay muestra suficiente.

local A = CoABuffs
local C = {}
A.Catalogo = C

C.MIN_OBS = 6          -- observaciones antes de decir nada por conteo
C.MIN_JUNTOS = 4       -- veces vistos a la vez antes de proponer exclusión

C.reg = {}
C.juntos = {}
C.sesion = {}          -- spellIds vistos DESDE ESTE ARRANQUE

-- REVISION DEL CATALOGO. Sube SOLO cuando cambia algo que altera lo que el
-- configurador enseñaría. Existe porque `C.propuestas` recorre el catalogo
-- entero y lo ordena, y el panel lo llamaba en CADA repintado: con el historico
-- de varias semanas en SavedVariables eso es un barrido completo dos veces por
-- segundo. Con esto, el panel se guarda el resultado y sólo lo rehace cuando de
-- verdad hay algo nuevo. En una raid en marcha el catalogo se mueve unas pocas
-- veces por pull, no dos veces por segundo.
C.rev = 0
local function tocado() C.rev = C.rev + 1 end
C.tocado = tocado

function C.reset() C.reg, C.juntos, C.sesion = {}, {}, {}; tocado() end

function C.cargar(guardado)
  C.reg = {}
  tocado()
  if type(guardado) ~= "table" then return end
  for id, r in pairs(guardado) do
    if type(r) == "table" and tonumber(id) then
      local clases, n = {}, 0
      if type(r.clases) == "table" then
        for k, v in pairs(r.clases) do if v then clases[k] = true; n = n + 1 end end
      elseif r.clase then
        clases[r.clase] = true; n = 1    -- formato viejo: una sola clase
      end
      -- SE RECUENTA, no se lee del guardado. Leer `r.nClases` de un fichero en
      -- formato viejo dejaba nClases=0 con una clase dentro, y al observar una
      -- SEGUNDA clase el contador subia a 1 con el conjunto ya en 2: esDeClase
      -- decia true y clasesQueLoPonen devolvia dos clases. Es exactamente el
      -- caso Berserking que motivo todo este rediseno, volviendo por la puerta
      -- de atras en cuanto alguien actualice desde la version anterior.
      C.reg[tonumber(id)] = {
        spellId = tonumber(id), nombre = r.nombre or "?",
        clases = clases, nClases = n,
        texto = r.texto,   -- FALTABA: sin esto el panel decia "sin texto de
                           -- tooltip" para siempre en todo lo visto antes del
                           -- ultimo /reload, que es el dato con el que el RL
                           -- decide si rescatar algo del cajon de dudas.
        lanzadores = r.lanzadores or {}, sinLanzador = r.sinLanzador or false,
        vistoEn = r.vistoEn or {}, n = r.n or 0,
        alcance = r.alcance or A.ALC_DUDA,
        -- FALTABA ESTA LÍNEA: el icono no se restauraba, así que sólo tenían
        -- icono los buffs vistos desde el último arranque.
        icono = r.icono,
        cajon = r.cajon, motivo = r.motivo, noApilaCon = r.noApilaCon,
      }
    end
  end
end

function C.volcar() return C.reg end

-- Cuenta el CONJUNTO, no se fia del contador. Si los dos divergen por cualquier
-- via, manda lo que hay de verdad. Definida ANTES de usarse: es local.
local function cuantasClases(r)
  local n = 0
  for _ in pairs(r.clases or {}) do n = n + 1 end
  return n
end
C.cuantasClases = cuantasClases

local function nuevo(spellId)
  return { spellId = spellId, nombre = "?", clases = {}, nClases = 0,
           lanzadores = {}, sinLanzador = false, vistoEn = {}, n = 0,
           alcance = A.ALC_DUDA }
end

-- Se llama por cada aura vista. Barato: el tooltip se lee UNA vez por spellId.
function C.observar(objetivo, spellId, nombreAura, casterUnit, icono)
  local r = C.reg[spellId]
  -- `cambio` se levanta SOLO si de verdad cambia algo. Esta funcion se llama por
  -- cada aura de cada jugador en cada barrido —cientos de veces— y casi todas
  -- las llamadas no aportan nada nuevo: subir la revision en todas dejaria la
  -- cache del panel inservible.
  local cambio = false
  if not r then r = nuevo(spellId); C.reg[spellId] = r; cambio = true end
  if nombreAura and r.nombre ~= nombreAura then r.nombre = nombreAura; cambio = true end
  if icono and r.icono ~= icono then r.icono = icono; cambio = true end
  if not C.sesion[spellId] then C.sesion[spellId] = true; cambio = true end

  if casterUnit then
    local lanzador = UnitName(casterUnit)
    if lanzador then
      r.lanzadores[lanzador] = true
      local _, token = UnitClass(casterUnit)
      if token and not r.clases[token] then
        r.clases[token] = true
        r.nClases = cuantasClases(r)    -- recuento, no incremento
        cambio = true
      end
    end
  elseif not r.sinLanzador then
    -- Aura de objeto o de sistema. No es habilidad de clase.
    r.sinLanzador = true
    cambio = true
  end

  if not r.vistoEn[objetivo.nombre] then
    r.vistoEn[objetivo.nombre] = true
    r.n = (r.n or 0) + 1
    cambio = true
  end

  -- Lo que dice el juego, una sola vez. La condicion mira el TEXTO, no el
  -- cajon: mirando el cajon, un catalogo cargado de disco (que trae cajon pero
  -- no traia texto) no volvia a leerlo nunca.
  if r.texto == nil and A.Tooltip then
    local tt = A.Tooltip.leer(spellId)
    if tt then
      r.nombre = r.nombre ~= "?" and r.nombre or tt.nombre
      r.texto = tt.texto
      r.cajon, r.motivo = A.Clasificador.clasificar(spellId, tt.texto)
      r.noApilaCon = A.Tooltip.noApilaCon(spellId)
      cambio = true
    end
  end
  if cambio then tocado() end
end

function C.observarConjunto(ids)
  for i = 1, #ids do
    for j = i + 1, #ids do
      local a, b = ids[i], ids[j]
      if a > b then a, b = b, a end
      local k = a .. ":" .. b
      C.juntos[k] = (C.juntos[k] or 0) + 1
    end
  end
end

function C.vecesJuntos(a, b)
  if a > b then a, b = b, a end
  return C.juntos[a .. ":" .. b] or 0
end

-- ¿Es esto una habilidad de clase? Sólo si lo ha puesto SIEMPRE la misma clase
-- y nunca ha aparecido sin lanzador.
function C.esDeClase(r)
  return (cuantasClases(r) == 1) and (not r.sinLanzador)
end

function C.claseUnica(r)
  if not C.esDeClase(r) then return nil end
  for token in pairs(r.clases) do return token end
  return nil
end

function C.listaClases(r)
  local out = {}
  for token in pairs(r.clases or {}) do out[#out + 1] = token end
  table.sort(out)
  return out
end

-- El texto manda. El conteo sólo habla con muestra suficiente, y lo dice.
function C.recalcular(tamRaid)
  tamRaid = math.max(1, tamRaid or 1)
  local antes = {}
  for id, r in pairs(C.reg) do antes[id] = r.alcance end
  for _, r in pairs(C.reg) do
    local n = 0
    for _ in pairs(r.vistoEn) do n = n + 1 end
    r.n = n
    if r.cajon == A.Clasificador.GRUPO then
      r.alcance = A.ALC_RAID
    elseif r.cajon == A.Clasificador.FUERA then
      r.alcance = A.ALC_PERSONAL
    elseif n < C.MIN_OBS or tamRaid < 5 then
      -- Muestra pequeña: callarse. Con la raid de dos que había, cualquier aura
      -- vista en dos personas se declaraba "alcance raid".
      r.alcance = A.ALC_DUDA
    elseif n >= math.floor(tamRaid * 0.6) then
      r.alcance = A.ALC_RAID
    elseif n >= 2 then
      r.alcance = A.ALC_GRUPO
    else
      r.alcance = A.ALC_PERSONAL
    end
  end
  for id, r in pairs(C.reg) do
    if antes[id] ~= r.alcance then tocado(); return end
  end
end

-- ---------------------------------------------------- exclusiones ----------
-- PROPUESTAS, nunca aplicadas. Salen del "Does not stack with..." del tooltip,
-- que es lo único que dice el juego, y exigen haber visto los dos hechizos a la
-- vez varias veces antes de sugerir nada por conteo.
function C.exclusionesPropuestas(spellId)
  local r = C.reg[spellId]
  if not r then return {} end
  local out = {}
  for id, o in pairs(C.reg) do
    if id ~= spellId then
      local mismo = r.noApilaCon and o.noApilaCon and (r.noApilaCon == o.noApilaCon)
      local nombreIgual = (o.nombre == r.nombre) and o.nombre ~= "?"
      if mismo or nombreIgual then
        out[#out + 1] = { spellId = id, nombre = o.nombre,
                          motivo = nombreIgual and "mismo nombre visible"
                                   or ("los dos dicen: no apila con " .. tostring(r.noApilaCon)) }
      end
    end
  end
  table.sort(out, function(a, b) return a.spellId < b.spellId end)
  return out
end

-- ---------------------------------------------------- propuestas -----------
function C.propuestas(cajon, soloSesion)
  local out = {}
  for id, r in pairs(C.reg) do
    local c = r.cajon or A.Clasificador.DUDA
    if (cajon == nil or c == cajon) and (not soloSesion or C.sesion[id]) then
      out[#out + 1] = {
        spellId = id, nombre = r.nombre, alcance = r.alcance,
        cajon = c, motivo = r.motivo or "sin texto de tooltip",
        clases = C.listaClases(r), nClases = r.nClases or 0,
        deClase = C.esDeClase(r), sinLanzador = r.sinLanzador,
        vistoEn = r.n, icono = r.icono, enSesion = C.sesion[id] and true or false,
        -- NO se calculan aqui las exclusiones. Estaba `exclusiones =
        -- C.exclusionesPropuestas(id)`, que recorre el catalogo ENTERO por cada
        -- entrada del catalogo: cuadratico, y encima el campo no lo leia nadie
        -- (el panel vuelve a pedir las exclusiones por su cuenta, y solo de lo
        -- que ya esta en la lista cerrada, que son cuatro).
      }
    end
  end
  table.sort(out, function(a, b)
    if a.nombre ~= b.nombre then return tostring(a.nombre) < tostring(b.nombre) end
    return a.spellId < b.spellId
  end)
  return out
end

-- Quién puede poner esto. Si el hechizo lo han lanzado clases distintas, no es
-- habilidad de clase y no se ofrece a nadie por clase: lo pone quien lo tenga.
function C.clasesQueLoPonen(spellId, equiv)
  local clases = {}
  local ids = { spellId }
  for i = 1, #(equiv or {}) do ids[#ids + 1] = equiv[i] end
  for i = 1, #ids do
    local r = C.reg[ids[i]]
    if r and C.esDeClase(r) then
      for token in pairs(r.clases) do clases[token] = true end
    end
  end
  return clases
end
