# docker-offsite-rds-snapshots

This is a docker image to make an RDS DB snapshot and then make a Cross Region and/or a Cross Account replica.


## Usage :

Use the following envars and then add those below to activate crr and/or car :


| Name          | Description |
| ------------- |-------------|
| SRC_RDS_DATABASE | **Required** : Name of the database or cluster to snapshot (ex "my-db-1") |
| SRC_RDS_DATABASE_REGION | **Required** : AWS region of the database or cluster to snapshot (ex "eu-west-1") |
| CREDENTIAL_SRC | **Optional** : Where the aws CLI get its credentials, see [aws-credential_source](https://docs.aws.amazon.com/sdkref/latest/guide/setting-global-credential_source.html) (default: "EcsContainer") |
| DEBUG | **Optional** : If set to true print all operations on stdout (default: none) |
| KMS_KEY_ARN  | **Optional** : If not empty use the ARN key to copy encrypted snapshot (default: none) |
| RDS_ENGINE | **Optional** : If set to "aurora" perform cluster snaphot instead of database (default: none) |
| SNAPSHOTS_WAIT_PERIODS | **Optional** : Number of period to wait for the snaphots to be available, each period is 30 minutes (default: 6) |



## Cross region replication (CRR) :

This will copy the snapshot to an other region of the same account, launch the container with following envars :

* CRR_REGION : ex "eu-central-1"


## Cross account region replication (CAR) :

This will share the snapshot to an other AWS account and copy it to the chosen region, launch the container with following envars :

 * CAR_ACCOUNT_ID	: ex "012345678910" (destination account id)
 * CAR_REGION	: ex "eu-west-3"
 * CAR_ROLE_ARN	: ex "arn:aws:iam::012345678910:role/allow-copy-snapshot"

The IAM role must exist in the destination account, with the source account as a trusted entity and the following permissions :

```
      {
            "Action": [
                "rds:CopyDBSnapshot",
                "rds:AddTagsToResource",
                "rds:DescribeDBSnapshots"
            ],
            "Effect": "Allow",
            "Resource": "*",
            "Sid": "AllowSnapshotsCopy"
        },
        {
            "Action": [
                "rds:CopyDBClusterSnapshot",
                "rds:AddTagsToResource",
                "rds:DescribeDBClusterSnapshots",
                "rds:DeleteDBClusterSnapshot"
            ],
            "Effect": "Allow",
            "Resource": "*",
            "Sid": "AllowAuroraSnapshotsCopy"
        },
```

If KMS_KEY_ARN is set the role will also need KMS permissions, see [Sharing encrypted snapshots](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_ShareSnapshot.html#USER_ShareSnapshot.Encrypted)
