-- Declaraciones.lua — "no tengo este hechizo".
--
-- POR QUÉ EXISTE: en CoA dos jugadores de la misma clase NO llevan las mismas
-- habilidades. La reasignación automática busca "otro de la misma clase", y sin
-- esto puede asignarle a alguien algo que no puede lanzar. El jugador es el
-- único que sabe lo que tiene.
--
-- AUTORIDAD, y es distinta de la de la lista cerrada: esto NO necesita rango,
-- porque es una declaración de uno sobre SÍ MISMO. Pero por eso mismo sólo se
-- acepta sobre el propio remitente. El sujeto viaja en el mensaje y se compara
-- con quien lo manda: si no coinciden, se tira. Un rango 0 puede declarar lo
-- suyo y no puede tocar lo de nadie más.
--
-- Se replica con la misma mecánica que la lista: (rev, autor) por clave, orden
-- total, converge sin negociar. La clave es el par (jugador, spellId).

local A = CoABuffs
local D = {}
A.Declaraciones = D

D.datos = {}      -- [jugador] = { [spellId] = {sin=true/false, rev=n} }
D.revVista = 0

local function ficha(jugador)
  D.datos[jugador] = D.datos[jugador] or {}
  return D.datos[jugador]
end

function D.reset() D.datos = {}; D.revVista = 0 end

-- ¿Ha declarado <jugador> que NO tiene <spellId>?
function D.noLoTiene(jugador, spellId)
  local f = D.datos[jugador]
  local e = f and f[spellId]
  return (e ~= nil) and e.sin == true
end

-- Todo lo que ha declarado alguien, para pintarlo en el panel.
function D.deJugador(jugador)
  local out = {}
  local f = D.datos[jugador]
  if not f then return out end
  for spellId, e in pairs(f) do
    if e.sin then out[#out + 1] = spellId end
  end
  table.sort(out)
  return out
end

-- Quién ha declarado que no tiene <spellId>. Lo usa el configurador para que el
-- RL se entere de que a quien asignó ya no puede: en su panel, no en silencio.
function D.quienesNoLoTienen(spellId)
  local out = {}
  for jugador, f in pairs(D.datos) do
    if f[spellId] and f[spellId].sin then out[#out + 1] = jugador end
  end
  table.sort(out)
  return out
end

-- Declaración propia. Sólo se llama sobre uno mismo, desde el panel.
function D.declarar(spellId, sin)
  local f = ficha(A.yo)
  local prev = f[spellId]
  local rev = math.max((prev and prev.rev) or 0, D.revVista) + 1
  f[spellId] = { sin = sin and true or false, rev = rev }
  D.revVista = math.max(D.revVista, rev)
  return f[spellId]
end

-- Fusión de lo que llega por el cable. `remitente` ya viene validado contra el
-- sujeto en Protocolo.lua; aquí sólo se resuelve el orden.
function D.fusionar(jugador, spellId, sin, rev)
  rev = tonumber(rev) or 0
  D.revVista = math.max(D.revVista, rev)
  local f = ficha(jugador)
  local prev = f[spellId]
  if prev and prev.rev >= rev then return false end
  f[spellId] = { sin = sin and true or false, rev = rev }
  return true
end

function D.serializar(jugador, spellId)
  local e = D.datos[jugador] and D.datos[jugador][spellId]
  if not e then return nil end
  return string.format("%s|%d|%d|%d", jugador, spellId, e.sin and 1 or 0, e.rev)
end

-- Todas las declaraciones, para el volcado a SavedVariables y para el perfil.
function D.volcarCrudo()
  local out = {}
  for jugador, f in pairs(D.datos) do
    for spellId, e in pairs(f) do
      out[#out + 1] = { jugador = jugador, spellId = spellId, sin = e.sin, rev = e.rev }
    end
  end
  table.sort(out, function(a, b)
    if a.jugador ~= b.jugador then return a.jugador < b.jugador end
    return a.spellId < b.spellId
  end)
  return out
end

function D.cargarCrudo(guardado)
  if type(guardado) ~= "table" then return 0 end
  local n = 0
  for i = 1, #guardado do
    local r = guardado[i]
    if type(r) == "table" and r.jugador and tonumber(r.spellId) then
      ficha(r.jugador)[tonumber(r.spellId)] = { sin = r.sin and true or false,
                                                rev = tonumber(r.rev) or 0 }
      D.revVista = math.max(D.revVista, tonumber(r.rev) or 0)
      n = n + 1
    end
  end
  return n
end
