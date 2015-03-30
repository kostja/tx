#!/usr/bin/env python3

import sys
import time
import random
import string

ACCOUNT_MIN=100
ACCOUNT_MAX=50100

'''
- Date in ISO 8601 format;
- Document/transaction identifier: string consisting of upto 50 symbols;
- Source account ID: string consisting of 0-40 symbols;
- Destination account ID: string consisting of 0-40 symbols;
- Amount: decimal number, decimal separator is dot ('.'), no group separator is used.
'''

if __name__ == '__main__':
    if len(sys.argv) > 1:
        count = int(sys.argv[1])
    else:
        count = 100000

    start_time = time.time()
    for tr in range(count):
        date = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(start_time + tr))
        tr_id = ''.join(random.choice(string.ascii_uppercase + string.digits) for _ in range(16)) 
        src_account_id = random.randint(ACCOUNT_MIN, ACCOUNT_MAX - 1)
        dst_account_id = random.randint(ACCOUNT_MIN, ACCOUNT_MAX - 1)
        amount = random.random() * 10000
        print('{0}\t{1}\t{2}\t{3}\t{4:0.2f}'.format(date, tr_id, src_account_id, dst_account_id, amount))


