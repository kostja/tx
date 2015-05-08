#!/usr/bin/env tarantool

local fiber = require('fiber')
local log = require('log')
local http_server = require('http.server')
local fun = require('fun')
local shard = require('shard')
local yaml = require('yaml')

local STATE_NEW = 0
local STATE_INPROGRESS = 1
local STATE_HANDLED = 2
local SAVE_BATCH_SIZE = 50

local function die(msg, ...)
    local err = string.format(msg, ...)
    log.error(err)
    error(err)
end

local function tomoney(str)
    local sep = str:find(".", 1, true)
    local kopecks = 0
    if sep then
        kopecks = str:sub(sep + 1)
        local roubles = str:sub(1, sep - 1)
        if #kopecks == 2 then
            kopecks = tonumber(kopecks)
        elseif #kopecks == 1 then
            kopecks = tonumber(kopecks) * 10
        elseif #kopecks == 0 then
            kopecks = 0
        else
           die('Invalid amount: %s', str)
        end
        str = roubles
    end
    if #str == 0 then
        return kopecks
    else
        return tonumber(str) * 100 + kopecks
    end
end

local function frommoney(num)
    num = 0LL + num
    local roubles = tonumber(num / 100)
    local kopecks = math.abs(tonumber(num % 100))
    if roubles == 0 and num < 0 then
        return string.format("-0.%02d", kopecks)
    end
    return string.format("%d.%02d", roubles, kopecks)
end

-- called from a remote server
function load_accounts(tuples)
    for _, tuple in ipairs(tuples) do
        local status, reason = pcall(function()
            box.space.accounts:insert(tuple)
        end)
        if not status then
            if reason:find('^Duplicate') ~= nil then
                log.error('failed to insert account_id = %s: %s', tuple[1],
                    reason)
            else
                die('failed to insert account_id = %s: %s', tuple[1],
                    reason)
            end
        end
    end
end

local function load_batch(args)
    local server = args[1]
    local tuples = args[2]
    local status, reason = pcall(function()
        server.conn:timeout(5 * shard.REMOTE_TIMEOUT)
            :call("load_accounts", tuples)
    end)
    if not status then
        log.error('failed to insert on %s: %s', server.uri, reason)
        if not server.conn:is_connected() then
            log.error("server %s is offline", server.uri)
        end
    end
end

local function bulk_load(self)
    local count = self:query_param('count')
    if count then
        count = tonumber(count)
        log.info('bulk load, count = %s', count)
    else
        log.info('bulk load')
    end
    -- Start fiber queue to processes requests in parallel
    local batches = {}
    local i = 0
    local total = self.headers['content-length']
    local c = 0
    while true do
        local line = self:read("[\r\n]+")
        if line == '' then
            break
        elseif line == nil then
            die('failed to read request line')
            break
        elseif count and i >= count then
            log.info('stopped due to count argument value')
            break
        end
        c = c + #line
        local account_id, info, balance1 = line:match("([%d%-]*)\t+(.*)\t([%d%.]+)")
        if account_id then
            balance = tomoney(balance1)
            local tuple = box.tuple.new{ account_id, balance, info }
            for _, server in ipairs(shard.shard(account_id)) do
                local batch = batches[server]
                if batch == nil then
                    batch = { count = 0, tuples = {} }
                    batches[server] = batch
                end
                batch.count = batch.count + 1
                batch.tuples[batch.count] = tuple
            end
        else
            die('invalid line in bulk_load: [%s]', line) 
        end
       i = i + 1
    end
    local q = shard.queue(load_batch, shard.len())
    for server, batch in pairs(batches) do
        q:put({ server, batch.tuples })
    end
    -- stop fiber queue
    q:join()
    log.info('loaded %s accounts', i)
    batches = nil
    collectgarbage('collect')
    return self:render({ text = string.format('loaded %s accounts', i) })
end 

local function get_all_iter(paramx, state)
    local gen, param = paramx[1], paramx[2]
    local statenew
    result = {}
    local i = 0
    for state, tuple in gen, param, state do
        result[i+1] = string.format(
            '%s\t%s\t%s\n', tuple[1], tuple[3], frommoney(tuple[2])
        )
        statenew = state
        i = i + 1
        if i >= SAVE_BATCH_SIZE then
           break
        end
    end
    fiber.sleep(0)
    return statenew, table.concat(result)
end

local function get_all(self)
    local i = 0
    local delay = 0.01
    log.info('BEFORE_WAIT')
    log.info(yaml.encode(box.space.operations.index.queue:select(
        STATE_INPROGRESS, {iterator='le'}
    )))
    shard.wait_operations()
    log.info('AFTER WAIT')
    log.info(yaml.encode(box.space.operations.index.queue:select(
        STATE_INPROGRESS, {iterator='le'}
    )))

    local gen, param, state = box.space.accounts:pairs()
    return self:iterate(get_all_iter, {gen, param}, state)
end

local function transactions(self)
    local now = fiber.time()
    local count = self:query_param('count')
    if count then
        count = tonumber(count)
        log.debug('transactions, count = %s', count)
    else
        log.debug('transactions')
    end
    local i = 0
    local tasks = {}
    local tasks_n = 0
    local batch = shard.q_begin()
    while true do
        local line = self:read("[\r\n]+")
        if line == '' then
            break
        elseif line == nil then
            die('failed to read request line')
        elseif count and i >= count then
            log.info('stopped due to count argument value')
            break
        end
        local date, id, src, dst, amount = line:match(
            "([0-9%-]+%s+[0-9%-%:%.]+)%s+([%d%-]+)%s+([%d%-]+)%s+([%d%-]+)%s+([%d%.]+)"
        )
        if not date then
            die('invalid line in /transactions: [%s]', line) 
        end
        amount = tomoney(amount)
        batch.accounts:q_update(id, src, {{'-', 2, amount}})
        batch.accounts:q_update(id, dst, {{'+', 2, amount}})
        i = i + 1
        if i % 10000 == 0 then
           log.debug('queued %d transactions', i)
        end
    end
    batch:q_end()
--    log.info('queued %d transactions, done %s ms', i, (fiber.time() - now)*1000)
    return self:render({ text = string.format('processed %d transactions', i) })
end

-- check shard after connect function
shard.check_shard = function(conn)
    return conn.space.accounts ~= nil
end

--
-- Entry point
--
local function start(cfg)
    -- Configure database
    -- Create users && tables
    if not box.space.accounts then
        log.info('bootstraping database...')
        box.schema.user.create(cfg.login, { password = cfg.password })
        box.schema.user.grant(cfg.login, 'read,write,execute', 'universe')
        local accounts = box.schema.create_space('accounts')
        accounts:create_index('primary', {type = 'hash', parts = {1, 'str'}})
        log.info('bootstrapped') 
    end

    -- Start binary port
    box.cfg { listen = cfg.binary }

    -- Initialize sharding
    shard.init(cfg)

    -- Start HTTP server
    log.info('starting http server on *:%s...', cfg.http)
    local httpd = http_server.new(nil, cfg.http, { app_dir = '.',
        log_requests = true })
        :route({path = '/bulk_load', method = 'POST'}, bulk_load)
        :route({path = '/get_all', method = 'GET'}, get_all)
        :route({path = '/transactions', method = 'POST'}, transactions)

    if not httpd:start() then
        die('failed to start http server')    
    end
    log.info('started')
    return true
end

return {
    start = start
}

-- vim: ts=4:sw=4:sts=4:et

