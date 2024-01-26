#!/bin/bash

if [ "${DEBUG}" == "true" ]; then
  set -x
  env
  if [ $# -gt 0 ] ; then
    exec $@
  fi
fi

# Check prerequisites envars
if [ -z "${SRC_RDS_DATABASE}" ]; then
  echo "SRC_RDS_DATABASE not set, exiting"
  exit 1
fi

if [ -z "${SRC_RDS_DATABASE_REGION}" ]; then
  echo "SRC_RDS_DATABASE_REGION not set, exiting"
  exit 1
fi

if [[ -z "${CRR_REGION}" && -z "${CAR_REGION}" ]]; then
  echo "You must specify at least one destination region for the replicated snapshot :"
  echo "  * CRR_REGION for cross region replication"
  echo "  * CAR_REGION for cross account replication"
  exit 1
fi

if [ ! -z "${CAR_REGION}" ] ; then
  if [ -z "${CAR_ACCOUNT_ID}" ]; then
    echo "When you specify CAR_REGION you must also specify the destination account ID in CAR_ACCOUNT_ID"
    exit 1
  fi
  if [ -z "${CAR_ROLE_ARN}" ]; then
    echo "When you specify CAR_REGION you must also specify the role to assume in CAR_ROLE_ARN"
    echo "  (the role needs permissions to copy snaphots)"
    exit 1
  fi
fi

if [ -z "${CREDENTIAL_SRC}" ]; then
  echo "CREDENTIAL_SRC not specified, setting default EcsContainer"
  CREDENTIAL_SRC="EcsContainer"
fi

SNAPSHOTS_WAIT_PERIODS=${SNAPSHOTS_WAIT_PERIODS:=6}
echo "$(date +%Y-%m-%d-%H:%M:%S) : Wait snapshots for ${SNAPSHOTS_WAIT_PERIODS} periods"

aws configure set credential_source ${CREDENTIAL_SRC} --profile source
aws --profile source sts get-caller-identity --no-cli-pager

if [ "${RDS_ENGINE}" == "aurora" ]; then
  if ! aws --profile source --region ${SRC_RDS_DATABASE_REGION} \
           rds describe-db-clusters --db-cluster-identifier ${SRC_RDS_DATABASE} > /dev/null ; then
    exit 1
  fi
else
  if ! aws --profile source --region ${SRC_RDS_DATABASE_REGION} \
       rds describe-db-instances --db-instance-identifier ${SRC_RDS_DATABASE} > /dev/null ; then
    exit 1
  fi
fi

# SRC - make snapshot and wait
src_snapshot_name="${SRC_RDS_DATABASE}-snapshot-$(date +%Y-%m-%d-%H-%M-%S)"
echo "$(date +%Y-%m-%d-%H:%M:%S) : Launch snapshot for ${SRC_RDS_DATABASE}"
if [ "${RDS_ENGINE}" == "aurora" ]; then
  aws --profile source --region ${SRC_RDS_DATABASE_REGION} rds create-db-cluster-snapshot \
      --db-cluster-identifier ${SRC_RDS_DATABASE} --db-cluster-snapshot-identifier ${src_snapshot_name} \
      --tag Key=Creator,Value=${AWS_BATCH_JQ_NAME} > src.json
      src_snapshot_arn=$(jq -r '.DBClusterSnapshot.DBClusterSnapshotArn' src.json)
  [ !  $? -eq 0 ] && { exit 1; }
else
  aws --profile source --region ${SRC_RDS_DATABASE_REGION} rds create-db-snapshot \
      --db-instance-identifier ${SRC_RDS_DATABASE} --db-snapshot-identifier ${src_snapshot_name} \
      --tag Key=Creator,Value=${AWS_BATCH_JQ_NAME} > src.json
  [ !  $? -eq 0 ] && { exit 1; }
  src_snapshot_arn=$(jq -r '.DBSnapshot.DBSnapshotArn' src.json)
fi

for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do

  if [ "${RDS_ENGINE}" == "aurora" ]; then
    aws --profile source --region ${SRC_RDS_DATABASE_REGION} rds wait db-cluster-snapshot-available \
       --db-cluster-identifier ${SRC_RDS_DATABASE} --db-cluster-snapshot-identifier ${src_snapshot_name}
  else
    aws --profile source --region ${SRC_RDS_DATABASE_REGION} rds wait db-snapshot-available \
       --db-instance-identifier ${SRC_RDS_DATABASE} --db-snapshot-identifier ${src_snapshot_name}
  fi

  if [ $? -eq 0 ]; then
     break
  fi
     echo "Retrying.."
done

if [ "${RDS_ENGINE}" == "aurora" ]; then
    aws --profile source --region ${SRC_RDS_DATABASE_REGION} rds wait db-cluster-snapshot-available \
       --db-cluster-identifier ${SRC_RDS_DATABASE} --db-cluster-snapshot-identifier ${src_snapshot_name}
  [ !  $? -eq 0 ] && { echo "$(date +%Y-%m-%d-%H:%M:%S) : SRC snapshot is not available" ; exit 1; }
else
  aws --profile source --region ${SRC_RDS_DATABASE_REGION} rds wait db-snapshot-available \
      --db-instance-identifier ${SRC_RDS_DATABASE} --db-snapshot-identifier ${src_snapshot_name}
  [ !  $? -eq 0 ] && { echo "$(date +%Y-%m-%d-%H:%M:%S) : SRC snapshot is not available" ; exit 1; }
fi
echo "$(date +%Y-%m-%d-%H:%M:%S) : SRC snapshot is available (${src_snapshot_arn})"

# CRR - cross region replication - copy snapshot and wait
if [ ! -z "${CRR_REGION}" ] ; then
  echo "$(date +%Y-%m-%d-%H:%M:%S) : CRR : copy snapshot to region ${CRR_REGION}"

  if [ "${RDS_ENGINE}" == "aurora" ]; then
    aws --profile source --region ${CRR_REGION} rds copy-db-cluster-snapshot --copy-tags \
        --source-db-cluster-snapshot-identifier ${src_snapshot_arn} --target-db-cluster-snapshot-identifier "${src_snapshot_name}-replica" > crr.json
    [ !  $? -eq 0 ] && { exit 1; }

    crr_snapshot_arn=$(jq -r '.DBClusterSnapshot.DBClusterSnapshotArn' crr.json)
    aws --profile source --region ${CRR_REGION} rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier ${crr_snapshot_arn}
    [ !  $? -eq 0 ] && { exit 1; }
  else
    aws --profile source --region ${CRR_REGION} rds copy-db-snapshot --copy-tags \
        --source-db-snapshot-identifier ${src_snapshot_arn} --target-db-snapshot-identifier "${src_snapshot_name}-replica" > crr.json
    [ !  $? -eq 0 ] && { exit 1; }

    crr_snapshot_arn=$(jq -r '.DBSnapshot.DBSnapshotArn' crr.json)
    aws --profile source --region ${CRR_REGION} rds wait db-snapshot-available --db-snapshot-identifier ${crr_snapshot_arn}
    [ !  $? -eq 0 ] && { exit 1; }
  fi

  echo "$(date +%Y-%m-%d-%H:%M:%S) : CRR : snapshot is available (${crr_snapshot_arn})"
fi

# CAR - cross account replication - share and copy snapshot and wait
if [ ! -z "${CAR_REGION}" ] ; then
  echo "$(date +%Y-%m-%d-%H:%M:%S) : CAR : share snapshot to account ${CAR_ACCOUNT_ID}"

  if [ "${RDS_ENGINE}" == "aurora" ]; then
    aws --profile source --region ${SRC_RDS_DATABASE_REGION} rds modify-db-cluster-snapshot-attribute \
    --db-cluster-snapshot-identifier ${src_snapshot_name} --attribute-name restore --values-to-add ${CAR_ACCOUNT_ID} > car_share.json
    [ !  $? -eq 0 ] && { exit 1; }
  else
    aws --profile source --region ${SRC_RDS_DATABASE_REGION} rds modify-db-snapshot-attribute \
    --db-snapshot-identifier ${src_snapshot_name} --attribute-name restore --values-to-add ${CAR_ACCOUNT_ID} > car_share.json
    [ !  $? -eq 0 ] && { exit 1; }
  fi

  aws configure set role_arn ${CAR_ROLE_ARN} --profile offsite
  aws configure set credential_source ${CREDENTIAL_SRC} --profile offsite
  aws --profile offsite sts get-caller-identity --no-cli-pager

  if [ "${RDS_ENGINE}" == "aurora" ]; then

    if [ "${CAR_REGION}" == "${SRC_RDS_DATABASE_REGION}" ]; then
      echo "$(date +%Y-%m-%d-%H:%M:%S) : CAR : copy snapshot to account ${CAR_ACCOUNT_ID} / region ${CAR_REGION}"

      if [ ! -z "${SRC_KMS_KEY_ARN}" ] ; then
        aws --profile offsite --region ${CAR_REGION} rds copy-db-cluster-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
            --kms-key-id ${SRC_KMS_KEY_ARN} --source-db-cluster-snapshot-identifier ${src_snapshot_arn}  \
            --target-db-cluster-snapshot-identifier "${src_snapshot_name}-replica-offsite" > car_copy.json
        [ !  $? -eq 0 ] && { exit 1; }
      else
        aws --profile offsite --region ${CAR_REGION} rds copy-db-cluster-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
            --source-db-cluster-snapshot-identifier ${src_snapshot_arn} --target-db-cluster-snapshot-identifier "${src_snapshot_name}-replica-offsite" > car_copy.json
        [ !  $? -eq 0 ] && { exit 1; }
      fi
      car_snapshot_arn=$(jq -r '.DBClusterSnapshot.DBClusterSnapshotArn' car_copy.json)
      for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do
        aws --profile offsite --region ${CAR_REGION} rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier ${car_snapshot_arn}
      done
    else
      echo "$(date +%Y-%m-%d-%H:%M:%S) : CAR : copy a temp snapshot to account ${CAR_ACCOUNT_ID} / region ${SRC_RDS_DATABASE_REGION}"
      if [ ! -z "${SRC_KMS_KEY_ARN}" ] ; then
        aws --profile offsite --region ${SRC_RDS_DATABASE_REGION} rds copy-db-cluster-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
            --kms-key-id ${SRC_KMS_KEY_ARN}  --source-db-cluster-snapshot-identifier ${src_snapshot_arn} \
            --target-db-cluster-snapshot-identifier "${src_snapshot_name}-replica-offsite" > cartmp_copy.json
        [ !  $? -eq 0 ] && { exit 1; }

        cartmp_snapshot_arn=$(jq -r '.DBClusterSnapshot.DBClusterSnapshotArn' cartmp_copy.json)
        for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do
          aws --profile offsite --region ${SRC_RDS_DATABASE_REGION} rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier ${cartmp_snapshot_arn}
        done

        echo "$(date +%Y-%m-%d-%H:%M:%S) : CAR : copy the temp snapshot to region ${CAR_REGION}"
        if [ ! -z "${DST_KMS_KEY_ARN}" ] ; then
          aws --profile offsite --region ${CAR_REGION} rds copy-db-cluster-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
              --kms-key-id ${DST_KMS_KEY_ARN} --source-db-cluster-snapshot-identifier ${cartmp_snapshot_arn} \
              --target-db-cluster-snapshot-identifier "${src_snapshot_name}-replica-offsite" > car_copy.json
          [ !  $? -eq 0 ] && { exit 1; }
        else
          aws --profile offsite --region ${CAR_REGION} rds copy-db-cluster-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
              --kms-key-id alias/aws/rds --source-db-cluster-snapshot-identifier ${cartmp_snapshot_arn} \
              --target-db-cluster-snapshot-identifier "${src_snapshot_name}-replica-offsite" > car_copy.json
          [ !  $? -eq 0 ] && { exit 1; }
        fi
        car_snapshot_arn=$(jq -r '.DBClusterSnapshot.DBClusterSnapshotArn' car_copy.json)
        for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do
          aws --profile offsite --region ${CAR_REGION} rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier ${car_snapshot_arn}
        done
      else
        aws --profile offsite --region ${SRC_RDS_DATABASE_REGION} rds copy-db-cluster-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
            --source-db-cluster-snapshot-identifier ${src_snapshot_arn} --target-db-cluster-snapshot-identifier "${src_snapshot_name}-replica-offsite" > cartmp_copy.json
        [ !  $? -eq 0 ] && { exit 1; }

        cartmp_snapshot_arn=$(jq -r '.DBClusterSnapshot.DBClusterSnapshotArn' cartmp_copy.json)
        for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do
          aws --profile offsite --region ${SRC_RDS_DATABASE_REGION} rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier ${cartmp_snapshot_arn}
        done

        echo "$(date +%Y-%m-%d-%H:%M:%S) : CAR : copy the temp snapshot to region ${CAR_REGION}"
        aws --profile offsite --region ${CAR_REGION} rds copy-db-cluster-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
            --source-db-cluster-snapshot-identifier ${cartmp_snapshot_arn} --target-db-cluster-snapshot-identifier "${src_snapshot_name}-replica-offsite" > car_copy.json
        [ !  $? -eq 0 ] && { exit 1; }
        car_snapshot_arn=$(jq -r '.DBClusterSnapshot.DBClusterSnapshotArn' car_copy.json)
        for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do
          aws --profile offsite --region ${CAR_REGION} rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier ${car_snapshot_arn}
        done
      fi
    fi

    aws --profile offsite --region ${CAR_REGION} rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier ${car_snapshot_arn}
    [ !  $? -eq 0 ] && { exit 1; }
  else
    if [ "${CAR_REGION}" == "${SRC_RDS_DATABASE_REGION}" ]; then
      echo "$(date +%Y-%m-%d-%H:%M:%S) : CAR : copy snapshot to account ${CAR_ACCOUNT_ID} / region ${CAR_REGION}"

      if [ ! -z "${SRC_KMS_KEY_ARN}" ] ; then
        aws --profile offsite --region ${CAR_REGION} rds copy-db-snapshot --source-region ${SRC_RDS_DATABASE_REGION} \
            --source-db-snapshot-identifier ${src_snapshot_arn} --target-db-snapshot-identifier "${src_snapshot_name}-replica-offsite" \
            --kms-key-id ${SRC_KMS_KEY_ARN} > car_copy.json
        [ !  $? -eq 0 ] && { exit 1; }
      else
        aws --profile offsite --region ${CAR_REGION} rds copy-db-snapshot --source-region ${SRC_RDS_DATABASE_REGION} \
            --source-db-snapshot-identifier ${src_snapshot_arn} --target-db-snapshot-identifier "${src_snapshot_name}-replica-offsite" > car_copy.json
        [ !  $? -eq 0 ] && { exit 1; }
      fi
      car_snapshot_arn=$(jq -r '.DBSnapshot.DBSnapshotArn' car_copy.json)
      for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do
        aws --profile offsite --region ${CAR_REGION} rds wait db-snapshot-available --db-snapshot-identifier ${car_snapshot_arn}
      done
    else
      echo "$(date +%Y-%m-%d-%H:%M:%S) : CAR : copy a temp snapshot to account ${CAR_ACCOUNT_ID} / region ${SRC_RDS_DATABASE_REGION}"
      if [ ! -z "${SRC_KMS_KEY_ARN}" ] ; then
        aws --profile offsite --region ${SRC_RDS_DATABASE_REGION} rds copy-db-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
            --kms-key-id ${SRC_KMS_KEY_ARN}  --source-db-snapshot-identifier ${src_snapshot_arn} \
            --target-db-snapshot-identifier "${src_snapshot_name}-replica-offsite" > cartmp_copy.json
        [ !  $? -eq 0 ] && { exit 1; }

        cartmp_snapshot_arn=$(jq -r '.DBSnapshot.DBSnapshotArn' cartmp_copy.json)
        for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do
          aws --profile offsite --region ${SRC_RDS_DATABASE_REGION} rds wait db-snapshot-available --db-snapshot-identifier ${cartmp_snapshot_arn}
        done

        echo "$(date +%Y-%m-%d-%H:%M:%S) : CAR : copy the temp snapshot to region ${CAR_REGION}"
        if [ ! -z "${DST_KMS_KEY_ARN}" ] ; then
          aws --profile offsite --region ${CAR_REGION} rds copy-db-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
              --kms-key-id ${DST_KMS_KEY_ARN} --source-db-snapshot-identifier ${cartmp_snapshot_arn} \
              --target-db-snapshot-identifier "${src_snapshot_name}-replica-offsite" > car_copy.json
          [ !  $? -eq 0 ] && { exit 1; }
        else
          aws --profile offsite --region ${CAR_REGION} rds copy-db-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
              --kms-key-id alias/aws/rds --source-db-snapshot-identifier ${cartmp_snapshot_arn} \
              --target-db-snapshot-identifier "${src_snapshot_name}-replica-offsite" > car_copy.json
          [ !  $? -eq 0 ] && { exit 1; }
        fi
        car_snapshot_arn=$(jq -r '.DBSnapshot.DBSnapshotArn' car_copy.json)
        for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do
          aws --profile offsite --region ${CAR_REGION} rds wait db-snapshot-available --db-snapshot-identifier ${car_snapshot_arn}
        done
      else
        aws --profile offsite --region ${SRC_RDS_DATABASE_REGION} rds copy-db-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
            --source-db-snapshot-identifier ${src_snapshot_arn} --target-db-snapshot-identifier "${src_snapshot_name}-replica-offsite" > cartmp_copy.json
        [ !  $? -eq 0 ] && { exit 1; }

        cartmp_snapshot_arn=$(jq -r '.DBSnapshot.DBSnapshotArn' cartmp_copy.json)
        for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do
          aws --profile offsite --region ${SRC_RDS_DATABASE_REGION} rds wait db-snapshot-available --db-snapshot-identifier ${cartmp_snapshot_arn}
        done

        echo "$(date +%Y-%m-%d-%H:%M:%S) : CAR : copy the temp snapshot to region ${CAR_REGION}"
        aws --profile offsite --region ${CAR_REGION} rds copy-db-snapshot --source-region ${SRC_RDS_DATABASE_REGION}  \
            --source-db-snapshot-identifier ${cartmp_snapshot_arn} --target-db-snapshot-identifier "${src_snapshot_name}-replica-offsite" > car_copy.json
        [ !  $? -eq 0 ] && { exit 1; }
        car_snapshot_arn=$(jq -r '.DBSnapshot.DBSnapshotArn' car_copy.json)
        for i in $(seq 1 ${SNAPSHOTS_WAIT_PERIODS}) ; do
          aws --profile offsite --region ${CAR_REGION} rds wait db-snapshot-available --db-snapshot-identifier ${car_snapshot_arn}
        done
      fi
    fi
  echo "$(date +%Y-%m-%d-%H:%M:%S) : CAR : snapshot is available (${car_snapshot_arn})"
  fi
fi

# CLEAN - remove source temporary snapshot
echo "$(date +%Y-%m-%d-%H:%M:%S) : SRC : cleanup source snapshot"
if [ "${RDS_ENGINE}" == "aurora" ]; then
  aws --profile offsite --region ${SRC_RDS_DATABASE_REGION} rds delete-db-cluster-snapshot \
      --db-cluster-snapshot-identifier "${src_snapshot_name}-replica-offsite" > /dev/null
  [ !  $? -eq 0 ] && { exit 1; }
  aws --profile source --region ${SRC_RDS_DATABASE_REGION} rds delete-db-cluster-snapshot \
      --db-cluster-snapshot-identifier ${src_snapshot_name} > /dev/null
  exit $?
else
  aws --profile offsite --region ${SRC_RDS_DATABASE_REGION} rds delete-db-snapshot \
      --db-snapshot-identifier "${src_snapshot_name}-replica-offsite" > /dev/null
  [ !  $? -eq 0 ] && { exit 1; }
  aws --profile source --region ${SRC_RDS_DATABASE_REGION} rds delete-db-snapshot \
      --db-snapshot-identifier ${src_snapshot_name} > /dev/null
  exit $?
fi
