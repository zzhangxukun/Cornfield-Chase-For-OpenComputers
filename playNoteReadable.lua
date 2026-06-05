local M = {}
M.func = function(channelCount, musicScore, BPM)
    local SPB = 60 / BPM

    local function normalizeNote(note)
        if type(note) ~= "number" then
            return nil
        end
        if note < 0 then
            return 0
        elseif note > 24 then
            return 24
        end
        return note
    end

    local function playChannel(inst, note)
        if type(_G.playNote) == "function" then
            _G.playNote(inst, note)
        else
            print("playNote fallback:", inst, note)
        end
    end

    local function decodeNote(value, channel)
        local mS = math.floor(value / (100 ^ (channel - 1))) % 100
        if mS == 0 then
            return nil
        end
        local inst = math.floor(mS / 10)
        local note = normalizeNote(mS % 10)
        return inst, note
    end

    for _, value in ipairs(musicScore) do
        for channel = 1, channelCount do
            local instrument, note = decodeNote(value, channel)
            if instrument and note ~= nil then
                playChannel(instrument, note)
            end
        end
        if type(SPB) == "number" and SPB > 0 and type(os.sleep) == "function" then
            os.sleep(SPB)
        end
    end
end

return M