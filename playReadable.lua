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

local function processSegment(segment, fmt, threshold, currentNote, currentDuration, notes)
  local sum = 0
  for _, v in ipairs(segment) do
    sum = sum + v * v
  end
  local rms = math.sqrt(sum / #segment)
  local noteNumber
  if rms >= threshold then
    noteNumber = freqToNoteNumber(estimateFrequency(segment, fmt.sampleRate))
  end
  local duration = #segment / fmt.sampleRate
  if noteNumber == currentNote then
    currentDuration = currentDuration + duration
  else
    if currentDuration > 0 then
      notes[#notes + 1] = {note = currentNote, duration = currentDuration}
    end
    currentNote = noteNumber
    currentDuration = duration
  end
  return currentNote, currentDuration
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
  local notes
  if source:match("^https?://") then
    local data, err = fetchUrl(source)
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
    notes = buildNoteTable(samples, fmt)
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
