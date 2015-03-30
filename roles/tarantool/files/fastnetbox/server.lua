#!/usr/bin/env tarantool

box.cfg {
    wal_mode = 'none';
    listen = 12345;
}

if not box.space.accounts then
    log.info('bootstraping database...')
    box.schema.user.create('user', { password = 'pass' })
    box.schema.user.grant('user', 'read,write,execute', 'universe')
    local transactions = box.schema.create_space('transactions')
    transactions:create_index('primary', {type = 'hash', parts = {1, 'str'}})
    transactions:create_index('queue', {type = 'tree', parts = {2, 'num', 1, 'str'}})
    local accounts = box.schema.create_space('accounts')
    accounts:create_index('primary', {type = 'hash', parts = {1, 'str'}})
    log.info('bootstrapped') 
end

box.space.accounts:truncate()

require('console').start()
