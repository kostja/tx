#!/usr/bin/env tarantool

local fiber = require('fiber')
local N = 100000

local function bench(fun, ...)
    local start_time = fiber.time64()
    fun(...)
    local end_time = fiber.time64()
    return  N * 1000000LL / (end_time - start_time)
end

local fastnetbox = require('connect')

local function test_call(conn)
    for i=1,N do
        --conn.space.transactions:insert({tostring(i), i})
        --conn:insert(512, {tostring(i), i})
    
        --local body = conn:process(packet)
        conn:call('ping', {'0005-100000010', 756970})
        --conn:ping()
    end
end

local conn = fastnetbox.connect('user:pass@192.168.103.170:13313')
print('fast', bench(test_call, conn))

local conn = require('net.box').new('user:pass@192.168.103.170:13313')
print('netbox', bench(test_call, conn))

os.exit(0)
