local M = {}
M.func = function(channelCount, musicScore, BPM)
    print("playNoteReadable start", channelCount, #musicScore, BPM) -- 开始：显示通道数、乐谱长度、BPM
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

    for idx, value in ipairs(musicScore) do
        print("Beat:", idx, "value=", value) -- 每拍开始：拍序号和值
        for channel = 1, channelCount do
            local instrument, note = decodeNote(value, channel)
            if instrument and note ~= nil then
                print("Decoded:", "channel=", channel, "inst=", instrument, "note=", note) -- 解码结果
                print("Calling playChannel:", instrument, note) -- 即将调用播放函数
                playChannel(instrument, note)
            end
        end
        if type(SPB) == "number" and SPB > 0 and type(os.sleep) == "function" then
            print("Sleeping SPB:", SPB) -- 休眠时间（秒/拍）
            os.sleep(SPB)
        end
    end
    print("playNoteReadable end") -- 结束：播放完成
end

return M