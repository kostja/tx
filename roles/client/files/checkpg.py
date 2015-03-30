#!/usr/bin/env python3

import sys
import time
import os
import psycopg2
import logging
import shutil
import csv

if len(sys.argv) < 5:
    print('Usage: {} accounts_dir trx_dir results_dir client_count'.format(sys.argv[0]), file = sys.stderr)
    sys.exit(-1)
accounts_dir = sys.argv[1]
trx_dir = sys.argv[2]
results_dir = sys.argv[3]
client_count = int(sys.argv[4])

##

log = logging.getLogger('checker')
log.setLevel(logging.DEBUG)
console_handler = logging.StreamHandler()
log.addHandler(console_handler)
file_handler = logging.FileHandler(os.path.join(results_dir, 'checker.log'))
log.addHandler(file_handler)
log.info("started")

conn = psycopg2.connect('')
cur = conn.cursor()

def create_schema():
    cur.execute("""
        DROP TABLE IF EXISTS account;
        DROP TABLE IF EXISTS transaction;
        DROP TABLE IF EXISTS account_result;
        CREATE UNLOGGED TABLE account (
            account_id VARCHAR(32) PRIMARY KEY,
            info TEXT,
            balance MONEY NOT NULL
            );
        CREATE UNLOGGED TABLE account_result AS TABLE account;
        CREATE UNLOGGED TABLE transaction (
            transaction_id VARCHAR(32), -- PRIMARY KEY,
            ts timestamp NOT NULL,
            src_id VARCHAR(32) NOT NULL,
            dst_id VARCHAR(32) NOT NULL,
            amount MONEY NOT NULL
            );

        CREATE INDEX transaction_src_id_idx ON transaction (src_id);
        CREATE INDEX transaction_dst_id_idx ON transaction (dst_id);

        CREATE OR REPLACE FUNCTION process() RETURNS void AS $$
            DECLARE
                row RECORD;
        BEGIN
        FOR row IN
            SELECT src_id, dst_id, amount FROM transaction
        LOOP
            UPDATE account SET balance = balance - row.amount
            WHERE account_id = row.src_id;
            UPDATE account SET balance = balance + row.amount
            WHERE account_id = row.dst_id;
        END LOOP;
        END;
        $$ LANGUAGE plpgsql;
    """)
    conn.commit()

def import_accounts():
    log.info("importing accounts...")
    for client_id in range(client_count):
        path = os.path.join(accounts_dir, "accounts{:03d}".format(client_id))
        log.info('importing %s', path)
        with open(path, 'r') as csvfile:
            cur.copy_from(csvfile, 'account', sep='\t',
                columns = ('account_id', 'info', 'balance'))
    conn.commit()

def process_transactions():
    log.info("importing transactions...")
    for client_id in range(client_count):
        path = os.path.join(trx_dir, "trx{:03d}.txt".format(client_id))
        log.info('importing %s', path)
        with open(path, 'r') as csvfile:
            cur.copy_from(csvfile, 'transaction', sep='\t',
                columns = ('ts', 'transaction_id', 'src_id', 'dst_id', 'amount'))
    conn.commit()

    log.info("processing transactions...")
    cur.callproc("process");
    conn.commit();

#log.info("importing results...")
#for client_id in range(client_count):
#    path = os.path.join(results_dir, "accounts{:03d}.tsv".format(client_id))
#    log.info('importing %s', path)
#    with open(path, 'r') as csvfile:
#        cur.copy_from(csvfile, 'account_result', sep='\t',
#            columns = ('account_id', 'info', 'balance'))
#    conn.commit()

log.info("checking results...")
#cur.execute("""
#    SELECT o.account_id AS orig_id, o.balance AS orig_balance,
#           n.account_id AS new_id, n.balance AS new_balance
#    FROM account o
#    FULL OUTER JOIN account_result n USING(account_id)
#    WHERE o.balance != n.balance OR
#          o.account_id IS NULL OR
#          n.account_id IS NULL
#""")
#while True:
#    row = cur.fetchone()
#    if row == None:
#        break;
#    (orig_id, orig_balance, new_id, new_balance) = row
#    if orig_id != new_id:
#        log.info("invalid account: orig=%s new=%s",
#            orig_id, new_id)
#    elif orig_balance != new_balance:
#        log.error("invalid balance: account=%s, expected=%s, got=%s",
#            orig_id, orig_balance, new_balance)
#    else:
#        raise Exception('Invalid row: '+ str(row))

def check():
    ok = True
    for client_id in range(client_count):
        path = os.path.join(results_dir, "accounts{:03d}.tsv".format(client_id))
        log.info('checking %s', path)
        with open(path, 'r') as csvfile:
            reader = csv.reader(csvfile, delimiter = '\t')
            for (account_id, info, balance_str) in reader:
                cur.execute("""SELECT balance, %s::money FROM account WHERE
                    account_id = %s""", (balance_str, account_id,))
                row = cur.fetchone()
                if row is None:
                    log.error("invalid account_id=%s in file=%s", account_id,
                        path)
                    ok = False
                    print('ok', False)
                    continue
                real_balance = row[0]
                balance = row[1]
                if real_balance != balance:
                    log.error("invalid balance for account_id=%s in file=%s: "+
                            "expected=%s got=%s", account_id, path,
                            real_balance, balance)
                    ok = False
                    print('ok', False)
                #else:
                #    print('ok', row[0], real_balance, balance)

    print('return', ok)
    return ok

create_schema();
import_accounts();
process_transactions();
ok = check()
if ok:
    log.info("OK!")
    sys.exit(0)
log.error("invalid results")
sys.exit(2)
