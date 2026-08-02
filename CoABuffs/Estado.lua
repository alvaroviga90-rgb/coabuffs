-- Estado.lua — la lista cerrada, replicada.
--
-- CONVERGENCIA. Cada entrada de la lista es un registro independiente con su
-- propio (rev, autor). Al fusionar gana el de rev mayor, y a igualdad de rev
-- gana el autor mayor alfabéticamente. Eso es un orden TOTAL y determinista:
--   * un mensaje viejo que llega tarde pierde y no hace nada (reordenamiento)
--   * el mismo mensaje aplicado dos veces da el mismo resultado (duplicados)
--   * dos asistentes editando buffs DISTINTOS conservan los dos cambios
--   * dos asistentes editando el MISMO buff convergen al mismo ganador en
--     todos los clientes, aunque los mensajes lleguen en órdenes distintos
-- No hace falta negociar, ni bloquear, ni pedir turno. Lo que sí hace falta es
-- que el perdedor se entere: de eso se encarga el heartbeat de Protocolo.lua.
--
-- Borrar no borra: deja lápida (estado = "none"). Si se borrara de verdad, un
-- cliente con estado viejo reintroduciría la entrada al resincronizar.

local A = CoABuffs
local E = {}
A.Estado = E

E.entradas = {}      -- [spellId] = {estado, asignado, guid, rev, autor, nombre, equiv}

-- RELOJ DE LAMPORT. La revisión más alta que este cliente ha VISTO, aunque no
-- la tenga: llega en los latidos ajenos y en las fusiones. Sin esto, un oficial
-- que entra en frío y edita antes de sincronizar nace con rev 1, pierde contra
-- la rev que ya corre por la raid, y su edición la aceptan CERO clientes. Él
-- ve el panel actualizado y veinte segundos después se le deshace solo.
E.revVista = 0
-- ¿Hemos llegado a oír a alguien? Mientras sea false, este cliente NO sabe por
-- dónde va la raid y no puede fabricar una revisión que compita.
E.sincronizado = false

-- Cinturón: una revisión que no sea un entero razonable no entra en el reloj.
-- Da igual por dónde llegue; si algo la cuela, aquí se para.
function E.verRev(r)
  r = tonumber(r)
  if not r or r ~= math.floor(r) or r < 0 or r >= 2147483647 then return end
  if r > E.revVista then E.revVista = r end
  E.sincronizado = true
end

local function nuevaEntrada(spellId)
  return {
    spellId = spellId, estado = A.NONE, asignado = nil, guid = nil,
    rev = 0, autor = "", nombre = "?", equiv = {},
  }
end

-- ¿gana a? Orden total: (rev, autor)
local function gana(a, b)
  if not b then return true end
  if a.rev ~= b.rev then return a.rev > b.rev end
  return tostring(a.autor) > tostring(b.autor)
end

function E.reset()
  E.entradas = {}
end

-- PERSISTENCIA. Sin esto, un reinicio de servidor con toda la raid relogueando
-- a la vez borra la lista cerrada entera: nadie tiene un estado más nuevo que
-- nadie y no hay de dónde resincronizar. Se guarda con su (rev, autor), así que
-- al volver se funde con lo de los demás por las mismas reglas de siempre.
function E.volcarCrudo()
  local out = {}
  local ids = E.lista()
  for i = 1, #ids do
    local e = E.entradas[ids[i]]
    out[#out + 1] = {
      spellId = e.spellId, estado = e.estado, asignado = e.asignado, guid = e.guid,
      rev = e.rev, autor = e.autor, nombre = e.nombre, equiv = e.equiv,
    }
  end
  return out
end

function E.cargarCrudo(guardado)
  if type(guardado) ~= "table" then return 0 end
  local n = 0
  for i = 1, #guardado do
    local r = guardado[i]
    if type(r) == "table" and tonumber(r.spellId) and A.ESTADOS_VALIDOS[r.estado] then
      E.entradas[tonumber(r.spellId)] = {
        spellId = tonumber(r.spellId), estado = r.estado, asignado = r.asignado,
        guid = r.guid, rev = tonumber(r.rev) or 0, autor = tostring(r.autor or ""),
        nombre = r.nombre or "?", equiv = r.equiv or {},
      }
      n = n + 1
    end
  end
  return n
end

function E.revMax()
  local m = 0
  for _, e in pairs(E.entradas) do if e.rev > m then m = e.rev end end
  return m
end

function E.get(spellId)
  return E.entradas[spellId]
end

function E.lista()
  local out = {}
  for id in pairs(E.entradas) do out[#out + 1] = id end
  table.sort(out)
  return out
end

-- Sólo se llama desde Core tras comprobar el rango. Devuelve la entrada nueva.
function E.editar(spellId, campos, autor)
  local e = E.entradas[spellId] or nuevaEntrada(spellId)
  local nueva = {
    spellId = spellId,
    estado  = campos.estado  or e.estado,
    asignado= campos.asignado ~= nil and campos.asignado or e.asignado,
    guid    = campos.guid    ~= nil and campos.guid or e.guid,
    nombre  = campos.nombre  or e.nombre,
    equiv   = campos.equiv   or e.equiv,
    -- Por encima de todo lo que se ha visto, no sólo de lo que se tiene.
    rev     = math.max(E.revMax(), E.revVista) + 1,
    autor   = autor,
  }
  if campos.asignado == false then nueva.asignado = nil; nueva.guid = nil end
  E.entradas[spellId] = nueva
  return nueva
end

-- Fusión. Devuelve (cambio, cuantas). No mira quién la manda: la autoridad se
-- comprueba ANTES, en Protocolo.lua, y una entrada que no supere el filtro no
-- llega hasta aquí.
function E.fusionar(remotas)
  local cambio, n = false, 0
  for spellId, r in pairs(remotas) do
    E.verRev(r.rev)
    local local_ = E.entradas[spellId]
    if gana(r, local_) then
      -- Si lo que se pisa era MÍO, hay que decírselo a quien lo escribió. Un
      -- cambio que se deshace solo y en silencio es peor que no poder hacerlo.
      if local_ and local_.autor == A.yo and local_.rev > 0
         and (local_.estado ~= r.estado or local_.asignado ~= r.asignado) then
        A.log("|cffff8800tu cambio en %s lo ha reemplazado %s.|r",
              tostring(local_.nombre), tostring(r.autor))
      end
      E.entradas[spellId] = r
      cambio, n = true, n + 1
    end
  end
  return cambio, n
end

-- Digest determinista de la lista. Dos clientes convergidos dan la misma
-- cadena; se manda en el heartbeat y es lo que dispara las resincronizaciones.
function E.digest()
  local ids = E.lista()
  local h = 5381
  for i = 1, #ids do
    local e = E.entradas[ids[i]]
    local s = string.format("%d:%s:%s:%d:%s", e.spellId, e.estado,
                            tostring(e.asignado), e.rev, e.autor)
    for j = 1, #s do
      h = (h * 33 + string.byte(s, j)) % 4294967296
    end
  end
  return string.format("%x", h)
end

-- ------------------------------------------------------- serialización ------
-- Formato compacto a propósito: con 49 B fijos de coste por mensaje, cada byte
-- de cuerpo que se ahorra es presupuesto que no se gasta.
--   entrada := spellId,estado,asignado,rev,autor,nombre,equiv1 equiv2
local function esc(s)
  return (tostring(s or ""):gsub("[|;,]", " "))
end

function E.serializarEntrada(e)
  local eq = table.concat(e.equiv or {}, " ")
  return string.format("%d,%s,%s,%d,%s,%s,%s",
    e.spellId, e.estado, esc(e.asignado), e.rev, esc(e.autor), esc(e.nombre), eq)
end

function E.parsearEntrada(txt)
  local id, estado, asignado, rev, autor, nombre, eq =
    txt:match("^(%d+),([^,]*),([^,]*),(%d+),([^,]*),([^,]*),([^,]*)$")
  if not id then return nil end
  if not A.ESTADOS_VALIDOS[estado] then return nil end
  local revN = tonumber(rev)
  if not revN or revN >= 2147483647 then return nil end
  local equiv = {}
  for n in tostring(eq):gmatch("%d+") do equiv[#equiv + 1] = tonumber(n) end
  return {
    spellId = tonumber(id), estado = estado,
    asignado = (asignado ~= "" and asignado) or nil,
    rev = tonumber(rev), autor = autor,
    nombre = (nombre ~= "" and nombre) or "?", equiv = equiv,
  }
end

-- Trocea la lista en bloques que quepan de sobra en un mensaje de AceComm.
-- El troceo de AceComm existe, pero un mensaje multiparte que pierde un trozo
-- se tira entero: es más barato mandar bloques pequeños que reenviar.
function E.bloques(maxCuerpo)
  local ids, out, actual = E.lista(), {}, {}
  local largo = 0
  for i = 1, #ids do
    local s = E.serializarEntrada(E.entradas[ids[i]])
    if largo + #s + 1 > maxCuerpo and #actual > 0 then
      out[#out + 1] = actual; actual = {}; largo = 0
    end
    actual[#actual + 1] = s
    largo = largo + #s + 1
  end
  if #actual > 0 then out[#out + 1] = actual end
  return out
end
