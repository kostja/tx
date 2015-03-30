#!/usr/bin/env python
import os
import glob
import sys

def wc_l(filename):
    with open(filename) as f:
        for i, l in enumerate(f):
                pass
    return i + 1

def append(dstfile, filename):
    dst = open(dstfile, "a")
    with open(filename) as f:
       dst.write(f.read()) 
    dst.close()

all_files = glob.glob('*.txt')
all_files.sort()
total_lines = 0

num_files = 2
if len(sys.argv) > 1:
    num_files = int(sys.argv[1])

min_files = len(all_files)/num_files
# force open in the first iteration
files = min_files + 1
dstfile = ""

iteration = 0

for filename in all_files:
    if  files >= min_files:
        dstfile = filename
        files = 1
        canonical_name = "trx{:03}.txt".format(iteration) 
        if dstfile != canonical_name:
            os.rename(dstfile, canonical_name)
            os.rename(dstfile + ".batch",  canonical_name + ".batch")
            dstfile = canonical_name
        print "Creating " + dstfile + "..."
        iteration = iteration + 1
    else:
        print "Appending " + filename + " to " + dstfile
        append(dstfile, filename)
        append(dstfile + ".batch", filename + ".batch")
        files = files  + 1
        os.remove(filename)
        os.remove(filename + ".batch")

