-- Tooltip.lua — leer lo que el juego ya sabe.
--
-- El modo aprendizaje deja de INFERIR y pasa a LEER. El texto del hechizo es un
-- dato del cliente, no una estadística sacada de dos observaciones: se crea un
-- GameTooltip oculto, se le pasa "spell:ID" con SetHyperlink y se leen sus
-- líneas con _G["<nombre>TextLeft"..i]:GetText().
--
-- Se cachea por spellId y se hace UNA vez. Un tooltip no cambia entre pulls.
--
-- Todo va con pcall y con comprobación de existencia: si en este cliente el
-- truco no funcionara, el catálogo se queda sin texto y cae a lo de antes
-- (contar observaciones), pero el addon no revienta ni se calla.

local A = CoABuffs
local T = {}
A.Tooltip = T

T.cache = {}          -- [spellId] = {lineas={...}, texto="...", nombre=, icono=}
T.disponible = nil    -- nil = sin probar, true/false = comprobado
T.NOMBRE_FRAME = "CoABuffsTooltipOculto"

local frame

local function crear()
  if frame then return frame end
  local ok = pcall(function()
    frame = CreateFrame("GameTooltip", T.NOMBRE_FRAME, UIParent, "GameTooltipTemplate")
    frame:SetOwner(UIParent, "ANCHOR_NONE")
    frame:Hide()
  end)
  if not ok then frame = nil end
  return frame
end

-- Lee el tooltip de un hechizo. Devuelve la tabla cacheada o nil.
function T.leer(spellId)
  spellId = tonumber(spellId)
  if not spellId then return nil end
  local c = T.cache[spellId]
  if c ~= nil then return c end
  if T.disponible == false then return nil end

  local f = crear()
  if not f then T.disponible = false; return nil end

  local lineas = {}
  local ok = pcall(function()
    f:ClearLines()
    f:SetOwner(UIParent, "ANCHOR_NONE")
    f:SetHyperlink("spell:" .. spellId)
    for i = 1, 30 do
      local fs = _G[T.NOMBRE_FRAME .. "TextLeft" .. i]
      if not fs then break end
      local txt = fs:GetText()
      if txt and txt ~= "" then lineas[#lineas + 1] = txt end
    end
    f:Hide()
  end)

  -- UN FALLO SUELTO NO APAGA LA LECTURA DE TODA LA SESION. Antes, cualquier
  -- pcall fallido ponia T.disponible=false y cortaba en seco todas las lecturas
  -- futuras: el modo aprendizaje se convertia en el de inferencia sin avisar.
  -- Ahora se apunta el fallo de ESE hechizo y sólo se da por perdido el
  -- mecanismo tras varios seguidos.
  if not ok then
    T.fallos = (T.fallos or 0) + 1
    if T.fallos >= 8 then T.disponible = false end
    T.cache[spellId] = false
    return nil
  end
  T.fallos = 0
  T.disponible = true

  if #lineas == 0 then
    T.cache[spellId] = false
    return nil
  end

  local reg = {
    lineas = lineas,
    nombre = lineas[1],
    -- El cuerpo es todo MENOS el titulo. Con una sola linea no hay cuerpo: antes
    -- se devolvia el titulo como cuerpo y el clasificador acababa juzgando el
    -- nombre del hechizo en vez de su descripcion.
    texto = (#lineas >= 2) and table.concat(lineas, " ", 2) or "",
  }
  T.cache[spellId] = reg
  return reg
end

function T.textoDe(spellId)
  local r = T.leer(spellId)
  return r and r.texto or nil
end

function T.nombreDe(spellId)
  local r = T.leer(spellId)
  return r and r.nombre or nil
end

-- "Does not stack with ..." sale en el propio tooltip, y a veces dice CON QUÉ.
-- Es la única fuente honesta de exclusión que hay; lo demás es adivinar.
function T.noApilaCon(spellId)
  local txt = T.textoDe(spellId)
  if not txt then return nil end
  local m = txt:match("[Dd]oes not stack with ([^%.]+)")
  if m then return (m:gsub("^%s+", ""):gsub("%s+$", ""):lower()) end
  if txt:match("[Dd]oes not stack") then return "similar effects" end
  return nil
end

function T.hayTooltips()
  return T.disponible == true
end
