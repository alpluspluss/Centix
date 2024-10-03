--!native
--!optimize 2
--!strict

type EntityId = number
type ComponentId = number

local ENTITY_MASK: number = 0x00FFFFFF
local GENERATION_SHIFT: number = 0x18

local Centix = {}
Centix.__index = Centix

type Storage<T> = {
    dense: { [number]: EntityId },
    sparse: { [EntityId]: number },
    data: { [number]: T },
}

type RelationshipRegistry = {
    nextId: number,
    relationships: { [ComponentId]: string },
}

type RelationshipSet = Storage<{ [EntityId]: boolean }>

type Centix = typeof(setmetatable({
    _archetypeIndex = {} :: { [number]: { [ComponentId]: any } },
    _entityIndex = {} :: { [EntityId]: any },
    _freeList = {} :: { EntityId },
    _generations = {} :: { [EntityId]: number },
    _nextId = 1 :: EntityId,
    _relationshipRegistry = { nextId = 1, relationships = {} } :: RelationshipRegistry,
    _relationshipSets = {} :: { [ComponentId]: RelationshipSet }
}, Centix))

function Centix.new(): Centix
    local self = setmetatable({}, Centix)
    self._archetypeIndex = {}
    self._entityIndex = {}
    self._freeList = {}
    self._generations = {}
    self._nextId = 1
    self._relationshipRegistry = { nextId = 1, relationships = {} }
    self._relationshipSets = {}
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

        for _, componentArray in archetype.componentData do
            local lastRow = archetype.entityCount + 1
            componentArray[row] = componentArray[lastRow]
            local movedEntity = archetype.entities[row]
            archetype.entityRow[movedEntity] = row
            componentArray[lastRow] = nil
        end

        archetype.entityRow[entityId] = nil

        if archetype.entityCount == 0 then
            self._archetypeIndex[archetype.bitmask] = nil
        end

        self._entityIndex[entityId] = nil
    end

    self._freeList[#self._freeList + 1] = entityId
end

local function __ArchetypeTransition(self: Centix, entity: EntityId, component: ComponentId, add: boolean): any
    local currentArchetype = self._entityIndex[entity]
    local newBitmask = add and bit32.bor(currentArchetype.bitmask, bit32.lshift(1, component - 1)) or
        bit32.band(currentArchetype.bitmask, bit32.bnot(bit32.lshift(1, component - 1)))

    local newArchetype = self._archetypeIndex[newBitmask]
    if not newArchetype then
        newArchetype = {
            bitmask = newBitmask,
            componentData = {},
            entities = {},
            entityCount = 0,
            entityRow = {}
        }
        self._archetypeIndex[newBitmask] = newArchetype
    end
    return newArchetype
end

function Centix.RegisterComponent<T>(self: Centix, entity: EntityId, component: ComponentId, data: T): Centix
    local entityId = bit32.band(entity, ENTITY_MASK)
    local generation = bit32.rshift(entity, GENERATION_SHIFT)
    if self._generations[entityId] ~= generation then
        error("[Centix]: Invalid entity reference", 0)
    end

    local currentArchetype = self._entityIndex[entity]
    if not currentArchetype then
        currentArchetype = {
            bitmask = 0,
            componentData = {},
            entities = {},
            entityCount = 0,
            entityRow = {}
        }
        self._entityIndex[entity] = currentArchetype
    end

    local componentArray = currentArchetype.componentData[component]
    if not componentArray then
        componentArray = {}
        currentArchetype.componentData[component] = componentArray
    end

    local row = currentArchetype.entityRow[entity]
    if row then
        componentArray[row] = data
    else
        local newArchetype = __ArchetypeTransition(self, entity, component, true)
        local newRow = newArchetype.entityCount + 1
        componentArray[newRow] = data
        newArchetype.entities[newRow] = entity
        newArchetype.entityRow[entity] = newRow
        newArchetype.entityCount += 1
        self._entityIndex[entity] = newArchetype
    end

    return self
end

function Centix.RemoveComponent(self: Centix, entity: EntityId, component: ComponentId): Centix
    local entityId = bit32.band(entity, ENTITY_MASK)
    local generation = bit32.rshift(entity, GENERATION_SHIFT)
    if self._generations[entityId] ~= generation then
        error("[Centix]: Invalid entity reference", 0)
    end

    local currentArchetype = self._entityIndex[entity]
    local componentArray = currentArchetype.componentData[component]
    local row = currentArchetype.entityRow[entity]
    if not row then
        return self
    end

    local lastRow = currentArchetype.entityCount
    componentArray[row] = componentArray[lastRow]

    local movedEntity = currentArchetype.entities[row]
    currentArchetype.entityRow[movedEntity] = row

    componentArray[lastRow] = nil
    currentArchetype.entityCount -= 1

    local newArchetype = __ArchetypeTransition(self, entity, component, false)
    local newRow = newArchetype.entityCount + 1
    newArchetype.entities[newRow] = entity
    newArchetype.entityRow[entity] = newRow
    newArchetype.entityCount += 1

    self._entityIndex[entity] = newArchetype
    return self
end

function Centix.RegisterRelationship(self: Centix, name: string): ComponentId
    local relationshipId = self._relationshipRegistry.nextId
    self._relationshipRegistry.relationships[relationshipId] = name
    self._relationshipRegistry.nextId += 1
    self._relationshipSets[relationshipId] = { dense = {}, sparse = {}, data = {} }
    return relationshipId
end

function Centix.AddRelationship(self: Centix, entity1: EntityId, entity2: EntityId, relationshipType: ComponentId): Centix
    local sparseSet = self._relationshipSets[relationshipType]
    if not sparseSet then
        error("[Centix]: Invalid relationship type", 0)
    end

    local row = sparseSet.sparse[entity1] :: any
    if not row then
        row = #sparseSet.dense + 1
        sparseSet.dense[row] = entity1
        sparseSet.sparse[entity1] = row
        sparseSet.data[row] = {}
    end
    sparseSet.data[row][entity2] = true
    return self
end

function Centix.RemoveRelationship(self: Centix, entity1: EntityId, entity2: EntityId, relationshipType: ComponentId): Centix
    local sparseSet = self._relationshipSets[relationshipType]
    if not sparseSet then
        error("[Centix]: Invalid relationship type", 0)
    end

    local row = sparseSet.sparse[entity1]
    if row then
        sparseSet.data[row][entity2] = nil

        if next(sparseSet.data[row]) == nil then
            local lastRow = #sparseSet.dense
            if row ~= lastRow then
                sparseSet.dense[row] = sparseSet.dense[lastRow]
                sparseSet.data[row] = sparseSet.data[lastRow]
                local movedEntity = sparseSet.dense[row]
                sparseSet.sparse[movedEntity] = row
            end
            sparseSet.dense[lastRow] = nil
            sparseSet.data[lastRow] = nil
            sparseSet.sparse[entity1] = nil
        end
    end
    return self
end

function Centix.GetRelationships(self: Centix, entity: EntityId, relationshipType: ComponentId): { [EntityId]: boolean }
    local sparseSet = self._relationshipSets[relationshipType]
    if not sparseSet then
        error("[Centix]: Invalid relationship type", 0)
    end

    local row = sparseSet.sparse[entity]
    if row then
        return sparseSet.data[row]
    end
    return {}
end

return Centix.new()
