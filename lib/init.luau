--!native
--!optimize 2
--!strict

type EntityId = number
type ComponentId = number
type Archetype = {
	bitmask: number,
	entities: { [number]: EntityId },
	entityRow: { [EntityId]: number },
	componentData: { [ComponentId]: { [number]: any } },
	entityCount: number,
	dirtyFlags: number
}

type ArchetypeEdgeCache = {
	[number]: { -- Flattened edge cache with combined bitmasks as keys
		to: Archetype,
		componentId: ComponentId
	}
}

type QueryCache = {
	archetypes: { Archetype },
	includeBitmask: number,
	excludeBitmask: number,
	components: { ComponentId }
}

local Signal = require(script:WaitForChild("Signal"))

local ENTITY_MASK: number = 0x00FFFFFF
local GENERATION_SHIFT: number = 0x18
local MAX_GENERATION: number = 0xFF

local DIRTY_ADDITION: number = 0x1
local DIRTY_REMOVAL: number = 0x2
local DIRTY_UPDATE: number = 0x4

local Centix = {}
Centix.__index = Centix

type Centix = typeof(setmetatable({
	_archetypeIndex = {} :: { [number]: Archetype },
	_entityIndex = {} :: { [EntityId]: Archetype },
	_freeList = {} :: { EntityId },
	_generations = {} :: { [EntityId]: number },
	_nextId = 1 :: EntityId,
	_edgeCache = {} :: ArchetypeEdgeCache,
	_queryCache = {} :: { [number]: QueryObject },
	_previousSnapshots = {} :: { [Archetype]: { entityCount: number, componentHash: number } },
	OnAdded = Signal.new(),
	OnSet = Signal.new(),
	OnRemoved = Signal.new(),
	OnTransitioned = Signal.new()
}, Centix))

function Centix.new(): Centix
	local self = setmetatable({}, Centix)
	self._archetypeIndex = {}
	self._entityIndex = {}
	self._freeList = {}
	self._generations = {}
	self._nextId = 1
	self._edgeCache = {}
	self._queryCache = {}
	self._previousSnapshots = {}
	self.OnAdded = Signal.new()
	self.OnRemoved = Signal.new()
	self.OnSet = Signal.new()
	self.OnTransitioned = Signal.new()
	return self
end

function Centix.Spawn(self: Centix): EntityId
	local entityId: EntityId
	local generation: number

	if #self._freeList > 0 then
		entityId = table.remove(self._freeList) :: number
		generation = self._generations[entityId] + 1
		if generation > MAX_GENERATION then
			generation = 0
		end
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

		if row ~= archetype.entityCount then
			archetype.entities[row] = lastEntity
			archetype.entityRow[lastEntity] = row
		end
		archetype.entityCount -= 1

		for _, componentArray in archetype.componentData do
			if row < archetype.entityCount then
				componentArray[row] = componentArray[archetype.entityCount + 1]
				local movedEntity = archetype.entities[row]
				archetype.entityRow[movedEntity] = row
			end
			componentArray[archetype.entityCount + 1] = nil
		end

		archetype.entityRow[entityId] = nil
		self._entityIndex[entityId] = nil
		if archetype.entityCount == 0 then
			self._archetypeIndex[archetype.bitmask] = nil
		end

		archetype.dirtyFlags = bit32.bor(archetype.dirtyFlags, DIRTY_REMOVAL)
	end
	
	self._freeList[#self._freeList + 1] = entityId
	self.OnRemoved:Fire(entityId)
end

local function __Archetype__Transition__(self: Centix, entity: EntityId, component: ComponentId, add: boolean): Archetype
	local currentArchetype = self._entityIndex[entity]
	if not currentArchetype then
		error("[Centix]: Entity not initialized with an archetype", 0)
	end

	local shiftComponent = bit32.lshift(1, component - 1)
	local newBitmask = add and bit32.bor(currentArchetype.bitmask, shiftComponent)
		or bit32.band(currentArchetype.bitmask, bit32.bnot(shiftComponent))

	local cacheKey = bit32.bor(bit32.lshift(currentArchetype.bitmask, 32), newBitmask)
	local cachedEdge = self._edgeCache[cacheKey]
	if cachedEdge then
		return cachedEdge.to
	end

	local newArchetype = self._archetypeIndex[newBitmask]
	if not newArchetype then
		newArchetype = {
			bitmask = newBitmask,
			componentData = {},
			entities = {},
			entityRow = {},
			entityCount = 0,
			dirtyFlags = DIRTY_ADDITION
		}
		self._archetypeIndex[newBitmask] = newArchetype
	end

	self._edgeCache[cacheKey] = {
		to = newArchetype,
		componentId = component,
	}

	if bit32.band(currentArchetype.dirtyFlags, DIRTY_UPDATE) == 0 then
		currentArchetype.dirtyFlags = bit32.bor(currentArchetype.dirtyFlags, DIRTY_UPDATE)
	end
	return newArchetype
end

function Centix.Set<T>(self: Centix, entity: EntityId, component: ComponentId, data: T): Centix
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
			entityRow = {},
			dirtyFlags = 0,
		}
		self._entityIndex[entity] = currentArchetype
	end

	local row = currentArchetype.entityRow[entity]
	local newBitmask = bit32.bor(currentArchetype.bitmask, bit32.lshift(1, component - 1))
	if row and newBitmask == currentArchetype.bitmask then
		local componentArray = currentArchetype.componentData[component]
		if not componentArray then
			componentArray = {}
			currentArchetype.componentData[component] = componentArray
		end
		componentArray[row] = data

		currentArchetype.dirtyFlags = bit32.bor(currentArchetype.dirtyFlags, DIRTY_UPDATE)
	else
		local newArchetype = __Archetype__Transition__(self, entity, component, true)

		newArchetype.bitmask = newBitmask
		local newRow = newArchetype.entityCount + 1
		newArchetype.entities[newRow] = entity
		newArchetype.entityRow[entity] = newRow
		newArchetype.entityCount += 1

		for compId, compData in currentArchetype.componentData do
			local oldArray = compData
			local oldRow = currentArchetype.entityRow[entity]
			if not newArchetype.componentData[compId] then
				newArchetype.componentData[compId] = {}
			end
			newArchetype.componentData[compId][newRow] = oldArray[oldRow]
		end

		if not newArchetype.componentData[component] then
			newArchetype.componentData[component] = {}
		end
		newArchetype.componentData[component][newRow] = data

		self._entityIndex[entity] = newArchetype

		currentArchetype.dirtyFlags = bit32.bor(currentArchetype.dirtyFlags, DIRTY_UPDATE)
		newArchetype.dirtyFlags = bit32.bor(newArchetype.dirtyFlags, DIRTY_ADDITION)
	end
	self.OnAdded:Fire(entity, component)
	return self
end

function Centix.Remove(self: Centix, entity: EntityId, component: ComponentId): Centix
    local entityId = bit32.band(entity, ENTITY_MASK)
    local generation = bit32.rshift(entity, GENERATION_SHIFT)

    if self._generations[entityId] ~= generation then
        error("[Centix]: Invalid entity reference", 0)
    end

    local currentArchetype = self._entityIndex[entity]
    if not currentArchetype then
        error("[Centix]: Entity does not exist in any archetype", 0)
    end
    if not currentArchetype.componentData[component] then
        return self
    end
    local shiftComponent = bit32.lshift(1, component - 1)
    local newBitmask = bit32.band(currentArchetype.bitmask, bit32.bnot(shiftComponent))
    if newBitmask == currentArchetype.bitmask then
        return self
    end
    local row = currentArchetype.entityRow[entity]
    currentArchetype.componentData[component][row] = nil

    local newArchetype = __Archetype__Transition__(self, entity, component, false)

    newArchetype.bitmask = newBitmask
    local newRow = newArchetype.entityCount + 1
    newArchetype.entities[newRow] = entity
    newArchetype.entityRow[entity] = newRow
    newArchetype.entityCount += 1

    for compId, compData in currentArchetype.componentData do
        local oldArray = compData
        local oldRow = currentArchetype.entityRow[entity]
        if not newArchetype.componentData[compId] then
            newArchetype.componentData[compId] = {}
        end
        newArchetype.componentData[compId][newRow] = oldArray[oldRow]
    end

    self._entityIndex[entity] = newArchetype
    currentArchetype.dirtyFlags = bit32.bor(currentArchetype.dirtyFlags, DIRTY_REMOVAL)
    newArchetype.dirtyFlags = bit32.bor(newArchetype.dirtyFlags, DIRTY_ADDITION)
	self.OnAdded:Fire(entity, component)
    return self
end

local querySchema = {
	archetypes = {} :: { Archetype },
	components = {} :: { ComponentId },
	includeBitmask = 0 :: number,
	excludeBitmask = 0 :: number,
	ecs = Centix.new()
}

local QueryObject = {}
QueryObject.__index = QueryObject

type QueryObject = typeof(setmetatable(querySchema, QueryObject))

function QueryObject.new(q: typeof(querySchema)): QueryObject
	local self = setmetatable({}, QueryObject)
	self.archetypes = q.archetypes
	self.components = q.components
	self.includeBitmask = q.includeBitmask
	self.excludeBitmask = q.excludeBitmask
	self.ecs = q.ecs
	return self
end

function QueryObject.Include(self: QueryObject, componentIds: { ComponentId }): QueryObject
	for _, componentId in componentIds do
		self.includeBitmask = bit32.bor(self.includeBitmask, bit32.lshift(1, componentId - 1))
	end
	return self
end

function QueryObject.Exclude(self: QueryObject, componentIds: { ComponentId }): QueryObject
	for _, componentId in componentIds do
		self.excludeBitmask = bit32.bor(self.excludeBitmask, bit32.lshift(1, componentId - 1))
	end
	return self
end

function QueryObject.View(self: QueryObject): () -> (EntityId, ...any)?
    local currentArchetypeIndex = 1
    local currentEntityIndex = 1
    local currentArchetype = self.archetypes[currentArchetypeIndex]

    local componentArrays = {}
    local numComponents = #self.components
    
    return function(): (EntityId, ...any)?
        while currentArchetype do
            if currentArchetype.entityCount == 0 then
                currentArchetypeIndex += 1
                currentArchetype = self.archetypes[currentArchetypeIndex]
                currentEntityIndex = 1
                continue
            end

            if bit32.band(currentArchetype.bitmask, self.includeBitmask) == self.includeBitmask and
               bit32.band(currentArchetype.bitmask, self.excludeBitmask) == 0 then
                for _, componentId in self.components do
                    componentArrays[componentId] = currentArchetype.componentData[componentId]
                end
                while currentEntityIndex <= currentArchetype.entityCount do
                    local entityId = currentArchetype.entities[currentEntityIndex]
                    currentEntityIndex += 1
                    local componentValues = table.create(numComponents)
                    for i, componentId in self.components do
                        local componentArray = componentArrays[componentId]
                        if componentArray then
                            local row = currentArchetype.entityRow[entityId]
                            componentValues[i] = componentArray[row]
                        else
                            componentValues[i] = nil
                        end
                    end
                    return entityId, table.unpack(componentValues)
                end
                currentArchetype.dirtyFlags = 0
            end
            currentArchetypeIndex += 1
            currentArchetype = self.archetypes[currentArchetypeIndex]
            currentEntityIndex = 1
        end
        return nil
    end
end

function Centix.Query(self: Centix, components: { ComponentId }): QueryObject
	local queryBitmask = 0
	-- TODO: Optimize this
	for _, componentId in components do
		queryBitmask = bit32.bor(queryBitmask, bit32.lshift(1, componentId - 1))
	end

	if self._queryCache[queryBitmask] then
		local cachedQuery = self._queryCache[queryBitmask]
		local isValid = true

		for _, archetype in cachedQuery.archetypes do
			if bit32.band(archetype.dirtyFlags, DIRTY_UPDATE) ~= 0 then
				isValid = false
				break
			end
		end

		if isValid then
			return cachedQuery
		end
	end

	local matchingArchetypes = {}
	for bitmask, archetype in self._archetypeIndex do
		if bit32.bor(bitmask, queryBitmask) == queryBitmask then
			matchingArchetypes[#matchingArchetypes + 1] = archetype
		end
	end

	local query = {
		archetypes = matchingArchetypes,
		includeBitmask = queryBitmask,
		excludeBitmask = 0,
		components = components,
		ecs = self
	}

	local queryObj = QueryObject.new(query)
	self._queryCache[queryBitmask] = queryObj
	return queryObj
end

return Centix.new()
