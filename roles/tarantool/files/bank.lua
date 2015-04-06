#!/usr/bin/env tarantool

local fiber = require('fiber')
local log = require('log')
local http_server = require('http.server')
local fun = require('fun')
local shard = require('shard')

local trx_workers_n = 4 -- workers_n/2 

local STATE_NEW = 0
local STATE_INPROGRESS = 1
local STATE_HANDLED = 2

local function die(msg, ...)
    local err = string.format(msg, ...)
    log.error(err)
    error(err)
end

local function shard2(a, b)
    local shards = {}
    for _, server in ipairs(shard.shard(a)) do
        shards[server] = server
    end
    for _, server in ipairs(shard.shard(b)) do
        shards[server] = server
    end
    return shards
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

local trxq_wakeup

local function queue_handler(self, fun)
    fiber.name('queue/handler')
    while true do
        local args = self.ch:get()
        if not args then
            break
        end
        local status, reason = pcall(fun, args)
        if not status then
            if not self.error then
                self.error = reason
                -- stop fiber queue
                self.ch:close()
            else
                self.error = self.error.."\n"..reason
            end
            break
        end
    end
    self.chj:put(true)
end

local queue_mt
local function queue(fun, workers)
    -- Start fiber queue to processes transactions in parallel
    local channel_size = math.min(workers, 1000)
    local ch = fiber.channel(workers)
    local chj = fiber.channel(workers)
    local self = setmetatable({ ch = ch, chj = chj, workers = workers }, queue_mt)
    for i=1,workers do
        fiber.create(queue_handler, self, fun)
    end
    return self
end

local function queue_join(self)
    log.debug("queue.join(%s)", self)
    -- stop fiber queue
    while self.ch:is_closed() ~= true and self.ch:is_empty() ~= true do
        fiber.sleep(0)
    end
    self.ch:close()
    -- wait until fibers stop

    for i = 1, self.workers do
        self.chj:get()
    end
    log.debug("queue.join(%s): done", self)
    if self.error then
        return error(self.error) -- re-throw error
    end
end

local function queue_put(self, arg)
    self.ch:put(arg)
end

queue_mt = {
    __index = {
        join = queue_join;
        put = queue_put;
    }
}

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
            --table.insert(batches, tuple)
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
    local q = queue(load_batch, shard.len())
    for server, batch in pairs(batches) do
        q:put({server, batch.tuples})
    end

    -- stop fiber queue
    q:join()
    log.info('loaded %s accounts', i)
    batches = nil
    collectgarbage('collect')
    return self:render({ text = string.format('loaded %s accounts', i) })
end 

local SAVE_BATCH_SIZE = 50

local function get_all_iter(paramx, state)
    local gen, param = paramx[1], paramx[2]
    local statenew
    result = {}
    local i = 0
    for state, tuple in gen, param, state do
        result[i+1] = string.format('%s\t%s\t%s\n', tuple[1], tuple[3], frommoney(tuple[2]))
        statenew = state
        i = i + 1
        if i >= SAVE_BATCH_SIZE then
           break
        end
    end
    fiber.sleep(0)
    return statenew, table.concat(result)
end

-- transactions queued for local execution but not executed yet
--
transaction_queue = {}
--  transactions executed locally, but perhaps not yet
--  executed globally. transasctions executed globally
--  are removed forever
transaction_history = {}
-- used only during recovery, for parallel recovery
--
transaction_inprogress = {}

local function has_outstanding_transactions()
    for k,v in pairs(transaction_queue) do
        return true
    end
    for k,v in pairs(transaction_inprogress) do
        return true
    end
    return false
end

local function get_all(self)
    trxq_wakeup()
    local i = 0
    local delay = 0.01
    while has_outstanding_transactions() do
        if i % 120 == 0 then
            count = 0
            for _ in pairs(transaction_queue) do count = count + 1 end
            for _ in pairs(transaction_inprogress) do count = count + 1 end
            -- log at least once
            log.info("waiting for %d outstanding transactions", count)
        end
        i = i + 1
        delay = math.min(delay * 2, 1)
        fiber.sleep(delay)
    end
    local gen, param, state = box.space.accounts:pairs()
        return self:iterate(get_all_iter, {gen, param}, state)
end

function find_transaction(id)
    return transaction_queue[id] ~= nil or transaction_history[id] ~= nil
            or transaction_inprogress[id] ~= nil
end

-- called from a remote host
function queue_transaction(tuples, ack_queue, purge_queue)
    for k, v in pairs(ack_queue) do
        local tuple = transaction_queue[v]
        if tuple == nil then
            if transaction_history[v] == nil then
                log.error("lost a transaction to execute,  %s", v)
            end
        else
            local id, src, dst, amount = tuple[1], tuple[2], tuple[3], tuple[4]

            box.begin()
            box.space.accounts:update(src, {{ '-', 2, amount }})
            box.space.accounts:update(dst, {{ '+', 2, amount }})
            box.commit()
            log.debug('executing transaction, %s', v)
            -- preserve this transaction in history until we know
            -- that all nodes have executed it
            transaction_history[id] = true 
            -- we no longer need it in the queue
            transaction_queue[id] = nil
        end
    end
    for k,v in pairs(purge_queue) do
        if transaction_history[v] == nil then
            log.error("double deletion of transaction %s", v)
        else
            log.debug("deleting transaction %s", v)
            transaction_history[v] = nil
        end
    end
    -- queue pushed tuples
    for k, v in pairs(tuples) do
        local id = v[1]
        if transaction_queue[id] ~= nil or transaction_history[id] ~= nil then
--            log.error('double queueing %s', id)
        else
            log.debug('queueing transaction, %s', id)
            transaction_queue[id] = v
        end
    end
end

local function recover_transaction(tuple)
    local id, src, dst, amount = unpack(tuple)
    transaction_inprogress[id] = tuple
    transaction_queue[id] = nil
    local delay = 0.01
    for i=1,100 do
        local failed = nil
        local shards = shard2(src, dst)
        for _, server in pairs(shards) do
            -- check that transaction is queued to all hosts
            local status, reason = pcall(function()
                return server.conn:timeout(shard.REMOTE_TIMEOUT):call("find_transaction", id) ~= nil
            end)
            if not status or not reason then
                -- wait until transaction will be queued on all hosts
                failed = server.uri
                break
            end
        end
        if failed == nil then
            break
        end
        fiber.sleep(delay)
        delay = math.min(delay * 2, 5)
    end
    -- queue_transaction checks that transaction is in transaction_queue
    -- put it there
    transaction_inprogress[id] = nil
    transaction_queue[id] = tuple
    if failed == nil then
        local status, reason = pcall(queue_transaction, {}, { id }, {})
        if status then
            transaction_history[id] = true 
            transaction_inprogress[id] = nil
        end
    else
        log.error("failed to process transaction=%s failed_host=%s", id, failed)
    end
end

local function trxq_manager_loop()
    fiber.name("trxq/handler")
    local delay = 0.01
    while true do
        local tuple
        for k, v in pairs(transaction_queue) do
            tuple = v
            break
        end
        if tuple then
            recover_transaction(tuple)
            delay = 0.01
        else
            fiber.sleep(delay)
            delay = math.min(delay * 2, 5)
        end
    end
end

local trxq_started = false
function trxq_wakeup()
    if trxq_started then
        return
    end
    -- Create fibers to handle transactions
    trxq_started = true
    for i=1,trx_workers_n do
        fiber.create(trxq_manager_loop)
    end
end

local function table_merge(dst, src)
    local n = #dst
    for i, val in ipairs(src) do
        dst[n + i] = val
    end
end

local function push_transaction(task)
    local server = task.server
    log.debug("push_transaction(%d, %s)", task.queue_len, server.uri)
    local ack_queue = server.ack_queue
    server.ack_queue = {}
    local purge_queue = server.purge_queue
    server.purge_queue = {}
    -- queue transactions
    local status, reason = pcall(function()
        server.conn:timeout(shard.REMOTE_TIMEOUT):call("queue_transaction",
            task.tuples, ack_queue, purge_queue)
    end)
    if not status then
        table_merge(server.ack_queue, ack_queue)
        table_merge(server.purge_queue, purge_queue)
        die('failed to queue transactions on %s, %s', server.uri, reason)
    end
    table_merge(server.purge_queue, ack_queue)
    table_merge(server.ack_queue, task.push_queue)
    log.debug("push_transaction(%d, %s) done", task.queue_len, server.uri)
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
        local date, id, src, dst, amount = line:match("([0-9%-]+%s+[0-9%-%:%.]+)%s+([%d%-]+)%s+([%d%-]+)%s+([%d%-]+)%s+([%d%.]+)")
        if not date then
            die('invalid line in /transactions: [%s]', line) 
        end
        amount = tomoney(amount)
        local shards = shard2(src, dst)
        for _, server in pairs(shards) do
            local tuple = {id, src, dst, amount}
            local task = tasks[server]
            if task == nil then
                task = {
                    server = server;
                    queue_len = 1;
                    push_queue = { id };
                    tuples = { tuple };
                }
                tasks[server] = task
                tasks_n = tasks_n + 1
            else
                task.queue_len = task.queue_len + 1
                task.push_queue[task.queue_len] = id
                task.tuples[task.queue_len] = tuple
            end
        end
        i = i + 1
        if i % 10000 == 0 then
           log.debug('queued %d transactions', i)
        end
    end
    local q = queue(push_transaction, tasks_n)
    for server, task in pairs(tasks) do
        q:put(task)
    end
    q:join()
--    log.info('queued %d transactions, done %s ms', i, (fiber.time() - now)*1000)
    return self:render({ text = string.format('processed %d transactions', i) })
end

-- shard server init additional fields
local function cb_shard_init(srv)
    srv.ack_queue = {}
    srv.purge_queue = {}
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
        local transactions = box.schema.create_space('transactions')
        transactions:create_index('primary', {type = 'hash', parts = {1, 'str'}})
        transactions:create_index('queue', {type = 'tree', parts = {2, 'num', 1, 'str'}})
        local accounts = box.schema.create_space('accounts')
        accounts:create_index('primary', {type = 'hash', parts = {1, 'str'}})
        log.info('bootstrapped') 
    end

    -- Start binary port
    box.cfg { listen = cfg.binary }

    -- Initialize shard
    shard.init(cfg, cb_shard_init)

    -- Change state of all INPROGRESS tasks to NEW
    for _, tuple in ipairs(box.space.transactions.index.queue:
        select(STATE_INPROGRESS, { iterator = eq })) do
        box.space.transactions:update(tuple[1], {{ '=', 2, STATE_NEW }})
    end

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

