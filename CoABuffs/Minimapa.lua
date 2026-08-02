-- Minimapa.lua — botón en el minimapa, a mano.
--
-- Sin LibDBIcon ni ninguna otra librería: es media pantalla de código y la regla
-- dice cero dependencias nuevas. Lo único que hace falta es colocar un botón en
-- un círculo alrededor del minimapa y dejar arrastrarlo.
--
-- La posición se guarda por PERSONAJE en SavedVariables: es preferencia local y
-- no viaja por la red, como todo lo de la vista.
--
-- Lo ven todos. Lo que ABRE depende del rango, y esa decisión no está aquí: se
-- delega en Core, que es quien sabe quién manda.

local A = CoABuffs
local M = {}
A.Minimapa = M

M.boton = nil
M.RADIO = 80          -- radio del círculo del minimapa en 3.3.5a

local function guardado()
  CoABuffsDB = CoABuffsDB or {}
  CoABuffsDB.ui = CoABuffsDB.ui or {}
  CoABuffsDB.ui.minimapa = CoABuffsDB.ui.minimapa or { angulo = 200, oculto = false }
  return CoABuffsDB.ui.minimapa
end

local function colocar(b, angulo)
  local rad = math.rad(angulo)
  local x = math.cos(rad) * M.RADIO
  local y = math.sin(rad) * M.RADIO
  pcall(function()
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", x, y)
  end)
end

-- Ángulo del cursor respecto al centro del minimapa, para el arrastre.
local function anguloDelCursor()
  if not GetCursorPosition or not Minimap then return nil end
  local ok, ang = pcall(function()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local escala = Minimap:GetEffectiveScale()
    px, py = px / escala, py / escala
    return math.deg(math.atan2(py - my, px - mx))
  end)
  return ok and ang or nil
end

function M.crear()
  if M.boton then return M.boton end
  if not Minimap or not CreateFrame then return nil end
  local g = guardado()

  local b
  local ok = pcall(function()
    b = CreateFrame("Button", "CoABuffsMinimapaBoton", Minimap)
    b:SetWidth(31); b:SetHeight(31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    local icono = b:CreateTexture(nil, "BACKGROUND")
    icono:SetWidth(20); icono:SetHeight(20)
    icono:SetTexture("Interface\\Icons\\Spell_Holy_GreaterBlessingofKings")
    icono:SetPoint("CENTER", b, "CENTER", 0, 1)
    b.icono = icono

    local borde = b:CreateTexture(nil, "OVERLAY")
    borde:SetWidth(53); borde:SetHeight(53)
    borde:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    borde:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)

    b:SetScript("OnDragStart", function(self)
      self.arrastrando = true
      self:SetScript("OnUpdate", function(s)
        local ang = anguloDelCursor()
        if ang then g.angulo = ang; colocar(s, ang) end
      end)
    end)
    b:SetScript("OnDragStop", function(self)
      self.arrastrando = nil
      self:SetScript("OnUpdate", nil)
    end)
    b:SetScript("OnClick", function(self, boton)
      A.abrirVistaPropia(boton == "RightButton")
    end)
    b:SetScript("OnEnter", function(self)
      if not GameTooltip then return end
      pcall(function()
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(A.NOMBRE, 1, 0.82, 0)
        GameTooltip:AddLine("Clic: abrir el reparto", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Clic derecho: vista por jugador", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Arrastrar: mover por el minimapa", 0.8, 0.8, 0.8)
        GameTooltip:Show()
      end)
    end)
    b:SetScript("OnLeave", function()
      if GameTooltip then pcall(function() GameTooltip:Hide() end) end
    end)
  end)

  if not ok or not b then return nil end
  M.boton = b
  colocar(b, g.angulo or 200)
  if g.oculto then pcall(function() b:Hide() end) end
  return b
end

function M.alternarVisible()
  local g = guardado()
  g.oculto = not g.oculto
  if M.boton then
    pcall(function() if g.oculto then M.boton:Hide() else M.boton:Show() end end)
  end
  A.log("boton del minimapa %s.", g.oculto and "oculto" or "visible")
end
