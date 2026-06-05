local note = require("note")
local filesystem = require("filesystem")
local component = require("component")
local os = require("os")

local function openLocalFile(path)
  local handle, err = filesystem.open(path, "r")
  if not handle then
    return nil, err
  end
  return handle
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
    local chunk = handle:read(4096)
    if not chunk or chunk == "" then
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

local function readExact(handle, count)
  local buffer = ""
  while #buffer < count do
    local chunk = handle:read(count - #buffer)
    if not chunk or chunk == "" then
      break
    end
    buffer = buffer .. chunk
  end
  return buffer
end

local function parseWavHandle(handle)
  local header = readExact(handle, 12)
  if #header < 12 then
    return nil, "数据过小，无法识别为 WAV。"
  end
  if header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
    return nil, "不是有效的 WAV 文件。"
  end

  local fmt, dataStart, dataSize
  while true do
    local chunkHeader = readExact(handle, 8)
    if #chunkHeader < 8 then
      break
    end
    local chunkId = chunkHeader:sub(1, 4)
    local chunkSize = uintLE(chunkHeader, 5, 4)
    local chunkDataStart = handle:seek("cur", 0)

    if chunkId == "fmt " then
      local chunkData = readExact(handle, chunkSize)
      if #chunkData < chunkSize then
        return nil, "损坏的 fmt chunk。"
      end
      fmt = {
        audioFormat = uintLE(chunkData, 1, 2),
        channels = uintLE(chunkData, 3, 2),
        sampleRate = uintLE(chunkData, 5, 4),
        bitsPerSample = uintLE(chunkData, 15, 2),
      }
    elseif chunkId == "data" then
      dataStart = chunkDataStart
      dataSize = chunkSize
      handle:seek("cur", chunkSize)
    else
      handle:seek("cur", chunkSize)
    end

    if chunkSize % 2 == 1 then
      handle:seek("cur", 1)
    end
    if fmt and dataStart then
      break
    end
  end

  if not fmt then
    return nil, "找不到 fmt Chunk。"
  end
  if not dataStart then
    return nil, "找不到 data Chunk。"
  end
  if fmt.audioFormat ~= 1 then
    return nil, "仅支持 PCM 编码的 WAV 文件。"
  end

  handle:seek("set", dataStart)
  return fmt, dataSize
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
  if zeroCrossings == 0 then
    return nil
  end
  local duration = #samples / sampleRate
  if duration <= 0 or duration == math.huge or duration ~= duration then
    return nil
  end
  local freq = zeroCrossings / (2 * duration)
  if freq <= 0 or freq == math.huge or freq ~= freq then
    return nil
  end
  return freq
end

local function normalizeFrequency(freq)
  if not freq or type(freq) ~= "number" then
    return nil
  end
  if freq ~= freq or freq == math.huge or freq == -math.huge then
    return nil
  end
  if freq <= 0 or freq < 20 or freq > 2000 then
    return nil
  end
  return freq
end


local function processSegment(segment, fmt, threshold, currentNote, currentDuration, notes)
  local sum = 0
  for _, v in ipairs(segment) do
    sum = sum + v * v
  end
  local rms = math.sqrt(sum / #segment)
  local noteFrequency = nil
  if rms >= threshold then
    local freq = estimateFrequency(segment, fmt.sampleRate)
    if freq and freq > 0 then
      noteFrequency = normalizeFrequency(freq)
    end
  end
  local duration = #segment / fmt.sampleRate
  if noteFrequency == currentNote then
    currentDuration = currentDuration + duration
  else
    if currentDuration > 0 and currentNote then
      notes[#notes + 1] = {note = currentNote, duration = currentDuration}
    elseif currentDuration > 0 then
      notes[#notes + 1] = {note = nil, duration = currentDuration}
    end
    currentNote = noteFrequency
    currentDuration = duration
  end
  return currentNote, currentDuration
end

local function buildNoteTableFromData(data, fmt)
  local bytesPerSample = fmt.bitsPerSample / 8
  local frameSize = bytesPerSample * fmt.channels
  local segmentSamples = math.max(64, math.floor(fmt.sampleRate * 0.08))
  local threshold = 2 ^ (fmt.bitsPerSample - 1) * 0.02
  local notes = {}
  local currentNote, currentDuration = nil, 0
  local segment = {}
  
  local fullFrames = math.floor(#data / frameSize)
  for i = 0, fullFrames - 1 do
    local frameStart = i * frameSize + 1
    local sum = 0
    for ch = 1, fmt.channels do
      local samplePos = frameStart + (ch - 1) * bytesPerSample
      local sample
      if bytesPerSample == 1 then
        sample = string.byte(data, samplePos) - 128
      else
        sample = sintLE(data, samplePos, bytesPerSample)
      end
      sum = sum + sample
    end
    local sample = sum / fmt.channels
    segment[#segment + 1] = sample
    if #segment >= segmentSamples then
      currentNote, currentDuration = processSegment(segment, fmt, threshold, currentNote, currentDuration, notes)
      segment = {}
    end
  end

  if #segment > 0 then
    currentNote, currentDuration = processSegment(segment, fmt, threshold, currentNote, currentDuration, notes)
  end
  if currentDuration > 0 then
    if currentNote then
      notes[#notes + 1] = {note = currentNote, duration = currentDuration}
    else
      notes[#notes + 1] = {note = nil, duration = currentDuration}
    end
  end
  return notes
end

local function parseWavData(data)
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

local function buildNoteTableFromHandle(handle, fmt, dataSize)
  local bytesPerSample = fmt.bitsPerSample / 8
  local frameSize = bytesPerSample * fmt.channels
  local segmentSamples = math.max(64, math.floor(fmt.sampleRate * 0.08))
  local threshold = 2 ^ (fmt.bitsPerSample - 1) * 0.02
  local notes = {}
  local currentNote, currentDuration = nil, 0
  local segment = {}
  local leftover = ""
  local bytesLeft = dataSize

  while bytesLeft > 0 do
    local readSize = math.min(8192, bytesLeft)
    local chunk = handle:read(readSize)
    if not chunk or chunk == "" then
      break
    end
    bytesLeft = bytesLeft - #chunk
    local buffer = leftover .. chunk
    local fullFrames = math.floor(#buffer / frameSize)
    local bytesToProcess = fullFrames * frameSize
    local frameData = buffer:sub(1, bytesToProcess)
    leftover = buffer:sub(bytesToProcess + 1)

    for i = 0, fullFrames - 1 do
      local frameStart = i * frameSize + 1
      local sum = 0
      for ch = 1, fmt.channels do
        local samplePos = frameStart + (ch - 1) * bytesPerSample
        local sample
        if bytesPerSample == 1 then
          sample = string.byte(frameData, samplePos) - 128
        else
          sample = sintLE(frameData, samplePos, bytesPerSample)
        end
        sum = sum + sample
      end
      local sample = sum / fmt.channels
      segment[#segment + 1] = sample
      if #segment >= segmentSamples then
        currentNote, currentDuration = processSegment(segment, fmt, threshold, currentNote, currentDuration, notes)
        segment = {}
      end
    end
  end

  if #segment > 0 then
    currentNote, currentDuration = processSegment(segment, fmt, threshold, currentNote, currentDuration, notes)
  end
  if currentDuration > 0 then
    if currentNote then
      notes[#notes + 1] = {note = currentNote, duration = currentDuration}
    else
      notes[#notes + 1] = {note = nil, duration = currentDuration}
    end
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
      handle:write(string.format("  { note = %.4f, duration = %.4f },\n", entry.note, entry.duration))
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
      if type(entry.note) == "number" and entry.note >= 20 and entry.note <= 2000 then
        note.play(entry.note, entry.duration)
      else
        os.sleep(entry.duration)
      end
    else
      os.sleep(entry.duration)
    end
  end
end

local function extractFilename(path)
  local filename = path:match("([^\\/]+)$") or path
  filename = filename:gsub("%.lua$", "")
  filename = filename:gsub("%.[^.]*$", "")
  return filename
end

local function loadTrackFromLua(path)
  local chunk, err = loadfile(path)
  if not chunk then
    return nil, err
  end
  local ok, track = pcall(chunk)
  if not ok then
    return nil, track
  end
  if type(track) ~= "table" then
    return nil, "Lua 文件未返回有效的音符表。"
  end
  return track
end

local function main()
  print("== OC 音乐 ==")
  io.write("请输入本地WAV文件绝对路径、本地Lua表文件(.lua)或网络URL: ")
  local source = io.read()
  if not source or source == "" then
    print("未输入音频源，已退出。")
    return
  end
  io.write("按回车开始处理...")
  io.read()

  print("正在加载音频数据...")
  local notes
  if source:match("^https?://") then
    local data, err = fetchUrl(source)
    if not data then
      print("读取音频失败: " .. tostring(err))
      return
    end

    local fmt, wavData = parseWavData(data)
    if not fmt then
      print("解析 WAV 失败: " .. tostring(wavData))
      return
    end
    print(string.format("WAV 格式: %d Hz, %d 位, %d 通道", fmt.sampleRate, fmt.bitsPerSample, fmt.channels))

    print("正在生成音符表...")
    notes = buildNoteTableFromData(wavData, fmt)
  elseif source:sub(-4):lower() == ".lua" then
    local track, err = loadTrackFromLua(source)
    if not track then
      print("加载 Lua 表失败: " .. tostring(err))
      return
    end
    print("已加载 Lua 表文件，直接播放。")
    notes = track
  else
    local handle, err = openLocalFile(source)
    if not handle then
      print("读取音频失败: " .. tostring(err))
      return
    end

    local fmt, dataSize = parseWavHandle(handle)
    if not fmt then
      print("解析 WAV 失败: " .. tostring(dataSize))
      handle:close()
      return
    end
    print(string.format("WAV 格式: %d Hz, %d 位, %d 通道", fmt.sampleRate, fmt.bitsPerSample, fmt.channels))

    print("正在逐段解码音频并生成音符表...")
    notes = buildNoteTableFromHandle(handle, fmt, dataSize)
    handle:close()
  end

  if #notes == 0 then
    print("未生成音符，可能音频无声或格式不受支持。")
    return
  end

  local baseName = extractFilename(source)
  local outputFile = "/home/" .. baseName .. ".lua"
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
