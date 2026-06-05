local note = require("note")
local filesystem = require("filesystem")
local component = require("component")
local os = require("os")

local function readLocalFile(path)
  local handle, err = filesystem.open(path, "r")
  if not handle then
    return nil, err
  end
  local chunks = {}
  while true do
    local chunk = handle:read(4096)
    if not chunk or chunk == "" then
      break
    end
    table.insert(chunks, chunk)
  end
  handle:close()
  return table.concat(chunks)
end

local function fetchUrl(url)
  if not component.isAvailable("internet") then
    return nil, "Internet 组件不可用，无法下载网络音频。"
  end
  local internet = require("internet")
  local handle, err = internet.request(url)
  if not handle then
    return nil, err
  end
  local chunks = {}
  while true do
    local chunk = handle.read()
    if not chunk then
      break
    end
    table.insert(chunks, chunk)
  end
  handle:close()
  return table.concat(chunks)
end

local function uintLE(data, pos, bytes)
  local value = 0
  for i = 0, bytes - 1 do
    value = value + string.byte(data, pos + i) * 2 ^ (8 * i)
  end
  return value
end

local function sintLE(data, pos, bytes)
  local value = uintLE(data, pos, bytes)
  local limit = 2 ^ (8 * bytes)
  if value >= limit / 2 then
    value = value - limit
  end
  return value
end

local function parseWav(data)
  if #data < 44 then
    return nil, "数据过小，无法识别为 WAV。"
  end
  if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then
    return nil, "不是有效的 WAV 文件。"
  end

  local pos = 13
  local fmt
  local dataChunk
  while pos <= #data - 8 do
    local chunkId = data:sub(pos, pos + 3)
    local chunkSize = uintLE(data, pos + 4, 4)
    local chunkStart = pos + 8
    if chunkId == "fmt " then
      local audioFormat = uintLE(data, chunkStart, 2)
      local channels = uintLE(data, chunkStart + 2, 2)
      local sampleRate = uintLE(data, chunkStart + 4, 4)
      local bitsPerSample = uintLE(data, chunkStart + 14, 2)
      fmt = {
        audioFormat = audioFormat,
        channels = channels,
        sampleRate = sampleRate,
        bitsPerSample = bitsPerSample,
      }
    elseif chunkId == "data" then
      dataChunk = {
        offset = chunkStart,
        size = chunkSize,
      }
      break
    end
    pos = chunkStart + chunkSize + (chunkSize % 2)
  end

  if not fmt then
    return nil, "找不到 fmt Chunk。"
  end
  if not dataChunk then
    return nil, "找不到 data Chunk。"
  end
  if fmt.audioFormat ~= 1 then
    return nil, "仅支持 PCM 编码的 WAV 文件。"
  end
  return fmt, data:sub(dataChunk.offset, dataChunk.offset + dataChunk.size - 1)
end

local function decodeSamples(data, fmt)
  local bytesPerSample = fmt.bitsPerSample / 8
  local frameSize = bytesPerSample * fmt.channels
  local count = math.floor(#data / frameSize)
  local samples = {}
  for i = 0, count - 1 do
    local sum = 0
    for ch = 1, fmt.channels do
      local pos = i * frameSize + (ch - 1) * bytesPerSample + 1
      local sample
      if bytesPerSample == 1 then
        sample = string.byte(data, pos) - 128
      else
        sample = sintLE(data, pos, bytesPerSample)
      end
      sum = sum + sample
    end
    samples[#samples + 1] = sum / fmt.channels
  end
  return samples
end

local function estimateFrequency(samples, sampleRate)
  if #samples < 2 then
    return nil
  end
  local zeroCrossings = 0
  local prev = samples[1]
  for i = 2, #samples do
    local curr = samples[i]
    if (prev < 0 and curr >= 0) or (prev > 0 and curr <= 0) then
      zeroCrossings = zeroCrossings + 1
    end
    prev = curr
  end
  local duration = #samples / sampleRate
  if duration <= 0 then
    return nil
  end
  return zeroCrossings / (2 * duration)
end

local function freqToNoteNumber(freq)
  if not freq or freq <= 0 then
    return nil
  end
  local baseFreq = 220
  local semitone = 12 * math.log(freq / baseFreq) / math.log(2) + 13
  local noteNumber = math.floor(semitone + 0.5)
  if noteNumber < 1 then
    noteNumber = 1
  elseif noteNumber > 25 then
    noteNumber = 25
  end
  return noteNumber
end

local function buildNoteTable(samples, fmt)
  local segmentSeconds = 0.08
  local segmentSize = math.max(64, math.floor(fmt.sampleRate * segmentSeconds))
  local threshold = 2 ^ (fmt.bitsPerSample - 1) * 0.02
  local notes = {}
  local currentNote
  local currentDuration = 0
  local i = 1
  while i <= #samples do
    local endIdx = math.min(#samples, i + segmentSize - 1)
    local chunk = {}
    for j = i, endIdx do
      chunk[#chunk + 1] = samples[j]
    end
    local sum = 0
    for _, v in ipairs(chunk) do
      sum = sum + v * v
    end
    local rms = math.sqrt(sum / #chunk)
    local noteNumber
    if rms >= threshold then
      local freq = estimateFrequency(chunk, fmt.sampleRate)
      noteNumber = freqToNoteNumber(freq)
    else
      noteNumber = nil
    end
    local duration = (#chunk) / fmt.sampleRate
    if noteNumber == currentNote then
      currentDuration = currentDuration + duration
    else
      if currentDuration > 0 then
        notes[#notes + 1] = {note = currentNote, duration = currentDuration}
      end
      currentNote = noteNumber
      currentDuration = duration
    end
    i = endIdx + 1
  end
  if currentDuration > 0 then
    notes[#notes + 1] = {note = currentNote, duration = currentDuration}
  end
  return notes
end

local function saveTrack(notes, filename)
  local handle, err = filesystem.open(filename, "w")
  if not handle then
    return nil, err
  end
  handle:write("local track = {\n")
  for _, entry in ipairs(notes) do
    if entry.note then
      handle:write(string.format("  { note = %d, duration = %.4f },\n", entry.note, entry.duration))
    else
      handle:write(string.format("  { note = nil, duration = %.4f },\n", entry.duration))
    end
  end
  handle:write("}\n\nreturn track\n")
  handle:close()
  return true
end

local function playTrack(notes)
  for _, entry in ipairs(notes) do
    if entry.note then
      note.play(entry.note, entry.duration)
    end
    os.sleep(entry.duration)
  end
end

local function main()
  print("== 音频转 Lua 表工具 (OpenComputers) ==")
  io.write("请输入本地WAV文件路径或网络URL: ")
  local source = io.read()
  if not source or source == "" then
    print("未输入音频源，已退出。")
    return
  end
  io.write("按回车开始转换...")
  io.read()

  print("正在加载音频数据...")
  local data, err
  if source:match("^https?://") then
    data, err = fetchUrl(source)
  else
    data, err = readLocalFile(source)
  end
  if not data then
    print("读取音频失败: " .. tostring(err))
    return
  end

  local fmt, wavData = parseWav(data)
  if not fmt then
    print("解析 WAV 失败: " .. tostring(wavData))
    return
  end
  print(string.format("WAV 格式: %d Hz, %d 位, %d 通道", fmt.sampleRate, fmt.bitsPerSample, fmt.channels))

  print("正在解码采样数据...")
  local samples = decodeSamples(wavData, fmt)
  print("正在生成音符表...")
  local notes = buildNoteTable(samples, fmt)

  if #notes == 0 then
    print("未生成音符，可能音频无声或格式不受支持。")
    return
  end

  local outputFile = "converted_track.lua"
  local ok, saveErr = saveTrack(notes, outputFile)
  if not ok then
    print("保存 Lua 表失败: " .. tostring(saveErr))
  else
    print("已保存 Lua 表到: " .. outputFile)
  end

  print("开始播放生成的音符...")
  playTrack(notes)
  print("播放完成。")
end

main()
