# Client CLI and Protocol Description

Client is a Java console application provided as a jar file. It allows to perform 3 tasks:

- load data to IMDG from a local file
- perform transactions from a local file on IMDG data
- export data from IMDG to a local file

It can be executed by issuing command:

```
java -jar imdgtest-client-1.0-SNAPSHOT.jar [options] [command] [command options]
```

Each command requires 2 common parameters to be specified:

- Server list - list of HTTP servers that process requests. Specified using "-server [server1],[server2],..." option.
- Client id - an integer that identifies client. Integers from 0 to <number of clients>-1 should be used for this.
  This option determines the first HTTP server that client will try to contact, thus uniform distribution of client
  identifiers is important for load balancing. Specified using "-id [number]" option.

After each command a log file named client-[id].log is created. Note that subsequent runs will overwrite this file.

## Loading data

Data can be loaded to IMDG using ```load``` command. The only required argument to this command is a list of files to load.
Optional ```-batch [number]``` option may be supplied to specify number of records to be processed in one HTTP request.
 
Example:

```
java -jar imdgtest-client-1.0-SNAPSHOT.jar -id 0 -server 127.0.0.1 load account_data.tsv
```

### Data format

Input data is in TSV format (delimited with \x09) encoded using utf-8.
Field values are not quoted (and thus can't contain tabulation symbol).
It has 3 fields:

- Account ID: string consisting of 3-50 symbols;
- Extra data: string consisting of 0-40 symbols;
- Balance: decimal number, decimal separator is dot ('.'), no group separator is used.


## Processing transactions

Transactions are processed using ```exec-trans``` command. The only required argument to this command is a list of files with
transactions to process. Optional ```-batch [number]``` option may be supplied to specify number of transactions
to be processed in one HTTP request.

Example:

```
java -jar imdgtest-client-1.0-SNAPSHOT.jar -id 0 -server 127.0.0.1 exec-trans transactions.tsv
```

### Data format

Input data is in TSV format (delimited with \x09) encoded using utf-8.
Field values are not quoted (and thus can't contain tabulation symbol).
It has 5 fields:

- Date in ISO 8601 format;
- Document/transaction identifier: string consisting of upto 50 symbols;
- Source account ID: string consisting of 0-40 symbols;
- Destination account ID: string consisting of 0-40 symbols;
- Amount: decimal number, decimal separator is dot ('.'), no group separator is used.

## Exporting data from IMDG

Accounts data can be exported to a local file using ```save``` command.
The only required argument to this command is ```-out [filename]``` option that specifies output file name.

Example:

```
java -jar imdgtest-client-1.0-SNAPSHOT.jar -id 0 -server 127.0.0.1 save -out new_account_data.tsv
```

File format is identical to the format used for loading account data.

## Server API

HTTP server used by this client should be able to process following requests:

- ```POST /bulk_load?count=[number]```: load data for a number of account from posted data (application/octet-stream) that has
  the same format as input file for ```load``` client command. URI parameter ```count``` specifies number of records in posted data.
- ```POST /transactions?count=[number]```: process a number of transactions from posted data (application/octet-stream) that has
  the same format as input file for ```exec-trans``` client command. URI parameter ```count``` specifies number of records in posted data.
- ```GET /get_all```: return data for all accounts as application/octet-stream in the same format as input file for
  ```load``` client command.
