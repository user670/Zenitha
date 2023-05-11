local sendCHN=love.thread.getChannel('inputChannel')
local recvCHN=love.thread.getChannel('outputChannel')

local getCount=sendCHN.getCount

local threads={}
local threadCount=0

--- @language LUA
local threadCode=[[
    local id=...

    local http=require'socket.http'
    local ltn12=require'ltn12'

    local sendCHN=love.thread.getChannel('inputChannel')
    local recvCHN=love.thread.getChannel('outputChannel')

    while true do
        local arg=sendCHN:demand()

        if arg._destroy then
            recvCHN:push{
                destroy=true,
                id=id,
            }
            break
        end

        -- print("\n------SEND------") for k,v in next,arg do print(k,v)end
        local data={}
        local _,code,detail=http.request{
            method=arg.method,
            url=arg.url,
            headers=arg.headers,
            source=ltn12.source.string(arg.body),

            sink=ltn12.sink.table(data),
        }

        local result={
            pool=arg.pool,
            _poolPtr=arg._poolPtr,
            code=code,
            body=table.concat(data),
            detail=detail,
        }
        -- print("\n------RECV------") for k,v in next,result do print(k,v)end
        recvCHN:push(result)
    end
]]

local msgPool=setmetatable({},{
    __index=function(self,k)
        self[k]={}
        return self[k]
    end
})

local HTTP={
    _msgCount=0,
    _host=false,
}

local function addThread(num)
    for i=1,26 do
        if num<=0 then break end
        if not threads[i] then
            threads[i]=love.thread.newThread(threadCode)
            threads[i]:start(i)
            threadCount=threadCount+1
            num=num-1
        end
    end
end

--- @class Zenitha.httpRequest
--- @field body table|nil|string @must be table if given, will be encoded to json
--- @field pool string @default to '_default' if not given
--- @field method string|nil @default to 'POST' if body is given, 'GET' otherwise
--- @field headers table|nil
--- @field url string @default to the url set with HTTP.setHost
--- @field path string|nil @append to url
--- @field _poolPtr string @internal use only
--- @field _destroy true @internal use only

--- Send a HTTP request
--- @param arg Zenitha.httpRequest
function HTTP.request(arg)
    arg.method=arg.method or arg.body and 'POST' or 'GET'
    if arg.url then
        assert(type(arg.url)=='string',"Field 'url' need string, get "..type(arg.url))
        if arg.url:sub(1,7)~='http://' then arg.url='http://'..arg.url end
    else
        arg.url=HTTP._host or error("Need url=<string> or set default host with HTTP.setHost")
    end
    if arg.path then
        assert(type(arg.path)=='string',"Field 'path' need string, get "..type(arg.path))
        arg.url=arg.url..arg.path
    end
    assert(arg.headers==nil or type(arg.headers)=='table',"Field 'headers' need table, get "..type(arg.headers))

    if arg.body~=nil then
        assert(type(arg.body)=='table',"Field 'body' need table, get "..type(arg.body))
        arg.body=JSON.encode(arg.body)
        if not arg.headers then arg.headers={} end
        TABLE.cover({
            ['Content-Type']="application/json",
            ['Content-Length']=#arg.body,
        },arg.headers)
    end

    if arg.pool==nil then arg.pool='_default' end
    arg._poolPtr=tostring(msgPool[arg.pool])

    sendCHN:push(arg)
end

--- Kill all threads and clear all message pool
function HTTP.reset()
    for i=1,#threads do
        threads[i]:release()
        threads[i]=false
    end
    TABLE.clear(msgPool)
    sendCHN:clear()
    recvCHN:clear()
    addThread(threadCount)
end

--- Set thread count
--- @param n number @1~26
function HTTP.setThreadCount(n)
    assert(type(n)=='number' and n>=1 and n<=26 and n%1==0,"HTTP.setThreadCount(n): n must be integer from 1 to 26")
    if n>threadCount then
        addThread(n-threadCount)
    else
        for _=n+1,threadCount do
            sendCHN:push{_destroy=true}
        end
    end
end

--- Get thread count
--- @return number
function HTTP.getThreadCount()
    return threadCount
end

--- Clear a message pool
--- @param pool string|nil @pool name
function HTTP.clearPool(pool)
    if pool==nil then pool='_default' end
    assert(type(pool)=='string',"Pool must be nil or string")
    HTTP._msgCount=HTTP._msgCount-#msgPool[pool]
    msgPool[pool]={}
end

--- Delete a message pool
--- @param pool string @pool name
function HTTP.deletePool(pool)
    assert(type(pool)=='string',"Pool must be nil or string")
    assert(pool~='_default',"Cannot delete _default pool. What are you doing?")
    HTTP._msgCount=HTTP._msgCount-#msgPool[pool]
    msgPool[pool]=nil
end

--- Poll a message from pool (specifiedif given)
--- @param pool string|nil @pool name
--- @return table|nil
function HTTP.pollMsg(pool)
    if not (type(pool)=='nil' or type(pool)=='string') then error("Pool must be nil or string") end
    HTTP._update()
    local p=msgPool[pool or '_default']
    if #p>0 then
        HTTP._msgCount=HTTP._msgCount-1
        return table.remove(p)
    end
end

--- Set default host
--- @param host string @host url
function HTTP.setHost(host)
    assert(type(host)=='string',"Host must be string")
    if host:sub(1,7)~='http://' then host='http://'..host end
    HTTP._host=host
end

--- Update receiving channel and put results into pool (called by Zenitha)
function HTTP._update()
    while getCount(recvCHN)>0 do
        local m=recvCHN:pop()
        if m.destroy then
            threads[m.id]:release()
            threads[m.id]=false
        elseif tostring(msgPool[m.pool])==m._poolPtr then -- If pool were cleared, discard this datapack
            table.insert(msgPool[m.pool],{
                code=m.code,
                body=m.body,
                detail=m.detail,
            })
            HTTP._msgCount=HTTP._msgCount+1
        end
    end
end

setmetatable(HTTP,{__call=function(self,arg)
    return self.request(arg)
end,__metatable=true})

HTTP.reset()

return HTTP
