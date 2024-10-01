--!native
--!optimize 2
--!strict

type SparseSet<T> = {
    dense: { [number]: EntityId },
    sparse: { [EntityId]: number }, 
    data: { [number]: T },
}
type EntityId = number
type ComponentId = number
type ArchetypeId = number
type Edge = {
    fromArchetype: Archetype,
    toArchetype: Archetype,
    component: ComponentId
}
type Archetype = {
    bitmask: number,
    componentData: { [ComponentId]: SparseSet<any> },
    entities: { [number]: EntityId },
    addEdges: { [ComponentId]: Edge },
    removeEdges: { [ComponentId]: Edge },
    entityCount: number,
    entityRow: { [EntityId]: number },
}


local ENTITY_FLAG: number = 0xFFFFFFFF
local GENERATION_FLAG: number = 0xFFFFFFFF

local Centix = {}
Centix.__index = Centix

type Centix = typeof(setmetatable({
    _archetypeIndex = {} :: { [number]: Archetype },
    _entityIndex = {} :: { [EntityId]: Archetype },
    _freeLists = {} :: { { number } },
    _generations = {} :: { [EntityId]: number },
    _nextId = 1 :: number, 
    _pendingTransitions = {} :: { { Entity: EntityId, Component: ComponentId, Add: boolean } }
}, Centix))

function Centix.New(): Centix
    local self = setmetatable({}, Centix)
    self._archetypeIndex = {}
    self._entityIndex = {}
    self._freeLists = {}
    self._generations = {}
    self._nextId = 1
    self._pendingTransitions = {}
    return self
end

function Centix.Entity(self: Centix): EntityId
    local entityId: EntityId
    local generation: number

    if #self._freeLists > 0 then
        local freeEntry = table.remove(self._freeLists) :: { number }
        entityId, generation = table.unpack(freeEntry)
        generation += 1
        self._generations[entityId] = generation
    else
        entityId = self._nextId
        self._nextId += 1
        generation = 0
        self._generations[entityId] = generation
    end

    return bit32.bor(bit32.lshift(generation, GENERATION_FLAG), entityId)
end

function Centix.Despawn(self: Centix, encodedId: EntityId): ()
    local entityId: number = bit32.band(encodedId, ENTITY_FLAG)
    local archetype: Archetype? = self._entityIndex[entityId]

    if archetype then
        local row = archetype.entityRow[entityId]
        archetype.entities[row] = archetype.entities[archetype.entityCount]
        archetype.entities[archetype.entityCount] = nil
        archetype.entityCount -= 1

        for componentId = 1, #archetype.componentData do
            local sparseSet = archetype.componentData[componentId]
            if sparseSet then
                local lastRow = archetype.entityCount + 1
                sparseSet.dense[row] = sparseSet.dense[lastRow]
                sparseSet.data[row] = sparseSet.data[lastRow]

                local movedEntity = sparseSet.dense[row]
                sparseSet.sparse[movedEntity] = row

                sparseSet.dense[lastRow] = nil
                sparseSet.data[lastRow] = nil
            end
        end

        archetype.entityRow[entityId] = nil

        if archetype.entityCount == 0 then
            self._archetypeIndex[archetype.bitmask] = nil
        end

        self._entityIndex[entityId] = nil
    end

    self._freeLists[#self._freeLists + 1] = { entityId, self._generations[entityId] }
end

local function IsEntityValid(self: Centix, encodedId: EntityId): boolean
    local entityId: number = bit32.band(encodedId, ENTITY_FLAG)
    local generation: number = bit32.rshift(encodedId, GENERATION_FLAG)
    return self._generations[entityId] == generation
end

local function ArchetypeTransition(self: Centix, entity: EntityId, component: ComponentId, add: boolean): Archetype
    local currentArchetype: Archetype = self._entityIndex[entity]
    local newBitmask: number = add and bit32.bor(currentArchetype.bitmask, bit32.lshift(1, component - 1)) or bit32.band(currentArchetype.bitmask, bit32.bnot(bit32.lshift(1, component - 1)))

    local edge = add and currentArchetype.addEdges[component] or currentArchetype.removeEdges[component]
    if edge then
        return edge.toArchetype
    end

    local newArchetype = self._archetypeIndex[newBitmask]
    if not newArchetype then
        newArchetype = {
            bitmask = newBitmask,
            componentData = {},
            entities = {},
            addEdges = {},
            removeEdges = {},
            entityCount = 0,
            entityRow = {}
        }
        self._archetypeIndex[newBitmask] = newArchetype
    end

    local newEdge = { fromArchetype = currentArchetype, toArchetype = newArchetype, component = component }
    if add then
        currentArchetype.addEdges[component] = newEdge
    else
        currentArchetype.removeEdges[component] = newEdge
    end

    return newArchetype
end

function Centix.RegisterComponent<T>(self: Centix, entity: EntityId, component: ComponentId, data: T): Centix
    if not IsEntityValid(self, entity) then
        error("[Centix]: Invalid entity reference", 0)
    end

    local currentArchetype = self._entityIndex[entity]
    if not currentArchetype then
        currentArchetype = {
            bitmask = 0,
            componentData = {},
            entities = {},
            addEdges = {},
            removeEdges = {},
            entityCount = 0,
            entityRow = {}
        }
        self._entityIndex[entity] = currentArchetype
    end

    local sparseSet = currentArchetype.componentData[component]
    if not sparseSet then
        sparseSet = { dense = {}, sparse = {}, data = {} }
        currentArchetype.componentData[component] = sparseSet
    end

    local row = currentArchetype.entityRow[entity]
    if row then
        sparseSet.data[row] = data
        return self
    end

    local newArchetype = ArchetypeTransition(self, entity, component, true)
   	local rows = newArchetype.entityCount + 1
    sparseSet.dense[rows] = entity
    sparseSet.sparse[entity] = rows
    sparseSet.data[rows] = data
    newArchetype.entities[rows] = entity
    newArchetype.entityRow[entity] = row
    newArchetype.entityCount += 1

    self._entityIndex[entity] = newArchetype
    return self
end

function Centix.RemoveComponent(self: Centix, entity: EntityId, component: ComponentId): Centix
    if not IsEntityValid(self, entity) then
        error("[Centix]: Invalid entity reference", 0)
    end

    local currentArchetype = self._entityIndex[entity]
    local sparseSet = currentArchetype.componentData[component]
    local row = sparseSet.sparse[entity]
    if not row then
		return self 
	end

    local lastRow = currentArchetype.entityCount
    sparseSet.dense[row] = sparseSet.dense[lastRow]
    sparseSet.data[row] = sparseSet.data[lastRow]

    local movedEntity = sparseSet.dense[row]
    sparseSet.sparse[movedEntity] = row

    sparseSet.dense[lastRow] = nil
    sparseSet.data[lastRow] = nil
    sparseSet.sparse[entity] = nil

    currentArchetype.entityCount -= 1

    local newArchetype = ArchetypeTransition(self, entity, component, false)
    row = newArchetype.entityCount + 1
    newArchetype.entities[row] = entity
    newArchetype.entityRow[entity] = row
    newArchetype.entityCount += 1

    self._entityIndex[entity] = newArchetype
    return self
end

function Centix.HasComponent(self: Centix, entity: EntityId, component: ComponentId): boolean
	if not IsEntityValid(self, entity) then
		error("[Centix]: Invalid entity reference", 0)
	end	
	return self._archetypeIndex[component] ~= nil and self._archetypeIndex[component]["entities"][entity] ~= nil
end

return Centix.New()