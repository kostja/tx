## Prerequisites

 1. Add your public ssh key to `~/.ssh/authorized_keys` on all physical hosts
 2. Run ssh-add `~/.ssh/id_rsa` on **your** host
 3. Select one physical host to be ansible controller
 4. Connect to the controller using `ssh -A controller.hostname`
 5. Check that you can connect to any physical hosts **from the controller**
    without entering password and private key
 6. Install ansible (ansible 1.7.2 was tested)
 7. Configure `hosts` inventory file for ansible (see `hosts.example`)
 8. Setup physical hosts (run one):

    ansible-playbook -i hosts 00_prepare_hosts.yml -K --forks 10

 9. Configure network - each Docker container must have access to others
10. Run benchmark step-by-step (see `Manual mode` below) or
    in batch mode (see `Batch mode`)

## Manual mode

Create and start containers:

    ansible-playbook -i hosts 05_create_containers.yml -K --forks 10

Deploy Tarantool cluster:

    ansible-playbook -i containers 10_deploy_cluster.yml --forks 100

Put account files to `roles/client/files/accounts/accountsNNN` and
transaction files to `roles/client/files/trx/trxNNN.txt`.

Run benchmark:

    ansible-playbook -i containers 15_run_benchmark.yml --forks 100

Results will be saved to `roles/client/files/results/`

## Batch mode (recommended)

 * Modify `config.yml` and `benchmarks.csv`.
 * Remove old results: ```mv ./out ./out.old```
 * Run script: ```./run.py```

`./run.py` will create ./out directory with results and log files.
Please note that run.py does not execute `00_prepare_hosts.yml` playbook.

## Known issues

 * Default disk size of docker containers (10G) is not enough to fit accounts
   files for some benchmarks. Add OPTIONS=`--storage-opt dm.basesize=30G` to
   `/etc/sysconfig/docker`, stop docker, remove /var/lib/docker and start
   docker again. 

## Utilites

### Check result

```
./roles/client/files/checkpg.py roles/client/files/accounts-24/ roles/client/files/trx-24/ out/12/ 24
```
