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
        }
    ]
}