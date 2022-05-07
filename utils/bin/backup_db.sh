#!/bin/bash

## Script can be run with or without parameters.
## TIMESTAMP variable is used to create the backup file in db container
##
##   * with parameter    - $1 is used as value
##   * without parameter - output of $(date +%Y.%m.%d.%H%M%S) is used.
##
TIMESTAMP=${1:-"$(date +%Y.%m.%d.%H%M%S)"}

## Taken from exported variables from docktie
PROJECT_DIR="${DOCKTIE_COMMON_PARENTDIR}"

DB_SERVICE_NAME='mysql'

## Source the env file for dockerized project in docker-compose format.
MAIN_ENV_FILE="$(dirname $DOCKTIE_DOCKER_COMPOSE_FULLPATH)/.env"
if [[ -e $MAIN_ENV_FILE ]]; then
   . $MAIN_ENV_FILE
else
    echo "ERROR: $MAIN_ENV_FILE not found. Aborting!"
    exit 1
fi

## Make sure backup folder exist
BACKUP_DIR="${PROJECT_DIR}/backups"
mkdir -p ${BACKUP_DIR}

DOCKER_COMPOSE_BIN="docker-compose" ## Gets the docker-compose of docktie utils
SHA256SUM_MYSQL_CREDS='c752afe39bdb780ae860eca0d42293a3d1068256c5bf1d04214ccb256de0b69b'

## TODO: Check if docker services are up

## ----------------------------------
## Generate credential file .my.cnf
## ----------------------------------
tmp_mysql_creds=$(mktemp '/tmp/dbbackup_XXXX')
cat > $tmp_mysql_creds << _BLOCK_
[client]
user=root
password=$MYSQL_ROOT_PASSWORD
_BLOCK_

### TODO: Cross-check created temp file to detect for password changes.
###  Maybe, check the $MAIN_ENV_FILE & that of BACKEND & FRONTEND to detect for changes.
##~ c752afe39bdb780ae860eca0d42293a3d1068256c5bf1d04214ccb256de0b69b  /tmp/docktie_kKXN

## Copy credentials file to mysql service as /root/.my.cnf'
##
$DOCKER_COMPOSE_BIN cp $tmp_mysql_creds ${DB_SERVICE_NAME}:/root/.my.cnf

## -------------------------------------------------------
## Generate the backup script
## -------------------------------------------------------
##
## NOTE: For those not too familiar with shell scripting, notice that some variable is escaped (e.g. \${BACKUPFILE})
##       while others are not (e.g. ${MYSQL_DATABASE}).
##
##       Those un-escaped are intended to use the values within this (parent) script, which means, it will no
##       longer a variable in final backup script that would be copied to mysql container/service.
##       
##       For those escaped ones, you may already have guessed by now. Yes, correct: it is intended to be a 
##       variable in the final backup script.
##
tmp_dbdump_script=$(mktemp '/tmp/dbbackup_XXXX')
cat > $tmp_dbdump_script << _BLOCK_
#!/bin/bash

timestamp=\$1

BACKUPFILE="/root/${MYSQL_DATABASE}-backup-\${timestamp}.sql.gz"
mysqldump $MYSQL_DATABASE | gzip > \${BACKUPFILE}
sha256sum \${BACKUPFILE} > \${BACKUPFILE}.sha256
_BLOCK_
chmod +x $tmp_dbdump_script 

DBDUMP_BIN='/root/db-dump.sh'
## Copy the backup script to mysql container
$DOCKER_COMPOSE_BIN cp $tmp_dbdump_script ${DB_SERVICE_NAME}:${DBDUMP_BIN}

## Dump sql database
$DOCKER_COMPOSE_BIN exec ${DB_SERVICE_NAME} ${DBDUMP_BIN} "$TIMESTAMP"

## Copy the file to Docker host machine, including the checksum file
##
BACKUPFILE="/root/${MYSQL_DATABASE}-backup-${TIMESTAMP}.sql.gz"
$DOCKER_COMPOSE_BIN cp ${DB_SERVICE_NAME}:${BACKUPFILE} ${BACKUP_DIR}
$DOCKER_COMPOSE_BIN cp ${DB_SERVICE_NAME}:${BACKUPFILE}.sha256 ${BACKUP_DIR}
##
## ...and check if file was not modified in any way:
##
echo "[INFO] DB backup for '${MYSQL_DATABASE}' copied to ${BACKUP_DIR}..."
echo "[INFO] Checking for backup integrity:"
cd $BACKUP_DIR
sha256sum -c <(sed 's/\/root\///g' $(basename ${BACKUPFILE}.sha256))

## Delete temp files
rm $tmp_dbdump_script
rm $tmp_mysql_creds
