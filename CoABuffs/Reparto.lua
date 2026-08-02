-- Reparto.lua — PANEL DE REPARTO. Lo ve todo el mundo. Solo lectura.
--
-- Dos pestañas del MISMO panel, no dos ventanas: es el mismo estado mirado por
-- dos ejes. Una tercera ventana flotante en un cliente de 2009 es ruido.
--   POR BUFF     qué buff, quién lo pone, si está puesto.
--   POR JUGADOR  la raid uno a uno, con color.
--
-- SEPARACIÓN MODELO / PINTADO, y no es cosmética: el arnés no dibuja, así que
-- si el color viviera dentro de la función que crea widgets no habría forma de
-- juzgarlo. `R.modelo()` y `R.modeloJugadores()` devuelven datos puros; las
-- funciones de pintado sólo los traducen a etiquetas. Lo que juzga el listón 13
-- es el modelo, que es exactamente lo que se pinta.
--
-- Ventana de sólo lectura: aquí no existe el código para editar la lista ni las
-- asignaciones de nadie. Lo único que sale a la red es la declaración propia.

local A = CoABuffs
local R = {}
A.Reparto = R

R.ventana, R.cuerpo, R.pestanas = nil, nil, nil
R.pestana = "buffs"

-- ESTRUCTURA MONTADA UNA VEZ, CONTENIDO ACTUALIZADO EN CADA REPINTADO.
-- `R.clave` es la firma de lo que hay montado (pestaña + filas). Mientras no
-- cambie, refrescar es escribir textos; no se crea ni se destruye un widget.
R.clave = nil
R.filas = {}
R.fijos = {}

local function AceGUI() return LibStub and LibStub("AceGUI-3.0", true) end

-- ------------------------------------------------------------ MODELO -------

-- Fila por buff: nombre, quién lo pone, y si está puesto EN QUIEN MIRA.
-- estado: "activo" | "falta" | "sindatos"
function R.modelo()
  local lista, porNombre = A.Escaner.roster()
  local efectivos = A.Asignacion.derivar(lista, porNombre)
  local ids, filas = A.Estado.lista(), {}
  for i = 1, #ids do
    local e = A.Estado.get(ids[i])
    if e.estado == A.REQ then
      local quien = efectivos[e.spellId]
      -- Cuántos de los observables no lo tienen. "sin datos" NO es "activo".
      local faltan, sinDatos = 0, 0
      for k = 1, #lista do
        local est = A.Escaner.estadoBuff(lista[k], e)
        if est == false then faltan = faltan + 1
        elseif est == nil then sinDatos = sinDatos + 1 end
      end
      local mio = porNombre[A.yo] and A.Escaner.estadoBuff(porNombre[A.yo], e)
      filas[#filas + 1] = {
        spellId = e.spellId, nombre = e.nombre, asignado = quien,
        faltan = faltan, sinDatos = sinDatos,
        estado = (mio == true and "activo") or (mio == false and "falta") or "sindatos",
        mio = (quien == A.yo),
      }
    end
  end
  return filas
end

-- Fila por jugador. EL CRITERIO DE COLOR, que es lo que da sentido a la vista:
--   rojo  le falta un requerido QUE TIENE DUEÑO ASIGNADO. Sólo eso: un
--         requerido sin asignar es configuración del RL, no culpa de nadie.
--   verde tiene todos los requeridos con dueño.
--   gris  no hay datos de él. NO es verde: pintar de verde a quien no has
--         podido comprobar es el mismo falso positivo que anunciarlo.
function R.modeloJugadores()
  local lista, porNombre = A.Escaner.roster()
  local efectivos = A.Asignacion.derivar(lista, porNombre)
  local ids = A.Estado.lista()
  local filas = {}
  for i = 1, #lista do
    local p = lista[i]
    local faltan, sinDatos = {}, 0
    for k = 1, #ids do
      local e = A.Estado.get(ids[k])
      local duenno = efectivos[e.spellId]
      if e.estado == A.REQ and duenno then
        local est = A.Escaner.estadoBuff(p, e)
        if est == false then
          -- `jugador` es A QUIEN le falta. Sin este campo el susurro del boton
          -- "Avisar" salia literalmente "te toca X :: alguien": se le decia al
          -- buffeador que buffeara, sin decirle a quien, que es lo unico que
          -- necesitaba saber.
          faltan[#faltan + 1] = { spellId = e.spellId, nombre = e.nombre,
                                  asignado = duenno, jugador = p.nombre }
        elseif est == nil then
          sinDatos = sinDatos + 1
        end
      end
    end
    local color
    -- Verde exige haberlo comprobado. Si no hay ficha de auras no se ha
    -- comprobado nada, y eso incluye el caso en que NINGUN requerido tenga
    -- dueno: ahi el bucle de arriba no llega a mirar ni una vez y sin este
    -- filtro un jugador recien entrado en rango salia "al dia".
    local hayFicha = A.Escaner.ficha[p.nombre] ~= nil
    if #faltan > 0 then color = "rojo"
    elseif sinDatos > 0 or not A.Escaner.observable(p) or not hayFicha then color = "gris"
    else color = "verde" end
    filas[#filas + 1] = {
      nombre = p.nombre, token = p.token, color = color,
      faltan = faltan, sinDatos = sinDatos,
      presente = A.Escaner.presente(p), observable = A.Escaner.observable(p),
    }
  end
  return filas
end


-- ------------------------------------------------------------ ventana ------

function R.cerrar()
  -- El estilo se devuelve ANTES de soltar el widget: AceGUI lo recicla y el
  -- fondo oscuro y el titulo en serif se los quedaria el siguiente que lo pida.
  if R.ventana then A.UI.desestilizar(R.ventana) end
  if R.ventana and R.ventana.Release then pcall(function() R.ventana:Release() end) end
  R.ventana, R.cuerpo, R.pestanas = nil, nil, nil
  R.clave, R.filas, R.fijos = nil, {}, {}
  R.scrollDe, R.pestanaMontada = {}, nil
  -- R.btn tambien: apunta a dos botones ya devueltos al pool, y escribirles
  -- texto seria escribir en el boton de otro addon.
  R.btn = nil
  R.pintadoBuffs, R.pintadoJugadores = nil, nil
end

function R.alternar()
  if R.ventana then R.cerrar() else R.abrir() end
end

function R.abrir(pestana)
  local gui = AceGUI()
  if pestana then R.pestana = pestana end
  if not gui then A.log("AceGUI no disponible; usa /cab estado."); return end
  -- Ya abierta: se MARCA, no se pinta. Pintar aqui es el camino por el que el
  -- boton del minimapa y /cab jugadores se saltaban el techo: seis pulsaciones
  -- seguidas eran seis repintados en el mismo instante. El estrangulador tiene
  -- que ser el unico camino, tambien para lo que dispara una persona.
  if R.ventana then A.refrescoPendiente = true; return end

  local v = gui:Create("Frame")
  R.ventana = v
  v:SetTitle("Reparto de buffs")
  v:SetLayout("List")
  v:SetCallback("OnClose", function() R.cerrar() end)
  if v.SetWidth then v:SetWidth(560) end
  if v.SetHeight then v:SetHeight(440) end
  A.UI.estilizarMarco(v)
  A.UI.estilizarTitulo(v)

  R.pestanas = gui:Create("SimpleGroup")
  R.pestanas:SetFullWidth(true); R.pestanas:SetLayout("Flow")
  v:AddChild(R.pestanas)

  R.cuerpo = A.UI.areaScroll(v, 330)
  R.clave, R.filas, R.fijos = nil, {}, {}
  R.crearPestanas()
  R.refrescar()
end

-- LOS BOTONES DE PESTAÑA SE CREAN UNA VEZ. Antes se soltaban y se volvían a
-- crear en cada repintado (`pintarPestanas` empezaba por `ReleaseChildren`), o
-- sea decenas de veces por segundo en raid: por eso no se podía ni pulsarlos.
function R.crearPestanas()
  local gui = AceGUI()
  if not gui or not R.pestanas then return end
  R.pestanas:ReleaseChildren()
  R.btn = {}
  local function boton(clave, texto)
    local b = gui:Create("Button")
    b:SetWidth(170)
    b:SetText(texto)
    b:SetCallback("OnClick", function()
      if R.pestana ~= clave then
        R.pestana = clave
        A.alCambiarEstado()    -- repintado diferido, nunca dentro del callback
      end
    end)
    R.pestanas:AddChild(b)
    R.btn[clave] = { w = b, texto = texto }
  end
  boton("buffs", "Por buff")
  boton("jugadores", "Por jugador")
end

local function actualizarPestanas()
  for clave, d in pairs(R.btn or {}) do
    local t = (R.pestana == clave) and ("> " .. d.texto) or d.texto
    if d.ultimo ~= t then d.ultimo = t; d.w:SetText(t) end
  end
end

-- --------------------------------------------------------- pintado ---------

local COLOR = { rojo = "ff4040", verde = "40ff40", gris = "9d9d9d" }

-- Reconstrucción: sólo cuando cambia la ESTRUCTURA (otra pestaña, otro conjunto
-- de filas). El scroll se guarda y se devuelve.
--
-- Y SE RECUERDA POR PESTAÑA. Cambiar de pestaña también reconstruye, y con una
-- sola posición pasaba esto: bajabas la lista de jugadores, mirabas los buffs,
-- volvías y estabas otra vez arriba. Cada eje se acuerda de por dónde ibas.
R.scrollDe = {}

local function empezarMontaje(pestanaNueva)
  local anterior = R.pestanaMontada
  if anterior then R.scrollDe[anterior] = A.UI.scrollActual(R.cuerpo) end
  R.cuerpo:ReleaseChildren()
  R.filas, R.fijos = {}, {}
  R.pestanaMontada = pestanaNueva
  return R.scrollDe[pestanaNueva]
end

local function terminarMontaje(clave, prev)
  R.clave = clave
  A.UI.restaurarScroll(R.cuerpo, prev)
end

-- ------------------------------------------------------- por jugador -------

local function crearFilaJugador(padre)
  local gui = AceGUI()
  local fila = {}
  local g = gui:Create("SimpleGroup")
  g:SetFullWidth(true); g:SetLayout("Flow")

  fila.wNombre = gui:Create("Label"); fila.wNombre:SetWidth(150); g:AddChild(fila.wNombre)
  fila.wEstado = gui:Create("Label"); fila.wEstado:SetWidth(120); g:AddChild(fila.wEstado)
  fila.wDetalle = gui:Create("Label"); fila.wDetalle:SetWidth(180); g:AddChild(fila.wDetalle)

  -- El botón se crea SIEMPRE y se habilita o no según haya algo que avisar. Si
  -- apareciera y desapareciera con los datos, cada buff que se cae o se pone
  -- cambiaría la estructura y forzaría una reconstrucción, que es justo lo que
  -- tira el scroll.
  -- El susurro va al ASIGNADO del buff que falta, no al jugador en rojo.
  local b = gui:Create("Button")
  b:SetWidth(90); b:SetText("Avisar")
  b:SetCallback("OnClick", function()
    local f = fila.datos
    if f and #f.faltan > 0 then
      A.Avisos.recordarBuffs(f.faltan)
      A.alCambiarEstado()
    end
  end)
  fila.wBoton = b
  g:AddChild(b)

  padre:AddChild(g)
  A.UI.separador(g)
  return fila
end

local function pintarFilaJugador(fila, f, puedeSusurrar)
  fila.datos = f
  A.UI.poner(fila, "tNombre", fila.wNombre, A.Colores.nombre(f.nombre, f.token))
  local txt
  if f.color == "rojo" then txt = string.format("|cff%s%d sin poner|r", COLOR.rojo, #f.faltan)
  elseif f.color == "verde" then txt = "|cff" .. COLOR.verde .. "al dia|r"
  else txt = "|cff" .. COLOR.gris .. "sin datos|r" end
  A.UI.poner(fila, "tEstado", fila.wEstado, txt)
  local nombres = {}
  for i = 1, math.min(#f.faltan, 3) do nombres[#nombres + 1] = f.faltan[i].nombre end
  A.UI.poner(fila, "tDetalle", fila.wDetalle, table.concat(nombres, ", "))
  A.UI.desactivar(fila, "dBoton", fila.wBoton, not (puedeSusurrar and #f.faltan > 0))
end

local CAB_JUG = "La raid, uno a uno.  |cffff4040rojo|r = le falta algo con dueno  ·  " ..
                "|cff40ff40verde|r = al dia  ·  |cff9d9d9dgris|r = sin datos"

function R.pintarJugadores()
  local gui = AceGUI()
  local puedeSusurrar = A.puedoEditar()
  local filas = R.modeloJugadores()

  -- Rango 0: sólo su propia situación, y sin botón de susurro.
  local visibles = {}
  if puedeSusurrar then
    visibles = filas
  else
    for i = 1, #filas do if filas[i].nombre == A.yo then visibles[#visibles + 1] = filas[i] end end
  end

  local partes = { "J", puedeSusurrar and "1" or "0" }
  for i = 1, #visibles do partes[#partes + 1] = visibles[i].nombre end
  local clave = table.concat(partes, "|")

  if clave ~= R.clave then
    local prev = empezarMontaje("jugadores")
    local cab = gui:Create("Label")
    cab:SetFullWidth(true)
    cab:SetText(puedeSusurrar and CAB_JUG or "Tu situacion")
    R.cuerpo:AddChild(cab)
    for i = 1, #visibles do R.filas[i] = crearFilaJugador(R.cuerpo) end
    terminarMontaje(clave, prev)
  end

  for i = 1, #visibles do
    if R.filas[i] then pintarFilaJugador(R.filas[i], visibles[i], puedeSusurrar) end
  end

  -- FOTO DE LO PINTADO, con su instante Y su pestaña. Antes se guardaba sólo en
  -- esta rama: bastaba pulsar "Por buff" para que la foto se congelara y
  -- cualquiera que la leyera —incluido el arnés— midiera una pantalla de hace un
  -- minuto. Ahora la pestaña viaja con la foto y quien la lea puede saber si
  -- sigue siendo lo que hay delante del jugador.
  -- La foto lleva LO QUE SE HA PINTADO, no el modelo entero. Para un rango 0 se
  -- dibuja una sola fila; guardar las 25 y llamarlo "foto de lo pintado" es
  -- invitar a que alguien mida sobre filas que nadie ve.
  R.pintadoJugadores = { t = GetTime(), filas = visibles, pestana = "jugadores",
                         parciales = not puedeSusurrar }
  -- Y se invalida la del otro eje: lo que hay en pantalla ahora es esto. Antes
  -- solo se hacia en un sentido, y media invalidacion es una foto que miente.
  R.pintadoBuffs = nil
end

-- ---------------------------------------------------------- por buff -------

local function crearFilaBuff(padre)
  local gui = AceGUI()
  local fila = {}
  local g = gui:Create("SimpleGroup")
  g:SetFullWidth(true); g:SetLayout("Flow")

  fila.wIcono = gui:Create("InteractiveLabel")
  fila.wIcono:SetWidth(230)
  if fila.wIcono.SetImageSize then fila.wIcono:SetImageSize(16, 16) end
  g:AddChild(fila.wIcono)

  fila.wQuien = gui:Create("Label"); fila.wQuien:SetWidth(150); g:AddChild(fila.wQuien)
  fila.wEstado = gui:Create("Label"); fila.wEstado:SetWidth(110); g:AddChild(fila.wEstado)

  padre:AddChild(g)
  A.UI.separador(g)
  return fila
end

local function pintarFilaBuff(fila, f, porNombre)
  fila.datos = f
  local icono = A.iconoDe(f.spellId)
  if fila.icono ~= icono and fila.wIcono.SetImage then
    fila.icono = icono
    fila.wIcono:SetImage(icono)
    if fila.wIcono.SetImageSize then fila.wIcono:SetImageSize(16, 16) end
  end
  A.UI.poner(fila, "tIcono", fila.wIcono,
    (f.mio and "|cffffd100" or "") .. (f.nombre or "?") .. (f.mio and "|r" or ""))
  -- El tooltip se vuelve a colgar sólo si cambia el texto que muestra.
  if fila.tip ~= tostring(f.spellId) then
    fila.tip = tostring(f.spellId)
    A.UI.tooltip(fila.wIcono, f.nombre or "?", { "spellId " .. tostring(f.spellId) })
  end

  local ficha = f.asignado and porNombre[f.asignado]
  A.UI.poner(fila, "tQuien", fila.wQuien,
    f.asignado and A.Colores.nombre(f.asignado, ficha and ficha.token)
    or "|cff9d9d9d(sin asignar)|r")

  local txt
  if f.estado == "activo" then txt = "|cff40ff40activo|r"
  elseif f.estado == "falta" then txt = "|cffff4040te falta|r"
  else txt = "|cff9d9d9dsin datos|r" end
  A.UI.poner(fila, "tEstado", fila.wEstado, txt)
end

local function crearFilaDeclarar(padre, spellId)
  local gui = AceGUI()
  local fila = { spellId = spellId }
  local g = gui:Create("SimpleGroup")
  g:SetFullWidth(true); g:SetLayout("Flow")
  fila.wNombre = gui:Create("Label"); fila.wNombre:SetWidth(230); g:AddChild(fila.wNombre)
  local b = gui:Create("Button")
  b:SetWidth(200)
  b:SetCallback("OnClick", function()
    -- El estado se relee AL PULSAR. Si se capturase al crear el botón, un botón
    -- que lleva rato en pantalla mandaría lo contrario de lo que dice.
    local sin = A.Declaraciones.noLoTiene(A.yo, fila.spellId)
    A.Protocolo.declarar(fila.spellId, not sin)
    A.alCambiarEstado()
  end)
  fila.wBoton = b
  g:AddChild(b)
  padre:AddChild(g)
  return fila
end

function R.pintarBuffs()
  local gui = AceGUI()
  local filas = R.modelo()
  local _, porNombre = A.Escaner.roster()

  local mios = {}
  for i = 1, #filas do if filas[i].mio then mios[#mios + 1] = filas[i] end end

  local partes = { "B" }
  for i = 1, #filas do partes[#partes + 1] = tostring(filas[i].spellId) end
  partes[#partes + 1] = "M"
  for i = 1, #mios do partes[#partes + 1] = tostring(mios[i].spellId) end
  local clave = table.concat(partes, "|")

  if clave ~= R.clave then
    local prev = empezarMontaje("buffs")
    R.fijos.cabMios = gui:Create("Label")
    R.fijos.cabMios:SetFullWidth(true)
    R.cuerpo:AddChild(R.fijos.cabMios)
    R.filas.mios = {}
    for i = 1, #mios do R.filas.mios[i] = crearFilaBuff(R.cuerpo) end

    local h = gui:Create("Heading")
    h:SetFullWidth(true); h:SetText("Reparto completo de la raid")
    R.cuerpo:AddChild(h)
    R.filas.todos = {}
    for i = 1, #filas do R.filas.todos[i] = crearFilaBuff(R.cuerpo) end

    local h2 = gui:Create("Heading")
    h2:SetFullWidth(true); h2:SetText("Declara lo que NO tienes (solo sobre ti)")
    R.cuerpo:AddChild(h2)
    R.filas.decl = {}
    for i = 1, #filas do R.filas.decl[i] = crearFilaDeclarar(R.cuerpo, filas[i].spellId) end

    R.fijos.pie = gui:Create("Label")
    R.fijos.pie:SetFullWidth(true)
    R.cuerpo:AddChild(R.fijos.pie)
    terminarMontaje(clave, prev)
  end

  A.UI.poner(R.fijos, "tCabMios", R.fijos.cabMios,
    string.format("|cffffd100LO TUYO|r  ·  %d buff(s) a tu cargo", #mios))
  for i = 1, #mios do
    if R.filas.mios[i] then pintarFilaBuff(R.filas.mios[i], mios[i], porNombre) end
  end
  for i = 1, #filas do
    if R.filas.todos[i] then pintarFilaBuff(R.filas.todos[i], filas[i], porNombre) end
  end
  for i = 1, #filas do
    local fd = R.filas.decl[i]
    if fd then
      A.UI.poner(fd, "tNombre", fd.wNombre, filas[i].nombre or "?")
      local sin = A.Declaraciones.noLoTiene(A.yo, filas[i].spellId)
      A.UI.poner(fd, "tBoton", fd.wBoton,
        sin and "he declarado que NO lo tengo" or "declarar que no lo tengo")
    end
  end

  local _, sinDatos, _, total = A.Escaner.cobertura()
  A.UI.poner(R.fijos, "tPie", R.fijos.pie,
    string.format("|cff9d9d9dde %d jugadores, sin datos de %d  ·  solo lectura|r",
                  total, sinDatos))

  R.pintadoBuffs = { t = GetTime(), filas = filas, pestana = "buffs" }
  -- Y se invalida la del otro eje: lo que hay en pantalla ahora es esto.
  R.pintadoJugadores = nil
end

function R.refrescar()
  local gui = AceGUI()
  if not gui or not R.ventana or not R.cuerpo then return end
  A.anotarRepintado("reparto")
  actualizarPestanas()
  if R.pestana == "jugadores" then R.pintarJugadores() else R.pintarBuffs() end
end
