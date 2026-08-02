-- Colores.lua — color de clase para CoA.
--
-- COMPROBADO EN ESTE CLIENTE, no supuesto: `RAID_CLASS_COLORS` **no trae las
-- clases de CoA**. Ningún fichero del cliente la define ni la extiende; los
-- addons instalados (DBM, Details, TurboPlates) sólo la LEEN. Trae las diez
-- clásicas y nada más. Así que tabla propia.
--
-- Los 21 tokens salen de `AtlasLoot\AtlasLoot.lua`, que lleva la lista de
-- clases de CoA del servidor (tabla `serverClasses.COA`). No me los he
-- inventado y no son los 12 del fixture: hay 9 más.
--
-- Regla dura: una clase desconocida NUNCA se queda sin color ni revienta. Sale
-- en gris neutro. Si mañana Ascension añade una clase, el panel sigue leyéndose.

local A = CoABuffs
local C = {}
A.Colores = C

C.NEUTRO = { r = 0.75, g = 0.75, b = 0.75, hex = "bfbfbf" }

-- Paleta propia. Se han elegido tonos separados entre sí para que 21 nombres en
-- una rejilla se distingan de un vistazo, respetando el color obvio cuando la
-- clase tiene uno evidente (el piromante va rojo, el clérigo solar dorado).
local PALETA = {
  BARBARIAN    = "c79c6e",  WITCHDOCTOR  = "5aa02c",  DEMONHUNTER  = "a330c9",
  WITCHHUNTER  = "8787ed",  STORMBRINGER = "0070de",  FLESHWARDEN  = "c41f3b",
  GUARDIAN     = "f58cba",  MONK         = "00ff96",  SONOFARUGAL  = "6b4423",
  RANGER       = "abd473",  CHRONOMANCER = "40c7eb",  NECROMANCER  = "4d4d8a",
  PYROMANCER   = "ff7d0a",  CULTIST      = "7a5c8f",  STARCALLER   = "9482c9",
  SUNCLERIC    = "ffd100",  TINKER       = "b5a642",  PROPHET      = "2ecfa0",
  REAPER       = "8b0000",  WILDWALKER   = "ff7d0a",  SPIRITMAGE   = "69ccf0",
  HERO         = "ffffff",
}

local cache = {}

local function deHex(hex)
  return {
    r = tonumber(hex:sub(1, 2), 16) / 255,
    g = tonumber(hex:sub(3, 4), 16) / 255,
    b = tonumber(hex:sub(5, 6), 16) / 255,
    hex = hex,
  }
end

-- Se consulta primero lo que traiga el cliente: si algún día Ascension mete las
-- clases de CoA en RAID_CLASS_COLORS, mandan las suyas y esta tabla sobra.
function C.de(token)
  if not token then return C.NEUTRO end
  local c = cache[token]
  if c then return c end
  local nativo = _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[token]
  if nativo and nativo.r then
    c = { r = nativo.r, g = nativo.g, b = nativo.b,
          hex = string.format("%02x%02x%02x", nativo.r * 255, nativo.g * 255, nativo.b * 255) }
  elseif PALETA[token] then
    c = deHex(PALETA[token])
  else
    c = C.NEUTRO
  end
  cache[token] = c
  return c
end

-- Nombre ya coloreado, listo para meter en una etiqueta.
function C.nombre(nombreJugador, token)
  if not nombreJugador then return "" end
  return string.format("|cff%s%s|r", C.de(token).hex, nombreJugador)
end

-- ¿De dónde ha salido el color? Lo usa /cab estado para poder decirlo en
-- pantalla en vez de que haya que adivinarlo.
function C.origen(token)
  if _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[token] then return "cliente" end
  if PALETA[token] then return "tabla propia" end
  return "neutro (clase desconocida)"
end
