#!/usr/bin/env python
import glob
import sys
import os

prefix = "/root/18plus_data/data/trx/"

trx = glob.glob(prefix + "trx*.txt")
trx.sort()
if len(sys.argv) > 1:
    batch = sys.argv[1]
else:
    batch = 6

print(batch)

def fname(i):
    return "trx%03d.txt" %i

def bname(i):
    return "trx%03d.txt.batch" %i

def concat(src, dst):
    fdst = open(dst, "a")
    with open(src, "r") as fsrc:
        fdst.write(fsrc.read())
    fdst.close()

def append(i, id):
    print("Appending {%03d} to {%03d}" % (i, id))
    concat(prefix + fname(i), fname(id))
    concat(prefix + bname(i), bname(id))

i = 0
new_id = 0
old_id = 0

for v in trx:
    if  i != 0 and i < batch: 
        append(old_id, new_id)
        i = i + 1
    else:
        if old_id != 0:
            new_id = new_id + 1
        append(old_id, new_id)
        i = 1
    old_id = old_id + 1


	
# vim: et ts=4 bs=4
