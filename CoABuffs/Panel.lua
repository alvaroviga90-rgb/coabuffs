-- Panel.lua — CONFIGURADOR. Solo rank 1 y 2.
--
-- Ventana distinta de la de reparto, no la misma con permisos. Los demás ni la
-- abren ni existe en su cliente el camino para editar nada: la puerta de verdad
-- está en A.editar y en Protocolo (autoridad por rango del REMITENTE), y ésta
-- ni siquiera se dibuja para quien no manda.
--
-- Estructura: cabecera fija, ÁREA CON SCROLL, y pie fijo con los botones. El
-- .toc ya cargaba AceGUIContainer-ScrollFrame y no lo montaba nadie; por eso el
-- contenido se salía del marco y el botón de cerrar flotaba entre las filas.
--
-- REFRESCAR NO ES RECONSTRUIR (ver la explicación larga en UI.lua). La
-- estructura se monta una vez y cada repintado sólo escribe textos y valores
-- sobre los widgets que ya existen. Sólo se reconstruye cuando cambia la
-- ESTRUCTURA de verdad —otra lista, otro filtro, otras propuestas— y ni siquiera
-- entonces si el jugador tiene un desplegable abierto: eso se espera a que lo
-- cierre, SIN plazo, porque el listón dice que un repintado no cierra un
-- desplegable y "salvo que lleve mucho rato" no es "nunca". Aplazar no es
-- congelar: las filas que ya existen se siguen actualizando y las nuevas se
-- añaden al final (AddChild no libera nada); lo único que espera al menú es
-- volver a ordenarlas, y la cabecera lo dice pasados A.APLAZO_AVISO segundos.
-- Con el código anterior el panel se soltaba entero decenas de veces por
-- segundo en raid: el scroll saltaba arriba solo y el desplegable se cerraba al
-- abrirlo.

local A = CoABuffs
local Pan = {}
A.Panel = Pan

local function AceGUI() return LibStub and LibStub("AceGUI-3.0", true) end

Pan.ventana, Pan.cuerpo, Pan.pie = nil, nil, nil
Pan.clave, Pan.filas, Pan.fijos, Pan.desplegables = nil, {}, {}, {}
Pan.pendiente = nil     -- instante en que se aplazo la reconstruccion, o nil

local ETIQUETA = {
  [A.REQ] = "Requerido", [A.OPC] = "Opcional",
  [A.PROH] = "Prohibido", [A.NONE] = "Fuera de la lista",
}
local ORDEN_ESTADOS = { A.REQ, A.OPC, A.PROH, A.NONE }
local MAX_PROPUESTAS = 30

function Pan.puedeVer() return A.puedoEditar() end

function Pan.alternar()
  if not Pan.puedeVer() then
    A.log("el configurador es solo para el lider y los asistentes. " ..
          "Abriendo tu panel de reparto (solo lectura).")
    A.Reparto.alternar()
    return
  end
  if Pan.ventana then Pan.cerrar() else Pan.abrir() end
end

function Pan.cerrar()
  -- Se devuelve el estilo ANTES de soltar el widget: si no, el marco vuelve al
  -- pool de AceGUI con nuestro fondo y nuestra fuente puestos.
  if Pan.ventana then A.UI.desestilizar(Pan.ventana) end
  if Pan.ventana and Pan.ventana.Release then pcall(function() Pan.ventana:Release() end) end
  Pan.ventana, Pan.cuerpo, Pan.pie = nil, nil, nil
  Pan.cabecera, Pan.piezas = nil, nil
  Pan.clave, Pan.filas, Pan.fijos, Pan.desplegables = nil, {}, {}, {}
  Pan.pendiente, Pan.cacheProps, Pan.cacheEquiv = nil, nil, nil
end

function Pan.abrir()
  if not Pan.puedeVer() then return end
  local gui = AceGUI()
  if not gui then A.log("AceGUI no disponible; usa /cab estado."); return end

  local v = gui:Create("Frame")
  Pan.ventana = v
  v:SetTitle("CoABuffs · configurador")
  v:SetLayout("List")
  v:SetCallback("OnClose", function() Pan.cerrar() end)
  if v.SetWidth then v:SetWidth(760) end
  if v.SetHeight then v:SetHeight(520) end
  A.UI.estilizarMarco(v)
  A.UI.estilizarTitulo(v)

  Pan.cabecera = gui:Create("Label")
  Pan.cabecera:SetFullWidth(true)
  v:AddChild(Pan.cabecera)

  Pan.cuerpo = A.UI.areaScroll(v, 360)   -- alto FIJO: el pie no flota
  Pan.pie = gui:Create("SimpleGroup")
  Pan.pie:SetFullWidth(true)
  Pan.pie:SetLayout("Flow")
  v:AddChild(Pan.pie)

  Pan.clave, Pan.filas, Pan.fijos, Pan.desplegables = nil, {}, {}, {}
  Pan.crearPie()
  Pan.refrescar()
end

local function nombresRaid()
  local lista = A.Escaner.roster()
  local mapa, orden = { [""] = "(sin asignar)" }, { "" }
  for i = 1, #lista do
    mapa[lista[i].nombre] = A.Colores.nombre(lista[i].nombre, lista[i].token)
    orden[#orden + 1] = lista[i].nombre
  end
  return mapa, orden
end

-- Un desplegable ABIERTO es el jugador con la mano en el ratón. No se le toca:
-- ni SetList (que hace pullout:Clear y le vacía la lista en la cara) ni
-- SetValue, ni por supuesto liberarlo.
local function apuntarDesplegable(dd)
  Pan.desplegables[#Pan.desplegables + 1] = dd
  return dd
end

-- El pie se monta aparte y sobrevive a las reconstrucciones del cuerpo, asi que
-- su desplegable se mira aparte: si no, una reconstruccion del cuerpo lo
-- borraria del registro y dejariamos de saber que esta abierto.
function Pan.hayAbierto()
  if A.UI.algunoAbierto(Pan.desplegables) then return true end
  if Pan.piezas and Pan.piezas.wPerfiles and Pan.piezas.wPerfiles.open then return true end
  return false
end

local function ponerLista(fila, campo, dd, clave, mapa, orden, valor)
  if not dd or dd.open then return end
  if fila[campo] ~= clave then
    fila[campo] = clave
    dd:SetList(mapa, orden)
    fila.valor = nil                     -- SetList rehace los items: hay que revalorar
  end
  valor = valor or ""
  if fila.valor ~= valor then fila.valor = valor; dd:SetValue(valor) end
end

-- ------------------------------------------------------------- filas -------

local function crearFilaEntrada(padre, spellId)
  local gui = AceGUI()
  local fila = { spellId = spellId }
  local g = gui:Create("SimpleGroup")
  g:SetFullWidth(true); g:SetLayout("Flow")

  -- Icono + nombre, con el spellId en el tooltip. El icono sale de UnitBuff
  -- posición 3, que ya se captura al escanear: no se consulta nada.
  fila.wEt = gui:Create("InteractiveLabel")
  fila.wEt:SetWidth(210)
  if fila.wEt.SetImageSize then fila.wEt:SetImageSize(16, 16) end
  g:AddChild(fila.wEt)

  fila.wEstado = gui:Create("Dropdown")
  fila.wEstado:SetWidth(130)
  fila.wEstado:SetList(ETIQUETA, ORDEN_ESTADOS)
  fila.wEstado:SetCallback("OnValueChanged", function(_, _, val)
    A.editar(fila.spellId, { estado = val })
  end)
  apuntarDesplegable(fila.wEstado)
  g:AddChild(fila.wEstado)

  fila.wAsig = gui:Create("Dropdown")
  fila.wAsig:SetWidth(160)
  fila.wAsig:SetCallback("OnValueChanged", function(_, _, val)
    A.editar(fila.spellId, { asignado = (val ~= "" and val) or false })
  end)
  apuntarDesplegable(fila.wAsig)
  g:AddChild(fila.wAsig)

  -- CASO LIMITE: si tras excluir no queda NADIE, el desplegable no puede
  -- quedarse vacio y mudo. Se dice en la fila. La etiqueta existe siempre y se
  -- queda vacía cuando no toca: si apareciera y desapareciera, cada declaración
  -- cambiaría la estructura y forzaría una reconstrucción.
  fila.wAviso = gui:Create("Label"); fila.wAviso:SetWidth(200); g:AddChild(fila.wAviso)

  fila.wEfectivo = gui:Create("Label"); fila.wEfectivo:SetWidth(150); g:AddChild(fila.wEfectivo)

  padre:AddChild(g)
  A.UI.separador(g)
  return fila
end

local function pintarFilaEntrada(fila, e, efectivos, mapaNombres, ordenNombres, porNombre)
  local icono = A.iconoDe(e.spellId)
  if fila.icono ~= icono and fila.wEt.SetImage then
    fila.icono = icono
    fila.wEt:SetImage(icono)
    if fila.wEt.SetImageSize then fila.wEt:SetImageSize(16, 16) end
  end
  A.UI.poner(fila, "tEt", fila.wEt, e.nombre or "?")
  -- El tooltip lleva el spellId y el texto del juego. La lista de equivalentes
  -- se ha quitado: era ruido y ademas invitaba a fiarse de ella.
  local reg2 = A.Catalogo.reg[e.spellId]
  local textoTip = reg2 and reg2.texto or "sin texto de tooltip"
  if fila.tip ~= textoTip then
    fila.tip = textoTip
    A.UI.tooltip(fila.wEt, e.nombre or "?",
      { "spellId " .. tostring(e.spellId), textoTip })
  end

  if not fila.wEstado.open and fila.valEstado ~= e.estado then
    fila.valEstado = e.estado
    fila.wEstado:SetValue(e.estado)
  end

  -- QUIEN HA DECLARADO QUE NO LO TIENE DESAPARECE DEL DESPLEGABLE de ESE buff.
  -- Antes salia un renglon naranja debajo de cada fila ("han declarado que NO lo
  -- tienen: Fulano") que ensuciaba la lista entera. Asi es mas limpio y ademas
  -- impide asignarselo. El dato no se pierde: va al tooltip del desplegable, o
  -- dentro de tres semanas nadie entiende por que falta gente.
  local mapaE, ordenE = { [""] = "(sin asignar)" }, { "" }
  local excluidos = {}
  for i = 1, #ordenNombres do
    local nm = ordenNombres[i]
    if nm ~= "" then
      if A.Declaraciones.noLoTiene(nm, e.spellId) then
        excluidos[#excluidos + 1] = nm
      else
        mapaE[nm] = mapaNombres[nm]; ordenE[#ordenE + 1] = nm
      end
    end
  end
  ponerLista(fila, "claveLista", fila.wAsig, table.concat(ordenE, ","),
             mapaE, ordenE, e.asignado or "")

  local tip2 = table.concat(excluidos, ", ")
  if fila.tipAsig ~= tip2 then
    fila.tipAsig = tip2
    A.UI.tooltip(fila.wAsig, "Asignar " .. (e.nombre or "?"),
      (#excluidos > 0)
        and { "No aparecen porque han declarado que NO lo tienen:", tip2 }
        or { "Nadie ha declarado que no lo tenga." })
  end

  A.UI.poner(fila, "tAviso", fila.wAviso,
    (#ordenE <= 1) and "|cffff8800nadie presente puede ponerlo|r" or "")

  -- Se guarda el DATO pintado, no solo el texto: es lo que permite comprobar
  -- desde fuera si esta fila esta diciendo la verdad, sin tener que reconstruir
  -- la cadena con colores para compararla.
  local quien = efectivos[e.spellId]
  fila.efectivo = quien
  A.UI.poner(fila, "tEfectivo", fila.wEfectivo,
    "efectivo: " .. (quien and A.Colores.nombre(quien, porNombre[quien] and porNombre[quien].token)
                     or "|cff808080-|r"))
end

local function crearFilaPropuesta(padre)
  local gui = AceGUI()
  local fila = {}
  local g = gui:Create("SimpleGroup")
  g:SetFullWidth(true); g:SetLayout("Flow")
  fila.wEt = gui:Create("InteractiveLabel")
  fila.wEt:SetWidth(430)
  if fila.wEt.SetImageSize then fila.wEt:SetImageSize(16, 16) end
  g:AddChild(fila.wEt)
  local b = gui:Create("Button")
  b:SetWidth(150); b:SetText("Anadir")
  b:SetCallback("OnClick", function()
    local p = fila.datos
    if not p then return end
    -- Se anade SIN equivalencias: esas las confirma el oficial una a una.
    -- Y se asigna solo a quien ya figure como efectivo.
    local lista = A.Escaner.roster()
    local tmp = { spellId = p.spellId, equiv = {}, estado = A.REQ }
    local cand = A.Asignacion.elegibles(tmp, lista)
    A.editar(p.spellId, { estado = A.REQ, nombre = p.nombre, equiv = {},
                          asignado = cand[1] or false })
    A.alCambiarEstado()
  end)
  fila.wBoton = b
  g:AddChild(b)
  padre:AddChild(g)
  return fila
end

local function pintarFilaPropuesta(fila, p)
  fila.datos = p
  if p.icono and fila.icono ~= p.icono and fila.wEt.SetImage then
    fila.icono = p.icono
    fila.wEt:SetImage(p.icono)
    if fila.wEt.SetImageSize then fila.wEt:SetImageSize(16, 16) end
  end
  -- Quien lo pone: el CONJUNTO de clases visto. Mas de una = no es de clase.
  local quien
  if p.sinLanzador then quien = "|cff808080aura de objeto o sistema|r"
  elseif p.nClases == 0 then quien = "|cff808080lanzador desconocido|r"
  elseif p.nClases == 1 then quien = A.Colores.nombre(p.clases[1], p.clases[1])
  else quien = "|cffff8800varias clases (" .. table.concat(p.clases, ", ") .. "): no es de clase|r" end
  A.UI.poner(fila, "tEt", fila.wEt, string.format("%s · %s · visto en %d · %s",
    p.nombre, quien, p.vistoEn, p.motivo))
  local tip = A.Catalogo.reg[p.spellId] and A.Catalogo.reg[p.spellId].texto
              or "sin texto de tooltip"
  if fila.tip ~= tip then
    fila.tip = tip
    A.UI.tooltip(fila.wEt, p.nombre, { "spellId " .. p.spellId, tip })
  end
end

local function crearFilaEquiv(padre)
  local gui = AceGUI()
  local fila = {}
  local g = gui:Create("SimpleGroup")
  g:SetFullWidth(true); g:SetLayout("Flow")
  fila.wEt = gui:Create("Label"); fila.wEt:SetWidth(430); g:AddChild(fila.wEt)
  local b = gui:Create("Button")
  b:SetWidth(150); b:SetText("Confirmar")
  b:SetCallback("OnClick", function()
    local d = fila.datos
    if not d then return end
    A.confirmarEquivalencia(d.principal, d.spellId)
    A.alCambiarEstado()
  end)
  fila.wBoton = b
  g:AddChild(b)
  padre:AddChild(g)
  return fila
end

-- --------------------------------------------------------------- datos -----

-- Lo que se va a enseñar, calculado ANTES de tocar un solo widget. De aquí sale
-- también la firma de la estructura: si no cambia, no se reconstruye nada.
local function recopilar()
  local d = {}
  d.lista, d.porNombre = A.Escaner.roster()
  d.efectivos = A.Asignacion.derivar(d.lista, d.porNombre)
  d.mapaNombres, d.ordenNombres = nombresRaid()
  d.vistos, d.sinDatos, _, d.total = A.Escaner.cobertura()
  d.aviso = A.Perfiles.avisoCuenta

  d.ids = A.Estado.lista()
  d.entradas = {}
  for i = 1, #d.ids do
    local e = A.Estado.get(d.ids[i])
    if e.estado ~= A.NONE then d.entradas[#d.entradas + 1] = e end
  end

  d.vista = Pan.filtroVista or "propuestas"
  local cajon = (d.vista == "propuestas" and A.Clasificador.GRUPO)
             or (d.vista == "duda" and A.Clasificador.DUDA)
             or (d.vista == "fuera" and A.Clasificador.FUERA) or nil

  -- LAS PROPUESTAS SE CACHEAN. `C.propuestas` recorre y ordena el catalogo
  -- entero, que es el historico de SavedVariables y crece sin techo; llamarlo en
  -- cada repintado (2/s) era el coste escondido de esta ventana. La cache se
  -- invalida sola con la revision del catalogo y con los filtros, que es
  -- exactamente de lo que depende el resultado.
  local claveProps = table.concat({ tostring(A.Catalogo.rev), d.vista,
    tostring(Pan.filtroClase or ""), Pan.soloSesion and "S" or "H",
    tostring(A.Estado.revMax()) }, "|")
  if Pan.cacheProps and Pan.cacheProps.clave == claveProps then
    d.props = Pan.cacheProps.props
  else
    d.props = {}
    if d.vista ~= "lista" then
      local props = A.Catalogo.propuestas(cajon, Pan.soloSesion)
      for i = 1, #props do
        local p = props[i]
        local actual = A.Estado.get(p.spellId)
        local yaEsta = actual and actual.estado ~= A.NONE
        local pasaClase = (Pan.filtroClase or "") == ""
        if not pasaClase then
          for k = 1, #p.clases do if p.clases[k] == Pan.filtroClase then pasaClase = true end end
        end
        if not yaEsta and pasaClase and #d.props < MAX_PROPUESTAS then
          d.props[#d.props + 1] = p
        end
      end
    end
    Pan.cacheProps = { clave = claveProps, props = d.props }
  end

  -- Las equivalencias sólo se piden de lo que YA está en la lista cerrada (unas
  -- pocas entradas), no de todo el catálogo, y también se cachean: cada llamada
  -- recorre el catálogo entero.
  local claveEq = tostring(A.Catalogo.rev) .. "|" .. tostring(A.Estado.revMax())
  if Pan.cacheEquiv and Pan.cacheEquiv.clave == claveEq then
    d.equivs, d.mapaC, d.ordenC = Pan.cacheEquiv.equivs, Pan.cacheEquiv.mapaC,
                                  Pan.cacheEquiv.ordenC
  else
    d.equivs = {}
    for i = 1, #d.ids do
      local e = A.Estado.get(d.ids[i])
      if e.estado ~= A.NONE then
        local props2 = A.Catalogo.exclusionesPropuestas(e.spellId)
        for k = 1, #props2 do
          local x = props2[k]
          local yaConf = false
          for z = 1, #(e.equiv or {}) do if e.equiv[z] == x.spellId then yaConf = true end end
          if not yaConf then
            d.equivs[#d.equivs + 1] = { principal = e.spellId, nombrePrincipal = e.nombre,
                                        spellId = x.spellId, nombre = x.nombre, motivo = x.motivo }
          end
        end
      end
    end

    -- Las clases del filtro también son estructura: son los items del desplegable.
    d.mapaC, d.ordenC = { [""] = "(todas)" }, { "" }
    local vistas = {}
    for _, r in pairs(A.Catalogo.reg) do
      for token in pairs(r.clases or {}) do
        if not vistas[token] then
          vistas[token] = true
          d.mapaC[token] = A.Colores.nombre(token, token)
          d.ordenC[#d.ordenC + 1] = token
        end
      end
    end
    table.sort(d.ordenC)
    Pan.cacheEquiv = { clave = claveEq, equivs = d.equivs, mapaC = d.mapaC, ordenC = d.ordenC }
  end

  d.perfiles = A.Perfiles.lista()

  local partes = { "P", d.vista, tostring(Pan.filtroClase or ""),
                   Pan.soloSesion and "S" or "H", d.aviso and "A" or "-" }
  for i = 1, #d.entradas do partes[#partes + 1] = "e" .. d.entradas[i].spellId end
  for i = 1, #d.props do partes[#partes + 1] = "p" .. d.props[i].spellId end
  for i = 1, #d.equivs do
    partes[#partes + 1] = "q" .. d.equivs[i].principal .. ">" .. d.equivs[i].spellId
  end
  d.clave = table.concat(partes, "|")
  return d
end

-- ------------------------------------------------------------- montaje -----

local function montar(d)
  local gui = AceGUI()
  local prev = A.UI.scrollActual(Pan.cuerpo)
  Pan.cuerpo:ReleaseChildren()
  Pan.filas = { entradas = {}, props = {}, equivs = {} }
  Pan.fijos = {}
  Pan.desplegables = {}

  -- Aviso de la cuenta partida: mejor decirlo que enseñar una lista vacía.
  if d.aviso then
    Pan.fijos.wAviso = gui:Create("Label")
    Pan.fijos.wAviso:SetFullWidth(true)
    Pan.cuerpo:AddChild(Pan.fijos.wAviso)
  end

  for i = 1, #d.entradas do
    Pan.filas.entradas[i] = crearFilaEntrada(Pan.cuerpo, d.entradas[i].spellId)
  end
  if #d.entradas == 0 then
    A.UI.etiqueta(Pan.cuerpo,
      "|cff808080La lista esta vacia. Anade buffs desde lo observado, abajo.|r", nil, true)
  end

  -- ------------------------------------------------------------ filtros ----
  local fila = gui:Create("SimpleGroup")
  fila:SetFullWidth(true); fila:SetLayout("Flow")

  local et1 = gui:Create("Label"); et1:SetWidth(60); et1:SetText("Ver:")
  fila:AddChild(et1)
  local fv = gui:Create("Dropdown")
  fv:SetWidth(170)
  fv:SetList({ propuestas = "Propuestas (grupo/raid)", duda = "Sin clasificar",
               fuera = "Descartadas", lista = "Ya en la lista" },
             { "propuestas", "duda", "fuera", "lista" })
  fv:SetValue(d.vista)
  fv:SetCallback("OnValueChanged", function(_, _, val)
    Pan.filtroVista = val; A.alCambiarEstado()
  end)
  apuntarDesplegable(fv)
  Pan.fijos.wVista = fv
  Pan.fijos.valVista = d.vista
  fila:AddChild(fv)

  local et2 = gui:Create("Label"); et2:SetWidth(60); et2:SetText("Clase:")
  fila:AddChild(et2)
  local fc = gui:Create("Dropdown")
  fc:SetWidth(150)
  fc:SetList(d.mapaC, d.ordenC)
  fc:SetValue(Pan.filtroClase or "")
  fc:SetCallback("OnValueChanged", function(_, _, val)
    Pan.filtroClase = val; A.alCambiarEstado()
  end)
  apuntarDesplegable(fc)
  Pan.fijos.wClase = fc
  Pan.fijos.claveClases = table.concat(d.ordenC, ",")
  Pan.fijos.valClase = Pan.filtroClase or ""
  fila:AddChild(fc)

  local fs = gui:Create("Button")
  fs:SetWidth(190)
  fs:SetCallback("OnClick", function() Pan.soloSesion = not Pan.soloSesion; A.alCambiarEstado() end)
  Pan.fijos.wSesion = fs
  fila:AddChild(fs)
  Pan.cuerpo:AddChild(fila)

  Pan.fijos.wTitulo = gui:Create("Heading")
  Pan.fijos.wTitulo:SetFullWidth(true)
  Pan.cuerpo:AddChild(Pan.fijos.wTitulo)

  for i = 1, #d.props do Pan.filas.props[i] = crearFilaPropuesta(Pan.cuerpo) end
  if d.vista ~= "lista" and #d.props == 0 then
    A.UI.etiqueta(Pan.cuerpo, "|cff808080nada que mostrar con este filtro.|r", nil, true)
  end

  -- Equivalencias PROPUESTAS de lo que ya esta en la lista, a confirmar una a
  -- una. Ninguna se aplica sola.
  local hq = gui:Create("Heading")
  hq:SetFullWidth(true)
  hq:SetText("Equivalencias propuestas (hay que confirmarlas)")
  Pan.cuerpo:AddChild(hq)
  for i = 1, #d.equivs do Pan.filas.equivs[i] = crearFilaEquiv(Pan.cuerpo) end
  if #d.equivs == 0 then
    A.UI.etiqueta(Pan.cuerpo, "|cff808080ninguna propuesta pendiente.|r", nil, true)
  end

  Pan.clave = d.clave
  A.UI.restaurarScroll(Pan.cuerpo, prev)
end

-- Escribe el contenido de las filas de la lista cerrada. Va POR spellId, no por
-- posición: durante un aplazamiento la lista puede haber crecido o encogido y
-- las filas montadas ya no cuadran uno a uno con las entradas. Cada fila se
-- pinta con SU entrada si sigue existiendo; una entrada nueva no tiene fila
-- todavía y no se puede inventar sin montar un widget —eso es lo que se aplaza—,
-- pero lo que hay en pantalla no se queda mintiendo.
local function pintarEntradas(d, puedeAnadir)
  local filas = Pan.filas and Pan.filas.entradas
  if not filas then return end
  local porId, tieneFila = {}, {}
  for i = 1, #d.entradas do porId[d.entradas[i].spellId] = d.entradas[i] end
  for i = 1, #filas do
    local f = filas[i]
    local e = f and f.spellId and porId[f.spellId]
    if e then
      tieneFila[f.spellId] = true
      pintarFilaEntrada(f, e, d.efectivos, d.mapaNombres, d.ordenNombres, d.porNombre)
    elseif f then
      -- Su entrada ya no está en la lista y todavía no se ha podido reconstruir.
      -- Antes que dejarla diciendo lo último que dijo, que lo diga.
      A.UI.poner(f, "tEt", f.wEt, "|cff808080(quitado de la lista)|r")
      A.UI.poner(f, "tEfectivo", f.wEfectivo, "")
      A.UI.poner(f, "tAviso", f.wAviso, "")
      f.efectivo = nil
    end
  end
  if not puedeAnadir then return end
  -- FILAS NUEVAS DURANTE UN APLAZAMIENTO. `AddChild` no libera nada: se puede
  -- añadir al final sin cerrarle el desplegable a nadie ni tocar el scroll. Van
  -- fuera de orden hasta la siguiente reconstrucción de verdad —que llega sola
  -- en cuanto el jugador cierre el menú, porque `Pan.clave` sigue siendo la
  -- vieja—, pero estar fuera de orden es infinitamente mejor que no estar.
  for i = 1, #d.entradas do
    local e = d.entradas[i]
    if not tieneFila[e.spellId] then
      local f = crearFilaEntrada(Pan.cuerpo, e.spellId)
      filas[#filas + 1] = f
      pintarFilaEntrada(f, e, d.efectivos, d.mapaNombres, d.ordenNombres, d.porNombre)
    end
  end
end

-- -------------------------------------------------------------- pintar -----

function Pan.refrescar()
  local gui = AceGUI()
  if not gui or not Pan.ventana or not Pan.cuerpo then return end
  if not Pan.puedeVer() then Pan.cerrar(); return end
  A.anotarRepintado("panel")

  local d = recopilar()

  -- Si hay una reconstrucción esperando a que el jugador cierre su desplegable,
  -- se dice. Un panel al que le faltan filas y no explica por qué parece roto, y
  -- un pullout de AceGUI no se cierra solo al pulsar fuera: puede quedarse
  -- abierto indefinidamente sin que nadie sepa que está bloqueando algo.
  local espera = ""
  if Pan.pendiente and (GetTime() - Pan.pendiente) >= A.APLAZO_AVISO then
    espera = " · |cffff8800hay filas nuevas esperando: cierra el desplegable|r"
  end
  A.UI.poner(Pan.fijos, "tCabecera", Pan.cabecera, string.format(
    "rev %d · digest %s · veo %d de %d (sin datos: %d) · con addon: %d · anunciante: %s%s%s",
    A.Estado.revMax(), A.Estado.digest(), d.vistos, d.total, d.sinDatos,
    A.Protocolo.companeros() + 1, tostring(A.Avisos.anunciante),
    A.Protocolo.hayIncompatibles() and " · |cffff8800hay clientes con otra version|r" or "",
    espera))

  if d.clave ~= Pan.clave then
    -- El jugador tiene un desplegable desplegado. Reconstruir se lo cerraría en
    -- la cara: se espera, y se espera sin plazo. En AceGUI un pullout no se
    -- cierra al hacer clic fuera (AceGUIWidget-DropDown.lua L375-390, L442-448,
    -- L508-512): sólo lo cierra volver a pulsar, elegir un item, perder el foco
    -- o ocultarse. Nada obliga al jugador a cerrarlo, y un desplegable vacío
    -- —el de perfiles cuando no hay ninguno guardado— se queda abierto sin que
    -- haya nada que elegir. Por eso lo que NO puede pasar es que esperar
    -- signifique mentir: lo de abajo mantiene el contenido al día igualmente.
    local t = GetTime()
    if Pan.hayAbierto() then
      Pan.pendiente = Pan.pendiente or t
      -- Las filas que ya existen se siguen actualizando, y las que faltan se
      -- AÑADEN al final: `AddChild` no libera nada, así que no le cierra el
      -- desplegable a nadie. Lo único que espera al menú es volver a poner las
      -- filas en orden y refrescar propuestas y equivalencias, y de eso avisa la
      -- cabecera.
      pintarEntradas(d, true)
      Pan.pintarPie(d)
      return
    end
    montar(d)
    Pan.pendiente = nil
  end

  if Pan.fijos.wAviso and d.aviso then
    A.UI.poner(Pan.fijos, "tAviso", Pan.fijos.wAviso, "|cffff8800" .. d.aviso .. "|r")
  end

  pintarEntradas(d)

  -- El desplegable de clase también se actualiza sólo si su lista ha cambiado,
  -- y nunca estando abierto: SetList hace pullout:Clear.
  if Pan.fijos.wClase and not Pan.fijos.wClase.open then
    local cc = table.concat(d.ordenC, ",")
    if Pan.fijos.claveClases ~= cc then
      Pan.fijos.claveClases = cc
      Pan.fijos.wClase:SetList(d.mapaC, d.ordenC)
      Pan.fijos.valClase = nil
    end
    local vc = Pan.filtroClase or ""
    if Pan.fijos.valClase ~= vc then Pan.fijos.valClase = vc; Pan.fijos.wClase:SetValue(vc) end
  end
  if Pan.fijos.wVista and not Pan.fijos.wVista.open and Pan.fijos.valVista ~= d.vista then
    Pan.fijos.valVista = d.vista
    Pan.fijos.wVista:SetValue(d.vista)
  end

  A.UI.poner(Pan.fijos, "tSesion", Pan.fijos.wSesion,
    Pan.soloSesion and "solo esta sesion" or "historico completo")

  -- El rotulo dice de verdad lo que se esta mirando: antes ponia "Observado en
  -- esta raid" y era el historico entero de SavedVariables, con carteles de
  -- "visto en 11" en una raid de dos.
  A.UI.poner(Pan.fijos, "tTitulo", Pan.fijos.wTitulo,
    d.vista == "lista" and "Buffs ya en la lista cerrada"
    or string.format("%s  ·  %s",
         (d.vista == "duda") and "Sin clasificar (el texto no permite decidir)"
         or (d.vista == "fuera") and "Apartadas (no parecen buffs de raid)"
         or "Propuestas de grupo o raid",
         Pan.soloSesion and "vistas en esta sesion" or "historico guardado"))

  for i = 1, #d.props do
    if Pan.filas.props[i] then pintarFilaPropuesta(Pan.filas.props[i], d.props[i]) end
  end

  for i = 1, #d.equivs do
    local f = Pan.filas.equivs[i]
    if f then
      local x = d.equivs[i]
      f.datos = x
      A.UI.poner(f, "tEt", f.wEt, string.format("%s  =  %s (%d) · %s",
        x.nombrePrincipal, x.nombre, x.spellId, x.motivo))
    end
  end

  Pan.pintarPie(d)
end

-- EL PIE SE CREA UNA VEZ. Antes se soltaba entero en cada repintado, y con él
-- la caja de texto de "guardar perfil": lo que estabas escribiendo se borraba
-- solo mientras escribías.
function Pan.crearPie()
  local gui = AceGUI()
  if not gui or not Pan.pie then return end
  Pan.pie:ReleaseChildren()
  Pan.piezas = {}

  local b1 = gui:Create("Button")
  b1:SetWidth(220)
  b1:SetText("Anunciar reparto a la raid")
  b1:SetCallback("OnClick", function() A.Avisos.anunciarReparto(); A.alCambiarEstado() end)
  Pan.pie:AddChild(b1)
  Pan.piezas.wAnunciar = b1

  local b2 = gui:Create("Button")
  b2:SetWidth(240)
  b2:SetText("Recordar por susurro a los asignados")
  b2:SetCallback("OnClick", function() A.Avisos.recordarPorSusurro() end)
  Pan.pie:AddChild(b2)

  local dp = gui:Create("Dropdown")
  dp:SetWidth(160)
  dp:SetCallback("OnValueChanged", function(_, _, val) A.Perfiles.cargar(val); A.alCambiarEstado() end)
  Pan.pie:AddChild(dp)
  Pan.piezas.wPerfiles = dp

  local eb = gui:Create("EditBox")
  if eb then
    eb:SetWidth(200)
    -- Etiqueta: la caja no se entendia para que era.
    if eb.SetLabel then eb:SetLabel("Guardar perfil con este nombre") end
    eb:SetText("")
    eb:SetCallback("OnEnterPressed", function(w, _, txt)
      if txt and txt ~= "" then A.Perfiles.guardar(txt); A.alCambiarEstado() end
    end)
    Pan.pie:AddChild(eb)
    Pan.piezas.wCaja = eb
  end
end

function Pan.pintarPie(d)
  if not Pan.piezas then return end
  A.UI.desactivar(Pan.piezas, "dAnunciar", Pan.piezas.wAnunciar,
                  A.Avisos.raidEnCombate() and true or false)
  local dp = Pan.piezas.wPerfiles
  if dp and not dp.open then
    local lista = (d and d.perfiles) or A.Perfiles.lista()
    local clave = table.concat(lista, ",")
    if Pan.piezas.clavePerfiles ~= clave then
      Pan.piezas.clavePerfiles = clave
      local mapa, orden = {}, {}
      for _, n in ipairs(lista) do mapa[n] = n; orden[#orden + 1] = n end
      dp:SetList(mapa, orden)
    end
  end
end
