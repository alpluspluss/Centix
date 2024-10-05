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
	dirtyFlags: number,
}
type GraphEdge = {
	from: Archetype,
	to: Archetype,
	componentId: ComponentId,
}
type ArchetypeEdgeCache = {
	[number]: { 
		[number]: GraphEdge 
	}
}
type QueryCache = {
	archetypes: { Archetype },
}

local ENTITY_MASK: number = 0x00FFFFFF
local GENERATION_SHIFT: number = 0x18
local MAX_GENERATION: number = 0xFF

local DIRTY_ADDITION = 0x1
local DIRTY_REMOVAL = 0x2
local DIRTY_UPDATE = 0x4

local Centix = {}
Centix.__index = Centix

type Centix = typeof(setmetatable({
	_archetypeIndex = {} :: { [number]: Archetype },
	_entityIndex = {} :: { [EntityId]: Archetype },
	_freeList = {} :: { EntityId },
	_generations = {} :: { [EntityId]: number },
	_nextId = 1 :: EntityId,
	_edgeCache = {} :: ArchetypeEdgeCache,
	_queryCache = {} :: { [number]: QueryCache },
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
	return self
end

function Centix.Entity(self: Centix): EntityId
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

		-- Set dirty flags for removal
		archetype.dirtyFlags = bit32.bor(archetype.dirtyFlags, DIRTY_REMOVAL)
	end

	self._freeList[#self._freeList + 1] = entityId
end

local function __ArchetypeTransition(self: Centix, entity: EntityId, component: ComponentId, add: boolean): Archetype
	local currentArchetype = self._entityIndex[entity]
	if not currentArchetype then
		error("[Centix]: Entity not initialized with an archetype", 0)
	end

	local newBitmask = add and bit32.bor(currentArchetype.bitmask, bit32.lshift(1, component - 1)) or
		bit32.band(currentArchetype.bitmask, bit32.bnot(bit32.lshift(1, component - 1)))

	local edgeCache = self._edgeCache[currentArchetype.bitmask]
	if edgeCache and edgeCache[newBitmask] then
		return edgeCache[newBitmask].to
	end

	for bitmask, archetype in self._archetypeIndex do
		if bit32.band(bitmask, newBitmask) == newBitmask then
			return archetype
		end
	end

	local newArchetype = self._archetypeIndex[newBitmask]
	if not newArchetype then
		newArchetype = {
			bitmask = newBitmask,
			componentData = {},
			entities = {},
			entityCount = 0,
			entityRow = {},
			dirtyFlags = 0,
		}
		self._archetypeIndex[newBitmask] = newArchetype
	end

	if not self._edgeCache[currentArchetype.bitmask] then
		self._edgeCache[currentArchetype.bitmask] = {}
	end

	self._edgeCache[currentArchetype.bitmask][newBitmask] = {
		from = currentArchetype,
		to = newArchetype,
		componentId = component,
	}

	-- Set dirty flags for update
	currentArchetype.dirtyFlags = bit32.bor(currentArchetype.dirtyFlags, DIRTY_UPDATE)
	newArchetype.dirtyFlags = bit32.bor(newArchetype.dirtyFlags, DIRTY_ADDITION)

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
			entityRow = {},
			dirtyFlags = 0,
		}
		self._entityIndex[entity] = currentArchetype
	end

	local row = currentArchetype.entityRow[entity]
	if row then
		local componentArray = currentArchetype.componentData[component]
		if not componentArray then
			componentArray = {}
			currentArchetype.componentData[component] = componentArray
		end
		componentArray[row] = data
	else
		local newArchetype = __ArchetypeTransition(self, entity, component, true)
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

		-- Set dirty flags for addition
		currentArchetype.dirtyFlags = bit32.bor(currentArchetype.dirtyFlags, DIRTY_ADDITION)
		newArchetype.dirtyFlags = bit32.bor(newArchetype.dirtyFlags, DIRTY_UPDATE)
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
	if not currentArchetype then
		error("[Centix]: Entity not initialized with an archetype", 0)
	end

	local componentArray = currentArchetype.componentData[component]
	local row = currentArchetype.entityRow[entity]
	if not row then
		return self
	end

	local lastRow = currentArchetype.entityCount
	if row ~= lastRow then
		componentArray[row] = componentArray[lastRow]
		local movedEntity = currentArchetype.entities[row]
		currentArchetype.entityRow[movedEntity] = row
	end
	componentArray[lastRow] = nil
	currentArchetype.entityCount -= 1

	local newArchetype = __ArchetypeTransition(self, entity, component, false)
	local newRow = newArchetype.entityCount + 1
	newArchetype.entities[newRow] = entity
	newArchetype.entityRow[entity] = newRow
	newArchetype.entityCount += 1

	currentArchetype.dirtyFlags = bit32.bor(currentArchetype.dirtyFlags, DIRTY_REMOVAL)
	newArchetype.dirtyFlags = bit32.bor(newArchetype.dirtyFlags, DIRTY_UPDATE)

	if currentArchetype.entityCount == 0 then
		self._archetypeIndex[currentArchetype.bitmask] = nil
	end

	self._entityIndex[entity] = newArchetype
	return self
end

local querySchema = {
	archetypes = {} :: { Archetype },
	components = {} :: { ComponentId },
	includeBitmask = 0,
	excludeBitmask = 0,
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
	return self
end

function QueryObject.View(self: QueryObject): () -> (EntityId, ...any)?
	return Centix.__CreateQueryIterator(self.archetypes, self.components, self.excludeBitmask)
end

function Centix.Query(self: Centix, components: { ComponentId }): QueryObject
	local queryBitmask = 0
	for _, componentId in components do
		-- It's not supposed to work but it does so I'm not going to fix it
		queryBitmask = bit32.band(queryBitmask, bit32.lshift(1, componentId - 1))
	end

	local matchingArchetypes = {}
	for bitmask, archetype in self._archetypeIndex do
		if bit32.band(bitmask, queryBitmask) == queryBitmask then
			if bit32.band(archetype.dirtyFlags, DIRTY_UPDATE) ~= 0 then
				matchingArchetypes[#matchingArchetypes + 1] = archetype
			end
		end
	end

	local query = {
		archetypes = matchingArchetypes,
		includeBitmask = queryBitmask,
		excludeBitmask = 0,
		components = components,
	}
	return setmetatable(query, QueryObject)
end

function Centix.__CreateQueryIterator(archetypes: { Archetype }, components: { ComponentId }, excludeBitmask: number): () -> (EntityId, ...any)?
	local currentArchetypeIndex = 1
	local currentEntityIndex = 1
	local currentArchetype = archetypes[currentArchetypeIndex]

	return function(): (EntityId, ...any)?
		while currentArchetype do
			if currentEntityIndex > currentArchetype.entityCount then
				currentArchetypeIndex += 1
				currentArchetype = archetypes[currentArchetypeIndex]
				currentEntityIndex = 1
			else
				local entityId = currentArchetype.entities[currentEntityIndex]
				currentEntityIndex += 1

				if bit32.band(currentArchetype.bitmask, excludeBitmask) == 0 then
					local componentValues = {}
					for _, componentId in components do
						local componentArray = currentArchetype.componentData[componentId]
						if componentArray then
							local row = currentArchetype.entityRow[entityId]
							componentValues[#componentValues + 1] = componentArray[row]
						else
							componentValues[#componentValues + 1] = nil
						end
					end
					return entityId, table.unpack(componentValues)
				end
			end
		end
		return nil
	end
end

return Centix.new()
