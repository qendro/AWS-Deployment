# IAM Policy for Spot Instances

This policy should be attached to the IAM role that will be used by spot instances for S3 access and EC2 metadata access.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3CheckpointAccess",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::dxnn-checkpoints",
        "arn:aws:s3:::dxnn-checkpoints/*"
      ]
    },
    {
      "Sid": "EC2SpotInstanceAccess",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeSpotInstanceRequests",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus"
      ],
      "Resource": "*"
    }
  ]
}
```

## Trust Policy for IAM Role

The IAM role should have this trust policy to allow EC2 instances to assume it:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

## Setup Instructions

1. Create the IAM role with the trust policy above
2. Attach the IAM policy to the role
3. Create an instance profile that uses this role
4. Update the spot configuration to use the instance profile name
