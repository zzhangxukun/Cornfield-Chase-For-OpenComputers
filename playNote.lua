local M={}
M.func=function(c,m,b)
 local p=type(_G.playNote)=="function" and _G.playNote
 local s=60/b
 print("playNote start", c, #m, b) -- 开始：通道数、乐谱长度、BPM
 for idx,v in ipairs(m) do
  print("Beat:", idx, "value=", v) -- 每拍开始：拍序号和值
  for i=1,c do
   local ms=math.floor(v/(100^(i-1)))%100
   if ms~=0 then
    local inst=math.floor(ms/10)
    local note=ms%10
    if note<0 then note=0 elseif note>24 then note=24 end
    print("Decoded:", "channel=", i, "inst=", inst, "note=", note) -- 解码结果
    if p then
     print("Calling play:", inst, note) -- 调用实际播放函数
     p(inst,note)
    end
   end
  end
  if type(s)=="number" and s>0 and type(os.sleep)=="function" then
   print("Sleeping:", s) -- 休眠时间（秒/拍）
   os.sleep(s)
  end
 end
 print("playNote end") -- 结束：播放完成
end
return M