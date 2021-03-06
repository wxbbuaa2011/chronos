## Input
## 1. agfi_list.txt, 
## 2. experiments.txt where each line is [app-name, app-tag, n_tiles, n_threads] 

## Runs the specified experiments. The output of each will be placed in
## validation/runs/<date>/app_tiles_threads.txt

import os
import sys
import datetime
from os import listdir

def run_cmd(cmd):
    print(cmd)
    os.system(cmd)

if len(sys.argv)<2:
    print("Usage: python run.py agfi_list.txt")
    exit(0)

## Save this before we go jumping around
scripts_dir = os.getcwd()

## Read agfi-list
fagfi = open(sys.argv[1], "r")
agfi_list = {} ## indexed by agfi-tag
inputs_list = {}
for line in fagfi:
    s = line.split();
    agfi_list[s[0]] = s[1]

print(agfi_list)

# Initialize with a random agfi
agfi = agfi_list[ list(agfi_list)[0]]
cmd = "sudo fpga-load-local-image -S 0 -I " + agfi
run_cmd(cmd)

downloaded_inputs = listdir("../inputs")
#AWS_PATH = "~/.local/bin/aws"
AWS_PATH = "aws"

## Read experiments

## The inputs are locates in a Zenodo hosted zip file
## The experiments.txt file specifies the 
## 1. The link to the zip file
## 2. The input file names for each application
## 3. The experiments to run with these inputs 
#   Where each experiment is a tuple [app, agfi-tag, n_tiles, n_threads]
S3_BUCKET = "chronos_inputs"
fexp = open("experiments.txt", "r")
tests = []
for line in fexp:
    if line.startswith("zenodo"):
        url = line.split()[1]
        print(url)
	if 'chronos-inputs.zip' not in downloaded_inputs:
	    os.chdir("../inputs/")
	    run_cmd("wget "+url)
	    run_cmd("unzip chronos-inputs.zip") 
	    os.chdir(scripts_dir)
    if line.startswith("input"):
        s = line.split()
        app = s[1]
        s3_loc = s[2]
        file_name = s[2].split("/")[-1]
        inputs_list[app] = file_name
    if line.startswith("test"):
        s = line.split()
        tests.append([s[1], s[2], s[3], s[4]])

print(inputs_list)
print(tests)

## Locate runtime (and compile if necessary)
if "test_chronos" not in listdir("../../software/runtime"):
    os.chdir("../../software/runtime")
    os.system("make")
    os.chdir(scripts_dir)

if "test_chronos" not in listdir("../../software/runtime"):
    print("ERROR: Runtime cannot be compiled. Please investigate manually....")
    exit(0)


d = datetime.datetime.today()
index = 0
runs = listdir("../runs")
while(True):
    dirname = str(d.year) + "-" + format(d.month, '02') + "-" + format(d.day,'02') + "_" +  format(index, '02')
    if dirname not in runs:
        print("creating directory "+dirname)
        os.mkdir("../runs/" + dirname)
        os.chdir("../runs/" + dirname)
        print(os.getcwd())
        runs_dir = os.getcwd()
        break
    index = index+1


## Runs the specified experiments and save the output to ...

n_repeats = 10;

for t in tests:
    app = t[0]
    riscv=False
    Throttle=False
    if app.startswith("riscv"):
	    riscv=True
	    app = app.split("_")[1]
    if app.startswith("throttle"):
        riscv=True
        Throttle=True 
        app = app.split("_")[1]
    if (t[1] not in agfi_list):
        print("%s not found in agfi-list" % t[1])
        continue
    agfi = agfi_list[t[1]]
    n_tiles = t[2]
    n_threads = t[3]

    for r in range(n_repeats):
        cmd = "sudo fpga-load-local-image -S 0 -I " + agfi
        run_cmd(cmd)
        cmd = "sudo ../../../software/runtime/test_chronos --n_tiles=" +n_tiles
        if (Throttle):
            cmd += " --rate_ctrl=16 "
        cmd += " --n_threads=" + n_threads +" " + app  
        cmd += " ../../inputs/chronos-inputs/" + inputs_list[app]
	if (riscv):
	    cmd +=" ../../../riscv_code/binaries/" + app + ".hex"
        cmd += " | tee " + t[1]
	if (riscv):
	    cmd += "_"+app
	cmd +=  "_tiles_"+n_tiles+"_threads_"+n_threads
        cmd += "_"+str(r) +".result" 
        run_cmd(cmd)
	#exit(0)

os.chdir(scripts_dir)




