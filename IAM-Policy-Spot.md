# IAM Policy for Spot Instances

This policy should be attached to the IAM role that will be used by spot instances for S3 access and EC2 metadata access.

**Note:** This policy supports multi-region deployments. The S3 bucket can remain in a single region (e.g., us-east-1) and instances in any region can access it.

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
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeRegions",
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AMIManagementMultiRegion",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeImages",
        "ec2:CopyImage",
        "ec2:CreateTags"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": [
            "us-east-1",
            "us-west-2",
            "eu-west-1",
            "ap-southeast-1"
          ]
        }
      }
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
