-- Perfiles.lua — varias listas guardadas, y la de la cuenta partida.
--
-- Un perfil es la lista cerrada + las asignaciones + las declaraciones. El RL
-- carga uno y se propaga a toda la raid.
--
-- EL PERFIL ENTERO ES UN EMPUJÓN GRANDE. No se manda de golpe: se trocea y sale
-- por la cola pausada de Protocolo.lua, que espacia cada mensaje según lo que
-- pesa contra los 100 B/s congelados. Cargar un perfil de 15 buffs tarda unos
-- segundos en llegar a los 25, y así tiene que ser.
--
-- LAS DOS CUENTAS. Los SavedVariables van por perfil de CUENTA del launcher, y
-- este usuario tiene dos. Los perfiles guardados con una NO se ven con la otra.
-- El addon **no puede leer con qué cuenta se ha entrado**: no hay API para eso
-- en 3.3.5a. Lo que sí puede es no mentir. Cada base de datos se sella con un
-- identificador propio y con los personajes que ha visto; si aparece vacía, se
-- distingue "nunca se ha usado" de "esta cuenta no es la de tus perfiles" y se
-- dice en pantalla, en vez de enseñar una lista vacía como si nada.

local A = CoABuffs
local Pf = {}
A.Perfiles = Pf

Pf.avisoCuenta = nil

local function db()
  CoABuffsDB = CoABuffsDB or {}
  CoABuffsDB.perfiles = CoABuffsDB.perfiles or {}
  CoABuffsDB.sello = CoABuffsDB.sello or {}
  return CoABuffsDB
end

-- ------------------------------------------------------------- sello -------

function Pf.sellar()
  local d = db()
  local s = d.sello
  if not s.id then
    -- Identificador estable sin depender de time() ni de random: se construye
    -- con el primer personaje y el reino que ven estos SavedVariables.
    s.id = string.format("%s-%s", tostring(GetRealmName()), tostring(A.yo))
    s.creadoCon = A.yo
    s.personajes = {}
    s.nuevo = true
  end
  s.personajes = s.personajes or {}
  if A.yo and not s.personajes[A.yo] then
    s.personajes[A.yo] = true
    s.nPersonajes = (s.nPersonajes or 0) + 1
  end
  return s
end

function Pf.nPerfiles()
  local n = 0
  for _ in pairs(db().perfiles) do n = n + 1 end
  return n
end

-- Se llama al arrancar. Devuelve el texto del aviso, o nil si no hay nada raro.
function Pf.revisarCuenta()
  local s = Pf.sellar()
  local d = db()
  Pf.avisoCuenta = nil
  if Pf.nPerfiles() > 0 then
    d.sello.nuevo = nil
    return nil
  end
  if s.nuevo then
    -- Base de datos recién creada: o es la primera vez, o se ha entrado con la
    -- OTRA cuenta del launcher. El addon no puede distinguirlo, así que lo dice.
    Pf.avisoCuenta =
      "No hay perfiles guardados en esta cuenta.\n" ..
      "Si tenias perfiles, es muy probable que estes en la OTRA cuenta del launcher: " ..
      "los SavedVariables no se comparten entre cuentas y desde aqui no se ven.\n" ..
      "Sello de esta base de datos: " .. tostring(s.id) ..
      "  ·  Salir, cambiar de cuenta en el launcher y volver a entrar los recupera."
    return Pf.avisoCuenta
  end
  return nil
end

-- ------------------------------------------------------------ perfiles -----

function Pf.lista()
  local out = {}
  for nombre in pairs(db().perfiles) do out[#out + 1] = nombre end
  table.sort(out)
  return out
end

function Pf.guardar(nombre)
  if not nombre or nombre == "" then return false, "hace falta un nombre" end
  if not A.puedoEditar() then return false, "solo el lider y los asistentes" end
  local d = db()
  -- UN PERFIL NO LLEVA DECLARACIONES AJENAS. Una declaración es de quien la
  -- hace y sólo él puede emitirla; si el perfil las guardara, al cargarlo se
  -- quedarían en el cliente del RL sin viajar y él derivaría un reparto
  -- distinto del que derivan los otros 24. Mejor no tenerlas que tenerlas a
  -- medias.
  d.perfiles[nombre] = {
    lista = A.Estado.volcarCrudo(),
    autor = A.yo,
    entradas = #A.Estado.lista(),
  }
  d.sello.nuevo = nil
  A.log("perfil %q guardado (%d entradas).", nombre, d.perfiles[nombre].entradas)
  return true
end

function Pf.borrar(nombre)
  if not A.puedoEditar() then return false end
  db().perfiles[nombre] = nil
  return true
end

-- Cargar un perfil NO es fusionar: es imponer. Cada entrada sube por encima de
-- lo que corra ahora mismo, para que gane el orden total y no haya que discutir.
function Pf.cargar(nombre)
  if not A.puedoEditar() then
    A.log("solo el lider y los asistentes pueden cargar un perfil.")
    return false
  end
  local p = db().perfiles[nombre]
  if not p then A.log("no existe el perfil %q.", tostring(nombre)); return false end
  if A.Protocolo.desincronizado then
    A.log("|cffff8800vas por detras de la raid: espera a sincronizar antes de cargar un perfil.|r")
    return false
  end

  local base = math.max(A.Estado.revMax(), A.Estado.revVista)
  local cambiadas = {}
  local descartadas = 0
  for i = 1, #(p.lista or {}) do
    local r = p.lista[i]
    local id = tonumber(r.spellId)
    -- Un perfil guardado tambien puede venir corrupto o de otra version: se
    -- valida como cualquier otra entrada, no se mete a pelo en la tabla.
    if not id or not A.ESTADOS_VALIDOS[r.estado] then
      descartadas = descartadas + 1
    else
      local eq = {}
      for k = 1, math.min(#(r.equiv or {}), A.MAX_EQUIV) do eq[k] = r.equiv[k] end
      base = base + 1
      local e = {
        spellId = id, estado = r.estado, asignado = r.asignado,
        guid = r.guid, rev = base, autor = A.yo,
        nombre = (r.nombre or "?"):sub(1, 40), equiv = eq,
      }
      A.Estado.entradas[id] = e
      cambiadas[#cambiadas + 1] = e
    end
  end
  if descartadas > 0 then
    A.log("|cffff8800%d entrada(s) del perfil %q no eran validas y se han descartado.|r",
          descartadas, nombre)
  end
  if p.declaraciones and #p.declaraciones > 0 then
    A.log("|cffff8800el perfil %q trae declaraciones de un formato viejo: no se aplican, " ..
          "cada jugador declara lo suyo.|r", nombre)
  end

  -- Troceado y pausado: el perfil entero no sale de golpe.
  A.Protocolo.empujarPerfil(cambiadas)
  A.alCambiarEstado()
  A.log("perfil %q cargado: %d entradas propagandose a la raid.", nombre, #cambiadas)
  return true
end
