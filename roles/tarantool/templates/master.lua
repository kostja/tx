#!/usr/bin/env tarantool

local bank = require('bank')

local cfg = {
    servers = {
{% for host in groups['tarantool_containers'] %}
    { uri = [[{{ hostvars[host]['ansible_ssh_host'] }}:{{ hostvars[host]['tarantool_port'] }}]]; zone=[[{{ hostvars[host]['zone'] }}]]};
{% endfor %}
    };
    http = {{ http_port_to_expose }};
    login = 'tester';
    password = 'pass';
    redundancy = {{ redundancy }};
    binary = {{ tarantool_port_to_expose }}
}

box.cfg {
    slab_alloc_arena = {{ arena }};
    slab_alloc_factor = 1.06;
    slab_alloc_minimal = 16;
    wal_mode = 'none';
}

bank.start(cfg)
-- vim: ts=4:sw=4:sts=4:et
