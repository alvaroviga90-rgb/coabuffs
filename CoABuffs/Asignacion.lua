-- Asignacion.lua — de asignado nominal a asignado efectivo.
--
-- CLAVE DEL DISEÑO: la reasignación NO se negocia por el cable. Es una función
-- determinista del estado replicado (la lista) y del roster (que todos los
-- clientes ven igual gracias a GetRaidRosterInfo, que devuelve TODO el roster
-- sin necesidad de tener a nadie en rango). Mismos datos + misma función =
-- mismo resultado en los 25 clientes, sin mandar un solo byte.
--
-- Si esto se resolviera hablando, cada muerte en un pull dispararía una ronda
-- de mensajes de 25 clientes con el presupuesto ya comido por DBM, y encima
-- habría que resolver los empates. Así no hay ronda, no hay empate y no hay
-- gasto.

local A = CoABuffs
local Asig = {}
A.Asignacion = Asig

-- Quién puede poner este buff. Sale del catálogo (clases a las que se ha VISTO
-- ponerlo), nunca de una tabla por clase escrita a mano.
function Asig.elegibles(entrada, lista)
  local clases = A.Catalogo.clasesQueLoPonen(entrada.spellId, entrada.equiv)
  local out = {}
  for i = 1, #lista do
    local e = lista[i]
    -- En CoA dos jugadores de la misma clase NO llevan las mismas habilidades.
    -- Buscar "otro de la misma clase" puede asignar algo imposible, así que
    -- quien ha declarado que no lo tiene queda fuera. Es el único que lo sabe.
    if A.Escaner.presente(e) and e.token and clases[e.token]
       and not A.Declaraciones.noLoTiene(e.nombre, entrada.spellId) then
      out[#out + 1] = e.nombre
    end
  end
  return out
end

-- ¿Sigue disponible el asignado nominal? "Ha cambiado de personaje" se detecta
-- por GUID: mismo nombre y distinto GUID no es la misma persona.
local function disponible(entrada, ficha)
  if not ficha then return false end
  if not A.Escaner.presente(ficha) then return false end
  if entrada.guid and ficha.guid and entrada.guid ~= ficha.guid then return false end
  -- Que el RL te haya asignado no te da el hechizo. Si has declarado que no lo
  -- tienes, el relevo salta también sobre la asignación nominal.
  if A.Declaraciones.noLoTiene(ficha.nombre, entrada.spellId) then return false end
  return true
end

-- Devuelve { [spellId] = nombreEfectivo }.
-- Recorre en orden fijo (spellId ascendente).
--
-- UNA PERSONA PUEDE PONER VARIOS BUFFS, y el RL se los da a propósito. La regla
-- de "no repetir persona" existe para repartir el trabajo cuando el addon elige
-- SOLO —que dos relevos automáticos no caigan encima del mismo—, no para
-- quitarle al asignado nominal los buffs que le han dado.
--
-- Aquí había un fallo medido en juego: `not usados[e.asignado]` se aplicaba
-- también al asignado nominal, así que con Elaryyon asignado a tres buffs se
-- quedaba con el primero y los otros dos saltaban a otra persona —y el susurro
-- se iba con ellos, al que no tenía que ponerlos—. Un nominal DISPONIBLE
-- conserva todos los suyos, cuenten lo que cuenten los demás. El relevo sólo
-- entra por indisponibilidad de verdad, que es lo que decide `disponible()`:
-- ausente, muerto, cambiado de personaje o ha declarado que no lo tiene.
function Asig.derivar(lista, porNombre)
  local res, usados, motivo = {}, {}, {}
  local ids = A.Estado.lista()

  -- PRIMERA PASADA: se RESERVAN todos los nominales disponibles, de toda la
  -- lista, antes de resolver un solo relevo.
  --
  -- Sin esto, el recorrido por spellId ascendente hacia que un relevo de un buff
  -- de id bajo se llevara por delante al nominal de uno de id alto: con tres
  -- WILDWALKER (P03 nominal del buff bajo, P07 del alto, P19 libre), al morir
  -- P03 el relevo cogia a P07 —que todavia no estaba en `usados` porque su buff
  -- no se habia mirado— y P07 acababa cargando con los dos mientras P19 estaba
  -- sin nada. Es el mismo defecto que el de juego, del reves: en vez de quitarle
  -- buffs al nominal, se los amontona a otro nominal.
  for i = 1, #ids do
    local e = A.Estado.get(ids[i])
    if e.estado == A.REQ and e.asignado
       and disponible(e, porNombre[e.asignado]) then
      usados[e.asignado] = true
    end
  end

  for i = 1, #ids do
    local e = A.Estado.get(ids[i])
    if e.estado == A.REQ then
      local elegido, por
      local ficha = e.asignado and porNombre[e.asignado]
      if e.asignado and disponible(e, ficha) then
        elegido, por = e.asignado, "nominal"
      else
        local cand = Asig.elegibles(e, lista)
        for k = 1, #cand do
          if not usados[cand[k]] then elegido = cand[k]; break end
        end
        if elegido then
          por = e.asignado and "relevo" or "auto"
        elseif #cand > 0 then
          -- No hay nadie libre: se dobla antes que dejar el buff huérfano.
          elegido, por = cand[1], "doblado"
        end
      end
      if elegido then usados[elegido] = true end
      res[ids[i]] = elegido
      motivo[ids[i]] = por
    end
  end
  return res, motivo
end
