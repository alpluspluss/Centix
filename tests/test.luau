local Centix = require("../Centix/lib/init")
local testkit = require("../Centix/testkit")

local TEST, _, CHECK, FINISH, _, _ = testkit.test()

local ECS = Centix.new()

TEST("Entity Creation", function()
    local entity = ECS:Entity()
    CHECK(typeof(entity) == "number")
end)

TEST("Entity Destruction", function()
    local entity = ECS:Entity()
    ECS:Despawn(entity)
    CHECK(ECS._freeList[1] == entity)
end)

TEST("Component Registeration", function()
    local entity = ECS:Entity()
    ECS:RegisterComponent(entity, 1, { x = 0, y = 0 })
    local data = ECS._entityIndex[entity].componentData[1].data[1]
    CHECK(data.x == 0 and data.y == 0)
end)

TEST("Component Removal", function()
    local entity = ECS:Entity()
    ECS:RegisterComponent(entity, 2, { someData = "example" })
    ECS:RemoveComponent(entity, 1)
    local componentData = ECS._entityIndex[entity].componentData[1].data[1]
    CHECK(componentData == nil)
end)

FINISH()
