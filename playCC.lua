local play = require("playNote")

-- 乐谱
local channelCount = 3

local musicScore = {
    551124,641235,120044,001411,661525,482500,331600,002416
}

-- BPM
local BPM = 120

play.func(channelCount, musicScore, BPM)