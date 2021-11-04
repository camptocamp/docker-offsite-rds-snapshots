# docker-offsite-rds-snapshots

This is a docker image to make an RDS DB snapshot and then make a Cross Region and/or a Cross Account replica.


## Cross region replication (CRR) :

This will copy the snapshot to an other region, launch the container with following envars :

 * SRC_RDS_DATABASE          : ex "production"
 * SRC_RDS_DATABASE_REGION   : ex "eu-west-1"
 * CRR_REGION                : ex "eu-central-1"


## Cross account region replication (CAR) :

This will share th snapshot to an other AWS account and restore it in the chosen region, launch the container with following envars :

 * SRC_RDS_DATABASE            : ex "production"
 * SRC_RDS_DATABASE_REGION     : ex "eu-west-1"
 * CAR_ACCOUNT_ID	             : ex "012345678910" (destination account id)
 * CAR_REGION	                 : ex "eu-west-3"
 * CAR_ROLE_ARN	               : ex "arn:aws:iam::012345678910:role/allow-copy-snapshot"

The role must exist in the destination account, with the source account as a trusted entity and the following permissions :

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
        }
```

## Other envars :

* CREDENTIAL_SRC : Where the aws cli get its credentials, see [aws-setting-credential_source](https://docs.aws.amazon.com/sdkref/latest/guide/setting-global-credential_source.html) (default: "EcsContainer")
* DEBUG: If set to true print all operations on stdout
