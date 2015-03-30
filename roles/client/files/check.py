#!/usr/bin/env python3

import sys
import time
import os
import sqlite3
import csv
import logging
import shutil

CLIENT_DIR = os.path.abspath("../../client/files")

if len(sys.argv) < 2:
    print('Usage: {} client_count'.format(sys.argv[0]), file = sys.stderr)
    sys.exit(-1)
client_count = int(sys.argv[1])

##

os.chdir(os.path.join(CLIENT_DIR, "results"))

log = logging.getLogger('checker')
log.setLevel(logging.DEBUG)
console_handler = logging.StreamHandler()
log.addHandler(console_handler)
file_handler = logging.FileHandler('checker.log')
log.addHandler(file_handler)
log.info("started")

conn = sqlite3.connect('accounts.db')
cur = conn.cursor()
cur.executescript("""
    PRAGMA synchronous = OFF;
    PRAGMA journal_mode = OFF;
""")

cur.executescript(
"""
    CREATE TABLE account (
        account_id VARCHAR(64) PRIMARY KEY,
        balance INT8 NOT NULL
    );
""");

conn.commit()

def tomoney(s):
    parts = s.split(".")
    if len(parts) == 1:
        return int(parts[0]) * 100
    elif len(parts) == 2:
        if len(parts[0]) == 0:
            m1 = 0
        else:
            m1 = int(parts[0])
        if len(parts[1]) == 0:
            return m1
        elif len(parts[1]) == 2:
            return m1 * 100 + int(parts[1])
        elif len(parts[1]) == 1:
            return m1 * 100 + int(parts[1]) * 10
    raise ValueError('tomoney: ' + s)

log.info("importing accounts...")
for client_id in range(client_count):
    path = os.path.join(CLIENT_DIR, "accounts",
        "accounts{:03d}".format(client_id))
    log.info('importing %s', path)
    with open(path, 'r') as csvfile:
        reader = csv.reader(csvfile, delimiter = '\t')
        for (account_id, info, balance_str) in reader:
            balance = tomoney(balance_str)
            cur.execute("INSERT INTO account (account_id, balance) "+
                        " VALUES(?, ?)", (account_id, balance))
    conn.commit()

log.info("processing transactions...")
for client_id in range(client_count):
    path = os.path.join(CLIENT_DIR, "trx",
        "trx{:03d}.txt".format(client_id))
    log.info('processing %s', path)
    with open(path, 'r') as csvfile:
        reader = csv.reader(csvfile, delimiter = '\t')
        for (date, trx_id, src, dst, amount_str) in reader:
            amount = tomoney(amount_str)
            cur.execute("""
                UPDATE account SET balance = balance - ?
                WHERE account_id = ?
            """, (amount, src))
            cur.execute("""
                UPDATE account SET balance = balance + ?
                WHERE account_id = ?
            """, (amount, dst))
            conn.commit()

ok = True
log.info("checking accounts...")
for client_id in range(client_count):
    path = os.path.join(CLIENT_DIR, "results",
        "accounts{:03d}.tsv".format(client_id))
    log.info('checking %s', path)
    with open(path, 'r') as csvfile:
        reader = csv.reader(csvfile, delimiter = '\t')
        for (account_id, info, balance_str) in reader:
            balance = tomoney(balance_str)
            cur.execute("SELECT balance FROM account WHERE account_id = ?",
                        (account_id,))
            row = cur.fetchone()
            if row is None:
                log.error("invalid account_id=%s in file=%s", account_id, path)
                ok = False
                continue
            real_balance = row[0]
            if real_balance != balance:
                log.error("invalid balance for account_id=%s in file=%s:"+
                          "expected=%s got=%s", account_id, path, real_balance,
                          balance)
                ok = False

if ok:
    log.info("OK!")
    os.chdir("..")
    shutil.rmtree(prefix)
    sys.exit(0)
log.error("invalid results")
sys.exit(2)
