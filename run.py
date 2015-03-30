#!/usr/bin/env python
# -*- coding: utf-8 -*-

##

import os
import sys
import logging
import yaml
import time
import csv
import ansible
import ansible.playbook
import ansible.color
import getpass
import time

#
# Utils
#

def populate_hosts(inventory, benchmark, what):
    count = benchmark[what + '_count']
    hosts = cfg[what + '_hosts']
    host_count = len(hosts)
    if what == 'server':
        host_count = min(host_count, benchmark['host_count'])
    per_host = count / host_count
    if count % host_count != 0: per_host += 1
    for hostname in hosts:
        host = inventory.get(hostname, None)
        if host is None:
            host = {}
            inventory[hostname] = host
        host[what + '_count'] = hostname != hosts[-1] and per_host or count
        print 'host', what, host[what + '_count']
        count -= per_host
        if count <= 0:
            break

def create_inventory(benchmark):
    inventory_hosts = {}
    populate_hosts(inventory_hosts, benchmark, 'client')
    populate_hosts(inventory_hosts, benchmark, 'server')
    sb = []
    sb.append('localhost ansible_connection=local')
    sb.append('[hosts_all]')
    for hostname in cfg['client_hosts']:
         sb.append(hostname)
    for hostname in cfg['server_hosts']:
         sb.append(hostname)
    sb.append('')
 
    sb.append('[hosts]')
    sb.append('')
    for (hostname, opts) in inventory_hosts.items():
        sb.append("{0} server_count={1} client_count={2} prefix=bench-{3}- "
            "redundancy={4} batch={5} hardware_failure={6} arena={7:.2f}".format(
                hostname, opts.get('server_count', 0),
                opts.get('client_count', 0), benchmark['benchmark_id'],
                benchmark['redundancy'], benchmark['batch'] and '1' or '0',
                benchmark['hardware_failure'] and '1' or '0',
                float(cfg.get('arena', 100) * benchmark['host_count']) / benchmark['server_count']))
    sb.append('')
    data = '\n'.join(sb)
    log.debug("inventory file (hosts):\n%s", data)
    with open('hosts', 'w+') as inventory_file:
        inventory_file.write(data)
    return ansible.inventory.Inventory('hosts')

def ansible_display(msg, color=None, stderr=False, screen_only=False,
                    log_only=False, runner=None):
    if stderr:
        log.error(msg)
    else:
        log.info(msg)

def ansible_run(pb):
    results = pb.run()
    failed = False
    for host, info in results.iteritems():
        if info['failures'] != 0:
            log.error("host %s failed", host)
            failed = True
    if failed:
        log.error("failed to continue benchmark")
        return False
    return True

#
# Configure logging
#

log = logging.getLogger('benchmark')
log.setLevel(logging.DEBUG)
formatter = logging.Formatter('%(asctime)s %(levelname)-5s: %(message)s')
console_handler = logging.StreamHandler()
console_handler.setFormatter(formatter)
log.addHandler(console_handler)
file_handler = logging.FileHandler('all.log')
file_handler.setFormatter(formatter)
log.addHandler(file_handler)
log.info("started")
# Hack ansible to log to our logger object
ansible.callbacks.display = ansible_display

#
# Parse configuration
#

log.debug("parsing configuration file")
cfg = {}
with open('config.yml', 'r') as cfgfile:
    cfg = yaml.load(cfgfile)[0]
log.debug("done")

log.debug("parsing benchmarks configuration")
benchmarks = []
with open('benchmarks.csv', 'r') as csvfile:
    csvreader = csv.reader(csvfile, delimiter='\t')
    next(csvreader, None) # skip header
    for row in csvreader:
        benchmark = {
            'benchmark_id': int(row[0]),
            'host_count': int(row[1]),
            'server_count': int(row[2]),
            'client_count': int(row[3]),
            'redundancy': int(row[4]),
            'batch': row[5].lower() == 'Да' or row[5] == '1',
            'hardware_failure': row[6].lower() == 'Да' or row[6] == '1'
        }
        benchmarks.append(benchmark)
log.debug("done")

# Ask sudo password
sudo_pass = ""
if cfg['sudo']:
    sudo_pass = getpass.getpass("sudo password> ")

timeout = cfg['ansible_timeout']

# Create direcotry for results
os.mkdir('out')

for benchmark in benchmarks:
    result_dir = os.path.join('out', str(benchmark['benchmark_id']))
    client_dir = os.path.join('roles', 'client', 'files')
    os.mkdir(result_dir)
    #
    # Add extra logging target
    #
    fh = logging.FileHandler(os.path.join(result_dir, "benchmark.log"))
    fh.setFormatter(formatter)
    log.addHandler(fh)

    log.info("benchmark #%(benchmark_id)s: server_count=%(server_count)s "
             "client_count=%(client_count)s batch=%(batch)s "
             "hardware_failure=%(hardware_failure)s", benchmark)

    #
    # Create inventory
    #
    inventory = create_inventory(benchmark)
    for host in inventory.get_hosts('hosts'):
        log.info("host %s server_count=%s client_count=%s",
            host.name, host.vars['server_count'], host.vars['client_count'])

    stats = ansible.callbacks.AggregateStats()
    playbook_cb = ansible.callbacks.PlaybookCallbacks(
        verbose=ansible.utils.VERBOSITY)
    runner_cb = ansible.callbacks.PlaybookRunnerCallbacks(stats,
        verbose=ansible.utils.VERBOSITY)
    #
    # Cleanup containers
    #
    log.info("cleanup containers")
    pb = ansible.playbook.PlayBook(
        playbook='04_cleanup_containers.yml',
        inventory=inventory,
        forks=len(inventory.get_hosts('hosts_all')) + 5,
        callbacks=playbook_cb,
        runner_callbacks=runner_cb,
        stats = stats,
        sudo_pass = sudo_pass,
        sudo = cfg['sudo'],
        timeout = timeout,
        any_errors_fatal = True
    )
    if not ansible_run(pb):
        continue
 
    #
    # Build containers
    #
    log.info("build containers")
    pb = ansible.playbook.PlayBook(
        playbook='05_create_containers.yml',
        inventory=inventory,
        forks=len(inventory.get_hosts('hosts')) + 5,
        callbacks=playbook_cb,
        runner_callbacks=runner_cb,
        stats = stats,
        sudo_pass = sudo_pass,
        sudo = cfg['sudo'],
        timeout = timeout,
        any_errors_fatal = True
    )
    if not ansible_run(pb):
        continue
    try:
        with open('containers', 'r') as inventory_file:
            log.debug("inventory file (containers):\n%s", inventory_file.read())
            containers = ansible.inventory.Inventory('containers')
        log.info("done")
    except:
        log.exception("failed to build containers")
        continue
    #
    # Prepare data directory
    #
    trx_dir = os.path.join(client_dir, "trx")
    accounts_dir = os.path.join(client_dir, "accounts")
    if os.path.lexists(trx_dir):
        log.info("exists: %s", trx_dir)
        os.unlink(trx_dir)
    if os.path.lexists(accounts_dir):
        log.info("exists: %s", accounts_dir)
        os.unlink(accounts_dir)
    new_trx_dir = "trx-{0}".format(benchmark['client_count'])
    new_accounts_dir = "accounts-{0}".format(benchmark['client_count'])
    log.info('using accounts from %s', os.path.join(client_dir, new_accounts_dir))
    os.symlink(new_accounts_dir, accounts_dir)
    log.info('using transactions from %s', os.path.join(client_dir, new_trx_dir))
    os.symlink(new_trx_dir, trx_dir)

    time.sleep(5)

    #
    # Test connection
    #
    for i in range(3):
        log.info("ping")
        pb = ansible.playbook.PlayBook(
            playbook='06_ping.yml',
            inventory=containers,
            forks=benchmark['server_count'] + 5,
            callbacks=playbook_cb,
            runner_callbacks=runner_cb,
            stats = stats,
            timeout = timeout
        )
        if not ansible_run(pb):
            continue

    #
    # Deploy cluster
    #
    log.info("deploy cluster")
    pb = ansible.playbook.PlayBook(
        playbook='10_deploy_cluster.yml',
        inventory=containers,
        forks=benchmark['server_count'] + 5,
        callbacks=playbook_cb,
        runner_callbacks=runner_cb,
        stats = stats,
        timeout = timeout,
        any_errors_fatal = True
    )
    if not ansible_run(pb):
        continue
    log.info("done")

    #
    # Run benchmark
    #
    log.info("run benchmark")
    pb = ansible.playbook.PlayBook(
        playbook='15_run_benchmark.yml',
        inventory=containers,
        forks=benchmark['client_count'] + 5,
        callbacks=playbook_cb,
        runner_callbacks=runner_cb,
        stats = stats,
        timeout = timeout
    )
    pb.run()
    log.info("done")

    #
    # Fetch statistics
    #
    log.info("fetch statistics")
    pb = ansible.playbook.PlayBook(
        playbook='20_fetch_sar.yml',
        inventory=inventory,
        forks=len(inventory.get_hosts('hosts')) + 5,
        callbacks=playbook_cb,
        runner_callbacks=runner_cb,
        stats = stats,
        sudo_pass = sudo_pass,
        sudo = cfg['sudo'],
        timeout = timeout,
    )
    pb.run()
    try:
        for host in inventory.get_hosts('hosts'):
            src_path = os.path.join(client_dir, 'results', host.name + '.sar')
            dst_path = os.path.join(result_dir, host.name + '.sar')
            os.rename(src_path, dst_path)
        log.info("done")
    except:
        log.exception("failed to fetch statistics")

    #
    # Fetch logs
    #
    log.info("fetch logs")
    pb = ansible.playbook.PlayBook(
        playbook='18_fetch_logs.yml',
        inventory=containers,
        forks=benchmark['server_count'] + 5,
        callbacks=playbook_cb,
        runner_callbacks=runner_cb,
        stats = stats,
        timeout = timeout
    )
    pb.run()
    try:
        for host in containers.get_hosts('tarantool_containers'):
            src_path = os.path.join(client_dir, 'results', host.name + '.log')
            dst_path = os.path.join(result_dir, host.name + '.log')
            os.rename(src_path, dst_path)
        log.info("done")
    except:
        log.exception("failed to fetch logs")

    log.info("done")

    log.info("prepare report")
    try:
        times = {}
        for what in ('start', 'load', 'exec', 'save'):
            src_path = os.path.join(client_dir, 'results', '.timestamp_' + what)
            dst_path = os.path.join(result_dir, '.timestamp_' + what)
            os.rename(src_path, dst_path)
            with open(dst_path) as f:
                times[what] = int(f.read())
        load_time = times['load'] - times['start']
        exec_time = times['exec'] - times['load']
        save_time = times['save'] - times['exec']
        log.info("load time: %d s", load_time)
        log.info("exec time: %d s", exec_time)
        log.info("save time: %d s", save_time)
        os.rename(os.path.join(client_dir, "results", "_results.txt"),
                  os.path.join(result_dir, "_results.txt"))
    except:
        log.exception("failed to prepare report")

    #
    # Move results
    #
    for i in range(benchmark['client_count']):
        for what in ("load", "exec", "save"):
            name = 'client-{0:d}-{1}.log'.format(i, what)
            src_path = os.path.join(client_dir, 'results', name)
            dst_path = os.path.join(result_dir, name)
            try:
                os.rename(src_path, dst_path)
            except:
                log.exception("failed to move %s to %s for client_id=%d",
                              i, src_path, dst_path)

        name = 'accounts{0:03d}.tsv'.format(i)
        src_path = os.path.join(client_dir, 'results', name)
        dst_path = os.path.join(result_dir, name)
        try:
           os.rename(src_path, dst_path)
        except:
            log.exception("failed to move file %s to %s for client_id=%d",
                i, src_path, dst_path)

    os.unlink(trx_dir)
    os.unlink(accounts_dir)

    log.info("benchmark #%(benchmark_id)s is done", benchmark)
    log.removeHandler(fh)
