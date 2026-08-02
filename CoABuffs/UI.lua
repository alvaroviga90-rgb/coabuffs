-- UI.lua — estilo WoW clásico compartido por las dos ventanas.
--
-- Marco oscuro con borde dorado, título centrado en serif, separadores tenues
-- entre filas y botones UIPanelButtonTemplate. Nada de rediseñar la interfaz
-- del juego: se usan las texturas y plantillas que ya trae el cliente.
--
-- Todo lo que toca frames en crudo va defendido: si una plantilla o un método
-- no existe, la ventana sale sin ese adorno pero NO revienta. Un addon que peta
-- al abrir una ventana se desinstala igual que uno que peta en raid.

local A = CoABuffs
local UI = {}
A.UI = UI

UI.FONDO = { r = 0.05, g = 0.05, b = 0.06, a = 0.94 }
UI.ORO   = { r = 0.72, g = 0.60, b = 0.28, a = 1 }

local function tiene(obj, metodo)
  return obj and type(obj[metodo]) == "function"
end

-- Saca el frame de verdad que hay debajo de un widget de AceGUI.
function UI.frameDe(widget)
  if not widget then return nil end
  return widget.frame or widget.content or nil
end

-- LO QUE SE PINTA SOBRE UN WIDGET DE AceGUI HAY QUE SABER DESHACERLO.
-- AceGUI recicla widgets desde un pool y `AceGUI:Release` (AceGUI-3.0.lua L206)
-- no limpia ni texturas ni fondos ni fuentes: lo que le pongamos a un frame se
-- queda pegado y se lo encuentra el siguiente addon que saque ese widget del
-- pool. Un fondo oscuro y un titulo dorado en serif apareciendo en la ventana de
-- DBM es culpa nuestra. Por eso: las texturas se REUTILIZAN por frame en vez de
-- crear una nueva cada vez (en WoW una textura no se puede destruir), y el
-- estilo se guarda al ponerlo y se devuelve al cerrar.
local estilos = {}

function UI.estilizarMarco(widget)
  local f = UI.frameDe(widget)
  if not tiene(f, "SetBackdrop") then return false end
  if tiene(f, "GetBackdrop") then
    estilos[f] = estilos[f] or {}
    if estilos[f].backdrop == nil then
      local ok0, bd = pcall(function() return f:GetBackdrop() end)
      estilos[f].backdrop = (ok0 and bd) or false
    end
  end
  local ok = pcall(function()
    f:SetBackdrop({
      bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 5, right = 5, top = 5, bottom = 5 },
    })
    f:SetBackdropColor(UI.FONDO.r, UI.FONDO.g, UI.FONDO.b, UI.FONDO.a)
    f:SetBackdropBorderColor(UI.ORO.r, UI.ORO.g, UI.ORO.b, UI.ORO.a)
  end)
  return ok
end

-- Título centrado en serif. La fuente es la del propio cliente.
function UI.estilizarTitulo(widget)
  local f = UI.frameDe(widget)
  local fs = widget and (widget.titletext or (f and f.titletext))
  if not tiene(fs, "SetFont") then return false end
  if f then
    estilos[f] = estilos[f] or {}
    if estilos[f].fuente == nil and tiene(fs, "GetFont") then
      local ok0, a, b, c = pcall(function() return fs:GetFont() end)
      estilos[f].fs = fs
      estilos[f].fuente = ok0 and a and { a, b, c } or false
      if tiene(fs, "GetTextColor") then
        local ok1, r, g, bb = pcall(function() return fs:GetTextColor() end)
        estilos[f].color = ok1 and { r, g, bb } or false
      end
    end
  end
  return pcall(function()
    fs:SetFont("Fonts\\MORPHEUS.TTF", 15)
    fs:SetTextColor(UI.ORO.r, UI.ORO.g, UI.ORO.b)
    if tiene(fs, "SetJustifyH") then fs:SetJustifyH("CENTER") end
  end)
end

-- Se llama ANTES de soltar la ventana. Devuelve el marco y el titulo a como
-- estaban, para que el widget vuelva al pool limpio.
function UI.desestilizar(widget)
  local f = UI.frameDe(widget)
  local e = f and estilos[f]
  if not e then return false end
  pcall(function()
    if e.backdrop ~= nil and tiene(f, "SetBackdrop") then
      f:SetBackdrop(e.backdrop or nil)
    end
    local fs = e.fs
    if fs and e.fuente and tiene(fs, "SetFont") then
      fs:SetFont(e.fuente[1], e.fuente[2], e.fuente[3])
    end
    if fs and e.color and tiene(fs, "SetTextColor") then
      fs:SetTextColor(e.color[1], e.color[2], e.color[3])
    end
  end)
  estilos[f] = nil
  return true
end

-- Separador tenue entre filas.
-- SE REUTILIZA POR FRAME. En WoW una textura no se puede destruir, y el frame
-- del SimpleGroup vuelve al pool de AceGUI con todo lo que le hayamos colgado:
-- crear una por cada reconstruccion de fila es una fuga sin techo, y la raya
-- reaparece luego en el SimpleGroup de otro addon. Si este frame ya tiene la
-- nuestra, se reaprovecha.
function UI.separador(widgetPadre)
  local f = UI.frameDe(widgetPadre)
  if not tiene(f, "CreateTexture") then return nil end
  if f.__coaSeparador then
    pcall(function() f.__coaSeparador:Show() end)
    return f.__coaSeparador
  end
  local t
  pcall(function()
    t = f:CreateTexture(nil, "ARTWORK")
    t:SetTexture("Interface\\Buttons\\WHITE8X8")
    t:SetVertexColor(1, 1, 1, 0.07)
    t:SetHeight(1)
    -- ABAJO del grupo, no al centro. Anclado a LEFT/RIGHT sin componente
    -- vertical, la textura cae en el centro del frame y CRUZA LOS NOMBRES por
    -- la mitad, que es lo que se veia en la vista del rango 0.
    t:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 4, 0)
    t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 0)
  end)
  if t then f.__coaSeparador = t end
  return t
end

-- Tooltip con el spellId. El icono y el id ya los tenemos de UnitBuff; no se
-- consulta nada al servidor.
function UI.tooltip(widget, titulo, lineas)
  if not tiene(widget, "SetCallback") then return end
  widget:SetCallback("OnEnter", function()
    if not GameTooltip then return end
    pcall(function()
      GameTooltip:SetOwner(UI.frameDe(widget) or UIParent, "ANCHOR_RIGHT")
      GameTooltip:AddLine(titulo, 1, 0.82, 0)
      for i = 1, #(lineas or {}) do GameTooltip:AddLine(lineas[i], 0.8, 0.8, 0.8) end
      GameTooltip:Show()
    end)
  end)
  widget:SetCallback("OnLeave", function()
    if GameTooltip then pcall(function() GameTooltip:Hide() end) end
  end)
end

-- Área con scroll dentro de un contenedor, con alto fijo para que el pie no
-- flote entre las filas. El .toc ya cargaba AceGUIContainer-ScrollFrame y no lo
-- montaba nadie: éste es el sitio.
function UI.areaScroll(contenedor, alto)
  local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
  if not AceGUI then return nil end
  local sc = AceGUI:Create("ScrollFrame")
  sc:SetLayout("List")
  sc:SetFullWidth(true)
  if tiene(sc, "SetHeight") then sc:SetHeight(alto or 360) end
  contenedor:AddChild(sc)
  return sc
end

-- ----------------------------------------------- refresco sin reconstruir ---
--
-- REFRESCAR NO ES RECONSTRUIR. `ReleaseChildren()` devuelve los widgets al pool
-- de AceGUI y crea otros nuevos, y eso tiene dos efectos que en juego hacen la
-- ventana inusable:
--
--   * el scroll salta arriba. Al soltar los hijos, el contenido se queda sin
--     alto; `AceGUIContainer-ScrollFrame.lua` L99-109 esconde la barra y le pone
--     valor 0, y L74 escribe `status.scrollvalue = 0`. La posicion se pierde.
--   * el desplegable abierto se cierra. `AceGUI:Release` (AceGUI-3.0.lua L206)
--     llama al `OnRelease` del Dropdown, que hace `pullout:Close()`
--     (AceGUIWidget-DropDown.lua L471-474). Y aunque no se libere, `SetList`
--     hace `pullout:Clear()` (L614-619): si esta abierto, le vacia la lista al
--     jugador en la cara.
--
-- Por eso las dos ventanas montan la estructura UNA VEZ y en cada repintado
-- solo escriben textos y estados sobre los widgets que ya existen. Estas tres
-- ayudas son lo que hace falta para eso.

-- Valor de scroll actual (0-1000), o nil si no se puede saber.
function UI.scrollActual(sc)
  if not sc then return nil end
  local st = sc.status or sc.localstatus
  if type(st) == "table" and st.scrollvalue then return st.scrollvalue end
  return sc.scrollvalue
end

-- Devuelve el scroll a donde estaba. Solo hace falta cuando la ESTRUCTURA
-- cambia de verdad (el RL mete un buff nuevo, cambia el filtro) y no queda mas
-- remedio que reconstruir. Va detras del ultimo AddChild, con el alto ya
-- calculado: el FixScroll diferido recalcula desde `status.offset`, que es lo
-- que deja puesto SetScroll.
function UI.restaurarScroll(sc, v)
  if not sc or not v or v <= 0 then return end
  pcall(function()
    if type(sc.SetScroll) == "function" then sc:SetScroll(v) end
    if sc.scrollbar and type(sc.scrollbar.SetValue) == "function" then
      sc.scrollbar:SetValue(v)
    end
  end)
end

-- Registro de desplegables de una ventana. Se rehace en cada reconstruccion.
function UI.algunoAbierto(lista)
  for i = 1, #(lista or {}) do
    local d = lista[i]
    if d and d.open then return true end
  end
  return false
end

-- Escribe solo si cambia, y el cacheo vive en NUESTRA tabla de fila, nunca
-- pegado al widget: AceGUI recicla widgets desde un pool y un campo pegado
-- sobrevive al reciclado, asi que compararíamos contra el texto de otra fila.
function UI.poner(fila, campo, w, txt)
  if not w then return end
  txt = txt or ""
  if fila[campo] ~= txt then fila[campo] = txt; w:SetText(txt) end
end

function UI.desactivar(fila, campo, w, si)
  if not w or type(w.SetDisabled) ~= "function" then return end
  si = si and true or false
  if fila[campo] ~= si then fila[campo] = si; w:SetDisabled(si) end
end

function UI.etiqueta(padre, texto, ancho, completo)
  local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
  if not AceGUI then return nil end
  local l = AceGUI:Create("Label")
  if completo then l:SetFullWidth(true) elseif ancho then l:SetWidth(ancho) end
  l:SetText(texto or "")
  padre:AddChild(l)
  return l
end
