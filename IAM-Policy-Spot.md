# IAM Policy for AWS Spot Instance Support

This policy provides the minimum required permissions for AWS-Deployment to launch spot instances and manage checkpoints.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:RunInstances",
                "ec2:CreateVolume",
                "ec2:AttachVolume"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "ec2:AvailabilityZone": "us-east-1a"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AllocateAddress",
                "ec2:CreateSecurityGroup",
                "ec2:AuthorizeSecurityGroupIngress",
                "ec2:CreateKeyPair",
                "ec2:DescribeInstances",
                "ec2:DescribeImages",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeKeyPairs",
                "ec2:TerminateInstances",
                "ec2:CreateTags"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "us-east-1"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::dxnn-checkpoints",
                "arn:aws:s3:::dxnn-checkpoints/dxnn/*"
            ]
        }
    ]
}
```

## Usage

1. **Create IAM Role**: Create a new IAM role with this policy
2. **Attach to EC2**: Attach the role to your EC2 instances for S3 access
3. **Update Bucket Name**: Replace `dxnn-checkpoints` with your actual bucket name
4. **Update Region**: Modify `us-east-1a` and `us-east-1` to match your region

## Security Notes

- **Minimal Scope**: Only allows access to specific S3 bucket and prefix
- **No Broad Wildcards**: Specific bucket and path restrictions
- **Region Locked**: EC2 operations restricted to specified region
- **Instance Profile**: Designed for EC2 instance profiles, not user access
