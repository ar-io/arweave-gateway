resource "aws_iam_role" "gateway_legacy_fargate" {
  name = "gateway-legacy-fargate-role"
  path =  "/serviceaccounts/"
  managed_policy_arns = [aws_iam_policy.rds_readwrite_policy.arn]
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = [
            "ecs.amazonaws.com",
            "ecs-tasks.amazonaws.com",
            "ec2.amazonaws.com"
          ]
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "gateway_legacy_fargate_policy" {
  name = "gateway-legacy-fargate-policy"
  role = aws_iam_role.gateway_legacy_fargate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "${var.deployment_role}"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:*",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:GetPublicKey",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          "secretsmanager:GetSecretValue"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ],
        Resource: "*"
      },
    ]
  })
}

resource "aws_iam_role" "cloudwatch_write_role" {
  name = "CloudwatchWriteRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = toset([
            "sns.amazonaws.com",
          ])
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "cloudwatch_write_role_policy" {
  name = "CloudwatchWriteRolePolicy"
  role = aws_iam_role.cloudwatch_write_role.id

  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        Effect : "Allow",
        Action : [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:PutMetricFilter",
          "logs:PutRetentionPolicy"
        ],
        Resource : [
          "*"
        ]
      }
    ]
  })
}

# Runtime gateway user

resource "aws_iam_user" "gateway_user" {
  name = "GatewayUser"
  path = "/gateway/"
}

resource "aws_iam_user_policy" "gateway_runtime_policy" {
  name = "GatewayRuntimePolicy"
  user = aws_iam_user.gateway_user.name

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    },
    {
      "Action": [
        "sqs:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_access_key" "gateway_user" {
  user = aws_iam_user.gateway_user.name
}

data "aws_iam_policy_document" "rds_readwrite_role_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com", "ecs-tasks.amazonaws.com", "ecs-tasks.amazonaws.com"]
    }
  }
}

# https://aws.amazon.com/blogs/database/securing-amazon-rds-and-aurora-postgresql-database-access-with-iam-authentication/
resource "aws_iam_role" "rds_readwrite_role" {
  name = "RdsReadWriteRole"
  assume_role_policy = data.aws_iam_policy_document.rds_readwrite_role_assume_role_policy.json
  managed_policy_arns = [aws_iam_policy.rds_readwrite_policy.arn]
}

resource "aws_iam_policy" "rds_readwrite_policy" {
  name = "RDSReadWritePolicy"
  path = "/gateway/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "rds-db:*"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:rds-db:${var.region}:${var.account_id}:dbuser:${module.rds_cluster_aurora_postgres.cluster_identifier}/*"
      },
      {
        Action = [
          "rds-db:*"
        ]
        Effect   = "Allow"
        Resource = module.rds_proxy.proxy_arn
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "rds_readwrite_role_gateway_user_attachment" {
  user       = aws_iam_user.gateway_user.name
  policy_arn = aws_iam_policy.rds_readwrite_policy.arn
}

# jobs


resource "aws_iam_role" "lambda_job" {
  name = "LambdaJob"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

  inline_policy {
    name = "lambda_job_inline_policy"

    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action   = ["sqs:*"]
          Effect   = "Allow"
          Resource = "*"
        },
        {
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ]
          Resource = "arn:aws:logs:*:*:*"
          Effect   = "Allow"
        }
      ]
    })
  }
}
