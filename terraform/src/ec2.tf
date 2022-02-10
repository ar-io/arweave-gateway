resource "aws_s3_bucket" "amis" {
  bucket = "gateway-legacy-${var.environment}-amis"
}

module "vmimport" {
  source  = "github.com/StratusGrid/terraform-aws-iam-role-vmimport"
  image_bucket_name = "gateway-legacy-${var.environment}-amis"
}


resource "aws_security_group" "gateway_legacy_ec2_import_blocks_security_group" {
  name        = "EC2 Gateway Legacy import-blocks Security Group"
  description = "ECS Gateway Legacy import-blocks Security Group"
  vpc_id      = aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = concat(aws_subnet.private[*].cidr_block, aws_subnet.public[*].cidr_block)
  }

  egress {
    from_port        = 1984
    to_port          = 1984
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 5432
    to_port          = 5432
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}


resource "aws_iam_instance_profile" "import_blocks_instance_profile" {
  name = "import_blocks_instance_profile"
  role = aws_iam_role.import_blocks_instance_role.name
}

resource "aws_iam_role" "import_blocks_instance_role" {
  name = "import_blocks_instance_role"
  path = "/"

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": "sts:AssumeRole",
            "Principal": {
               "Service": "ec2.amazonaws.com"
            },
            "Effect": "Allow",
            "Sid": ""
        }
    ]
}
EOF

  inline_policy {
    name = "import_blocks_inline_policy"

    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action   = ["secretsmanager:GetSecretValue", "kms:GetPublicKey", "kms:Decrypt", "kms:DescribeKey"]
          Effect   = "Allow"
          Resource = "*"
        },
        {
          Action   = ["sqs:*"]
          Effect   = "Allow"
          Resource = "*"
        }
      ]
    })
  }
}

# note, this requires AMI image to have been built prior to apply
module "import_blocks_ec2_instance" {
  ## Bootstrap: uncomment
  # count = 0

  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "3.0"

  name                   = "import-blocks"
  ami                    = var.import_blocks_ami
  instance_type          = var.ec2_import_blocks_resource
  iam_instance_profile   = aws_iam_instance_profile.import_blocks_instance_profile.name

  user_data = <<-EOT
    #!/usr/bin/env bash
    rm -f /var/dotenv || true
    touch /var/dotenv
    chmod +rw /var/dotenv
    echo AWS_REGION=${var.region} >> /var/dotenv
    echo AWS_DEFAULT_REGION=${var.region} >> /var/dotenv
    echo ARWEAVE_DB_READ_HOST=${module.rds_proxy.db_proxy_endpoints.read_only.endpoint} >> /var/dotenv
    echo ARWEAVE_DB_WRITE_HOST=${module.rds_proxy.db_proxy_endpoints.read_write.endpoint} >> /var/dotenv
    echo ARWEAVE_SQS_IMPORT_TXS_URL=${aws_sqs_queue.import_txs.url} >> /var/dotenv
    chmod 755 /var/dotenv
  EOT

  associate_public_ip_address = true

  monitoring             = true
  vpc_security_group_ids = aws_security_group.gateway_legacy_ec2_import_blocks_security_group[*].id
  subnet_id              = aws_subnet.private[0].id

  tags = {
    Terraform   = "true"
  }
}
