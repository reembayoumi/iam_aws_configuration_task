provider "aws" {
  region = var.region
}


data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_availability_zones" "available" {}

resource "aws_organizations_organization" "our_organization" {
    # Enable Trust Access from organization to the SSO
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
"sso.amazonaws.com"
  ]

  feature_set = "ALL"
}

# Create Organizational Account
resource "aws_organizations_account" "new_account" {
  name  = "reem"
  email = "reem.bayoumi.24@gmail.com"
}



# Step: Enable IAM Identity Center in the Console
# Go to AWS IAM Identity Center Console "https://us-east-1.console.aws.amazon.com/singlesignon/home?region=us-east-1#!/"
# Click enable
data "aws_ssoadmin_instances" "our_iam_identity_center" {}


# Create IAM Identity Center Users
# Official Docs:- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/identitystore_user
resource "aws_identitystore_user" "IAM_User" {
  for_each          = var.sso_users
  identity_store_id = tolist(data.aws_ssoadmin_instances.our_iam_identity_center.identity_store_ids)[0]

  display_name = each.value.display_name
  user_name    = each.value.user_name

  name {
    given_name  = each.value.given_name
    family_name = each.value.family_name
  }

  emails {
    value = each.value.email
  }
}

# Create Group in IAM Identity center.
resource "aws_identitystore_group" "dev_group" {
  display_name      = "Development Group"
  identity_store_id = tolist(data.aws_ssoadmin_instances.our_iam_identity_center.identity_store_ids)[0]
}



# Enable Security Hub
resource "aws_securityhub_account" "our_security_hub" {}



################### Start cloudTrail and Bucket Configuration

################### Bucket Configuration
# Create S3 Bucket


resource "aws_cloudtrail" "out_cloudtrail" {
  depends_on = [aws_s3_bucket_policy.logging_bucket_policy]
  name                          = "our_cloudtrail"
  s3_bucket_name                = "our-cloudtrail-bucket-${var.account_id}"
  include_global_service_events = false
  enable_logging                = true
}

resource "aws_s3_bucket" "our_bucket" {
  bucket = "our-cloudtrail-bucket-${var.account_id}"

}


resource "aws_s3_bucket_policy" "logging_bucket_policy" {
  bucket     = "our-cloudtrail-bucket-${var.account_id}"
  depends_on = [aws_s3_bucket.our_bucket ]

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "AWSCloudTrailAclCheck20131101",
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "cloudtrail.amazonaws.com"
        },
        "Action" : "s3:GetBucketAcl",
        "Resource" : "arn:aws:s3:::our-cloudtrail-bucket-${var.account_id}"
      },
      {
        "Sid" : "AWSCloudTrailWrite20131101",
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "cloudtrail.amazonaws.com"
        },
        "Action" : "s3:PutObject",
        "Resource" : [
          "arn:aws:s3:::our-cloudtrail-bucket-${var.account_id}/AWSLogs/${var.account_id}/*", # AWS Account ID - Logging
        ],
        "Condition" : {
          "StringEquals" : {
            "s3:x-amz-acl" : "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}


# controlling versioning on an S3 bucket
resource "aws_s3_bucket_versioning" "our_bucket_versioning" {
  bucket = aws_s3_bucket.our_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}


# We need to enable the SCP from the AWS Organization Console.
# Go To AWS Organizations Console.
# From Left-side, we Choose "Policies"
# Click on "Service control policies"
# Click Enable. 

resource "aws_organizations_policy" "prevent_disable_security_hub" {
  content = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Deny",
      "Action": [
        "securityhub:DisableSecurityHub"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalAccount": ["${var.account_id}"]
        }
      }
    }
  ]
}
POLICY

  name = "prevent_disable_security_hub"
}



resource "aws_organizations_policy" "prevent_disable_cloudtrail" {
  content = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Deny",
      "Action": [
        "cloudtrail:DeleteTrail",
        "cloudtrail:StopLogging"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalAccount": ["${var.account_id}"]
        }
      }
    }
  ]
}
POLICY

  name = "prevent_disable_cloudtrail"
}


resource "aws_organizations_policy" "deny_public_s3_cloudtrail" {
  name        = "DenyPublicS3CloudTrail"
  description = "Prevent exposing CloudTrail S3 bucket publicly"
  content     = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Deny",
        Action   = [
          "s3:PutBucketAcl",
          "s3:PutBucketPolicy"
        ],
        Resource = [
          "arn:aws:s3:::our-cloudtrail-bucket-${var.account_id}",
          "arn:aws:s3:::our-cloudtrail-bucket-${var.account_id}/*"
        ]
      }
    ]
  })
  type = "SERVICE_CONTROL_POLICY"
}






# ====================== Bonus

# Subnet
resource "aws_subnet" "subnetA" {
  vpc_id            = data.aws_vpc.selected.id
    availability_zone = data.aws_availability_zones.available.names[0]

  cidr_block        = cidrsubnet(data.aws_vpc.selected.cidr_block, 3, 1)
}


# Security Group
resource "aws_security_group" "webserver_sg" {
  vpc_id = data.aws_vpc.selected.id
		
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}



# Protect Access to the server "only users with IP assigned in the "cidr_blocks array""
resource "aws_security_group" "ssh_sg" {
  vpc_id = data.aws_vpc.selected.id


  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   #  # I can add my Public IP address so only me can SSH to the instance
  }


  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}



# EC2 Instance hosts the webserver
resource "aws_instance" "web" {
  # Amazon Linux 2 AMI
  ami           = "ami-0d3a2960fcac852bc" 
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.subnetA.id
   security_groups = [aws_security_group.ssh_sg.id, aws_security_group.webserver_sg.id]



  user_data = <<-EOF
                #!/bin/bash
                yum update -y
                yum install -y httpd
                systemctl start httpd
                systemctl enable httpd
                echo "Hello, I am Reem Bayoumi!" > /var/www/html/index.html
                EOF

  tags = {
    Name = "WebServer"
  }
}


## Protect Access to the Server "only specific account"

resource "aws_iam_role" "instance_access_role" {
  name               = "instance-access-role"
  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "AWS": "arn:aws:iam::992382781635:root"
        },
        "Action": "sts:AssumeRole"
      }
    ],
    "Resource": "arn:aws:ec2:*:*:instance/*"
  })
}

resource "aws_iam_policy" "instance_access_policy" {
  name        = "instance-access-policy"
  description = "Allow access to EC2 instances for specific account"
  policy      = <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "ec2:DescribeInstances",
        "Resource": "*",
        "Condition": {
          "StringEquals": {
            "aws:PrincipalAccount": "992382781635"
          }
        }
      },
      {
        "Effect": "Allow",
        "Action": [
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:TerminateInstances"
        ],
        "Resource": "*",
        "Condition": {
          "StringEquals": {
            "aws:PrincipalAccount": "992382781635"
          }
        }
      }
    ]
  }
  EOF
}

resource "aws_iam_role_policy_attachment" "attach_instance_access_policy" {
  role       = aws_iam_role.instance_access_role.name
  policy_arn = aws_iam_policy.instance_access_policy.arn
}


resource "aws_ssoadmin_permission_set" "ec2permessionset" {
  name         = "EC2_Permession_Set"
  instance_arn = tolist(data.aws_ssoadmin_instances.our_iam_identity_center.arns)[0]
}

resource "aws_ssoadmin_managed_policy_attachment" "attach-ec2-policy" {
  instance_arn       = tolist(data.aws_ssoadmin_instances.our_iam_identity_center.arns)[0]
  managed_policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
    permission_set_arn = aws_ssoadmin_permission_set.ec2permessionset.arn

}


resource "aws_ssoadmin_account_assignment" "account_assignment" {
  instance_arn       = tolist(data.aws_ssoadmin_instances.our_iam_identity_center.arns)[0]
  permission_set_arn = aws_ssoadmin_permission_set.ec2permessionset.arn
  
   principal_id   = aws_identitystore_group.dev_group.group_id
  principal_type = "GROUP"



  target_id   = "992382781635"
  target_type = "AWS_ACCOUNT"
}


