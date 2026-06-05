local M={}
M.func=function(c,m,b)
 local p=type(_G.playNote)=="function" and _G.playNote
 local s=60/b
 for _,v in ipairs(m) do
  for i=1,c do
   local ms=math.floor(v/(100^(i-1)))%100
   if ms~=0 then
    local inst=math.floor(ms/10)
    local note=ms%10
    if note<0 then note=0 elseif note>24 then note=24 end
    if p then p(inst,note) end
   end
  end
  if type(s)=="number" and s>0 and type(os.sleep)=="function" then os.sleep(s) end
 end
end
return M