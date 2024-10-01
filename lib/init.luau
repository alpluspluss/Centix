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
    entityRow: { [EntityId]: number }
}

local ENTITY_MASK: number = 0x00FFFFFF
local GENERATION_SHIFT: number = 0x18

local Centix = {}
Centix.__index = Centix

type Centix = typeof(setmetatable({
    _archetypeIndex = {} :: { [number]: Archetype },
    _entityIndex = {} :: { [EntityId]: Archetype },
    _freeList = {} :: { EntityId },
    _generations = {} :: { [EntityId]: number },
    _nextId = 1 :: EntityId,
}, Centix))

function Centix.new(): Centix
    local self = setmetatable({}, Centix)
    self._archetypeIndex = {}
    self._entityIndex = {}
    self._freeList = {}
    self._generations = {}
    self._nextId = 1
    return self
end

function Centix.Entity(self: Centix): EntityId
    local entityId: EntityId
    local generation: number

    if #self._freeList > 0 then
        entityId = table.remove(self._freeList) :: number
        generation = self._generations[entityId] + 1
    else
        entityId = self._nextId
        self._nextId += 1
        generation = 0
    end

    self._generations[entityId] = generation
    return bit32.bor(bit32.lshift(generation, GENERATION_SHIFT), entityId)
end

function Centix.Despawn(self: Centix, encodedId: EntityId): ()
    local entityId = bit32.band(encodedId, ENTITY_MASK)
    local archetype = self._entityIndex[entityId]

    if archetype then
        local row = archetype.entityRow[entityId]
        local lastEntity = archetype.entities[archetype.entityCount]
        archetype.entities[row] = lastEntity
        archetype.entities[archetype.entityCount] = nil
        archetype.entityCount -= 1

        for _, sparseSet in archetype.componentData do
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

    self._freeList[#self._freeList + 1] = entityId
end

local function __IsEntityValid(self: Centix, encodedId: EntityId): boolean
    local entityId = bit32.band(encodedId, ENTITY_MASK)
    local generation = bit32.rshift(encodedId, GENERATION_SHIFT)
    return self._generations[entityId] == generation
end

local function ArchetypeTransition(self: Centix, entity: EntityId, component: ComponentId, add: boolean): Archetype
    local currentArchetype = self._entityIndex[entity]
    local edgeTable = add and currentArchetype.addEdges or currentArchetype.removeEdges
    local newArchetype: Archetype

    local edge = edgeTable[component]
    if edge then
        return edge.toArchetype
    end

    local newBitmask = add and bit32.bor(currentArchetype.bitmask, bit32.lshift(1, component - 1)) or
        bit32.band(currentArchetype.bitmask, bit32.bnot(bit32.lshift(1, component - 1)))

    newArchetype = self._archetypeIndex[newBitmask]
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
    edgeTable[component] = newEdge

    return newArchetype
end

function Centix.RegisterComponent<T>(self: Centix, entity: EntityId, component: ComponentId, data: T): Centix
    if not __IsEntityValid(self, entity) then
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
    local newRow = newArchetype.entityCount + 1
    sparseSet.dense[newRow] = entity
    sparseSet.sparse[entity] = newRow
    sparseSet.data[newRow] = data
    newArchetype.entities[newRow] = entity
    newArchetype.entityRow[entity] = newRow
    newArchetype.entityCount += 1

    self._entityIndex[entity] = newArchetype
    return self
end

function Centix.RemoveComponent(self: Centix, entity: EntityId, component: ComponentId): Centix
    if not __IsEntityValid(self, entity) then
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

return Centix.new()
