-- Clasificador.lua — TRES CAJONES, nunca uno.
--
-- Un buff de raid tirado a la basura es el falso negativo que no nos podemos
-- permitir. Así que aquí no se descarta nada en silencio: se APARTA.
--
--   GRUPO  el texto dice a quién llega (party and raid members, nearby allies,
--          all allies...). Salen por defecto en el configurador.
--   FUERA  el texto sólo habla de "your"/"you"; o empieza por "This item"; o lo
--          que modifica no es de combate (experience gain, reputation gain); o
--          dura días.
--   DUDA   el texto no permite decidir. No ensucian la lista principal pero
--          están a un clic: ahí acabarán los custom con redacción rara, y ahí
--          es donde el RL los rescata.
--
-- EL ORDEN IMPORTA. "Aura of Reputation" dice "your entire party" y "Aura of
-- Experience" dice "you and your entire party": un filtro por palabra clave a
-- secas los deja entrar. Por eso las reglas de FUERA se evalúan ANTES, y hacen
-- falta varias señales combinadas, no una.

local A = CoABuffs
local K = {}
A.Clasificador = K

K.GRUPO = "grupo"
K.FUERA = "fuera"
K.DUDA  = "duda"

-- Señales de que el efecto alcanza a más gente que a uno mismo.
local ALCANCE = {
  "party and raid members", "raid and party members",
  "party and raid", "raid and party",
  "raid members", "party members",
  "nearby allies", "nearby party", "nearby raid", "nearby friendly",
  "all allies", "your allies", "allies within", "friendly targets",
  "group members", "all party", "entire raid", "entire party",
  "your party", "your group", "your raid", "all raid",
}

-- Señales de que NO es un buff de raid, por mucho que mencione al grupo.
local NO_COMBATE = {
  "experience gain", "reputation gain", "bonus experience",
  "honor gain", "gold from", "loot",
}

local function tiene(txt, lista)
  for i = 1, #lista do
    if txt:find(lista[i], 1, true) then return lista[i] end
  end
  return nil
end

-- Devuelve cajon, motivo. El motivo se enseña en el panel: si el RL no entiende
-- por que algo esta donde esta, no lo va a rescatar.
function K.clasificar(spellId, textoDado)
  local txt = textoDado or (A.Tooltip and A.Tooltip.textoDe(spellId))
  if not txt or txt == "" then
    return K.DUDA, "sin texto de tooltip"
  end
  local t = txt:lower()

  -- 1. Objetos y consumibles con instrucciones de uso.
  if t:match("^this item") then
    return K.FUERA, "el texto empieza por \"This item\""
  end

  -- 2. Lo que modifica no es de combate.
  local nc = tiene(t, NO_COMBATE)
  if nc then
    return K.FUERA, string.format("modifica %q, no es un buff de combate", nc)
  end

  -- 3. ¿Dice a quien llega? VA ANTES QUE LA DURACION, y esto costo caro:
  -- los cinco buffs de raid canonicos de 3.3.5a (Gift of the Wild, Prayer of
  -- Fortitude, Arcane Brilliance, Blessing of Kings, Prayer of Shadow
  -- Protection) dicen "for 1 hour", y con la regla de duracion delante los
  -- cinco caian en "fuera". Es el falso negativo que este fichero dice no
  -- poder permitirse, y afectaba a TODOS los buffs de raid, no a un caso raro.
  -- El fixture no lo veia porque ninguno de sus siete textos lleva "hour".
  local al = tiene(t, ALCANCE)
  if al then
    return K.GRUPO, string.format("el texto dice %q", al)
  end

  -- 4. Duracion larga sin alcance de grupo: eso no es un buff de pull.
  if t:match("lasts%s+[%d%.%s%w]-day") or t:match("for%s+[%d%.%s%w]-day") then
    return K.FUERA, "dura dias, no es un buff de raid"
  end

  -- 5. Solo habla de uno mismo.
  if (t:find("your", 1, true) or t:find("you ", 1, true)) then
    return K.FUERA, "el texto solo habla de \"you\"/\"your\""
  end

  return K.DUDA, "el texto no dice a quien llega"
end

-- Duracion corta declarada en el texto (segundos). Sirve de senal auxiliar: un
-- buff de raid dura minutos, un racial dura segundos. NO decide por si sola.
function K.duracionSegundos(txt)
  if not txt then return nil end
  local t = txt:lower()
  local s = t:match("for%s+(%d+)%s*sec") or t:match("lasts%s+(%d+)%s*sec")
  if s then return tonumber(s) end
  local m = t:match("for%s+(%d+)%s*min") or t:match("lasts%s+(%d+)%s*min")
  if m then return tonumber(m) * 60 end
  return nil
end
