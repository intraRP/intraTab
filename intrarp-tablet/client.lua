local tabletProp = nil
local tabletModel = "prop_cs_tablet" -- Tablet Prop

local function loadModel(model)
    RequestModel(model)
    while not HasModelLoaded(model) do Wait(0) end
end

local function loadAnimDict(dict)
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do Wait(0) end
end

RegisterNetEvent("intrarp-tablet:open")
AddEventHandler("intrarp-tablet:open", function()
    local playerPed = PlayerPedId()

    -- Tablet Prop & Animation
    loadModel(tabletModel)
    loadAnimDict("amb@world_human_seat_wall_tablet@female@base")

    TaskPlayAnim(playerPed, "amb@world_human_seat_wall_tablet@female@base", "base", 8.0, -8.0, -1, 49, 0, false, false, false)

    local tabletObject = CreateObject(GetHashKey(tabletModel), 1.0, 1.0, 1.0, true, true, false)
    AttachEntityToEntity(tabletObject, playerPed, GetPedBoneIndex(playerPed, 60309), 0.1, 0.0, -0.03, 0.0, 0.0, 0.0, true, true, false, true, 1, true)
    tabletProp = tabletObject

    SetNuiFocus(true, true)
    SendNUIMessage({ type = "show", url = Config.TabletURL })
end)

RegisterNUICallback("close", function(_, cb)
    local playerPed = PlayerPedId()
    ClearPedTasks(playerPed)
    if tabletProp then
        DeleteEntity(tabletProp)
        tabletProp = nil
    end
    SetNuiFocus(false, false)
    cb({})
end)

if Config.UseCommand then
    RegisterCommand(Config.CommandName, function()
        TriggerServerEvent("intrarp-tablet:tryOpen")
    end)
end