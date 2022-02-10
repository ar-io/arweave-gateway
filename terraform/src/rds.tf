data "aws_secretsmanager_secret_version" "postgresql_credentials" {
  secret_id = "${var.environment}/gateway-legacy/postgres"
}

locals {
  postgres_admin_user = jsondecode(data.aws_secretsmanager_secret_version.postgresql_credentials.secret_string)["admin_user"]
  postgres_admin_password = jsondecode(data.aws_secretsmanager_secret_version.postgresql_credentials.secret_string)["admin_password"]
}

// READ USER
resource "random_password" "read_user_password" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "postgres_read_user" {
  name        = "read"
  description = "Database read user, databse connection values"
  kms_key_id  = var.default_kms_id
}


resource "aws_secretsmanager_secret_version" "postgres_read_user" {
  secret_id = aws_secretsmanager_secret.postgres_read_user.id
  secret_string = jsonencode({
    username = "read"
    role     = "read"
    password = random_password.read_user_password.result
    dbClusterIdentifier = module.rds_cluster_aurora_postgres.cluster_identifier
    engine = "postgres"
    dbname = "arweave"
    port   = "5432"
  })
}

// WRITE USER
resource "random_password" "write_user_password" {
  length  = 16
  special = false
}

resource "aws_secretsmanager_secret" "postgres_write_user" {
  name        = "write"
  description = "Database write user, databse connection values"
  kms_key_id  = var.default_kms_id
}


resource "aws_secretsmanager_secret_version" "postgres_write_user" {
  secret_id = aws_secretsmanager_secret.postgres_write_user.id
  secret_string = jsonencode({
    username = "write"
    role     = "write"
    password = random_password.write_user_password.result
    dbClusterIdentifier = module.rds_cluster_aurora_postgres.cluster_identifier
    engine = "postgres"
    dbname = "arweave"
    port   = "5432"
  })
}


resource "aws_security_group" "postgresql_security_group" {
  name        = "Postgresql security group"
  description = "Allow TLS inbound traffic"
  vpc_id      = aws_vpc.default.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = concat(aws_subnet.private[*].cidr_block, aws_subnet.public[*].cidr_block)
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

module "rds_cluster_aurora_postgres" {
  source = "cloudposse/rds-cluster/aws"
  # Cloud Posse recommends pinning every module to a specific version
  version     = "0.50.0"

  name               = "arweave-rds-cluster-${var.environment}"
  engine             = "aurora-postgresql"
  cluster_family     = "aurora-postgresql12"
  cluster_identifier = "arweave-gateway-legacy-${var.environment}"
  cluster_type       = "global"
  engine_mode        = "provisioned"
  engine_version     = "12.8"
  # 1 writer, 1 reader
  cluster_size       = 2
  namespace          = "arweave-gateway-legacy"
  stage              = var.environment
  admin_user         = local.postgres_admin_user
  admin_password     = local.postgres_admin_password
  db_name            = "arweave"
  db_port            = 5432
  instance_type      = var.rds_instance_type
  vpc_id             = aws_vpc.default.id
  security_groups    = [
    aws_security_group.postgresql_security_group.id,
    aws_security_group.gateway_legacy_ecs_security_group.id
  ]

  subnets               = aws_subnet.private[*].id
  allowed_cidr_blocks   = ["0.0.0.0/0"]
  publicly_accessible   = false

}

resource "aws_iam_role" "rds_proxy_role" {
  name = "RDSProxySecretsRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = "RDSAssume"
        Principal = {
          Service = toset([
            "sns.amazonaws.com",
            "rds.amazonaws.com"
          ])
        }
      },
    ]
  })

  inline_policy {
    name = "RDSProxyPolicy"

    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid = "GetSecretValue"
          Action = [
            "secretsmanager:GetSecretValue"
          ]
          Effect   = "Allow"
          Resource = [
            aws_secretsmanager_secret.postgres_read_user.arn,
            aws_secretsmanager_secret.postgres_write_user.arn
          ]
        }
      ]
    })
  }
}

module "rds_proxy" {
  source  = "clowdhaus/rds-proxy/aws"
  version = "2.0.1"

  role_arn          = resource.aws_iam_role.rds_proxy_role.arn
  create_proxy      = true
  create_iam_role   = false
  create_iam_policy = false

  name                   = "rds-proxy"
  iam_role_name          = aws_iam_role.rds_proxy_role.name
  vpc_subnet_ids         = aws_subnet.private[*].id
  vpc_security_group_ids = [module.rds_cluster_aurora_postgres.security_group_id]

  db_proxy_endpoints = {
    read_write = {
      name                   = "read-write-endpoint"
      vpc_subnet_ids         = aws_subnet.private[*].id
      vpc_security_group_ids = [aws_security_group.postgresql_security_group.id]
    },
    read_only = {
      name                   = "read-only-endpoint"
      vpc_subnet_ids         = aws_subnet.private[*].id
      vpc_security_group_ids = [aws_security_group.postgresql_security_group.id]
      target_role            = "READ_ONLY"
    }
  }

  secrets = {
    read_only = {
      description = "Aurora PostgreSQL read role password"
      arn         = aws_secretsmanager_secret.postgres_read_user.arn
      kms_key_id  = var.default_kms_id
    },
    read_write = {
      description = "Aurora PostgreSQL write role password"
      arn         = aws_secretsmanager_secret.postgres_write_user.arn
      kms_key_id  = var.default_kms_id
    }
  }

  iam_auth      = "DISABLED"
  engine_family = "POSTGRESQL"
  debug_logging = true
  require_tls   = false
  # db_host       = module.rds_cluster_aurora_postgres.endpoint
  # db_name       = module.rds_cluster_aurora_postgres.name

  # Target Aurora cluster
  target_db_cluster     = true
  db_cluster_identifier = module.rds_cluster_aurora_postgres.cluster_identifier

  tags = {
    Terraform   = "true"
    Environment = var.environment
  }
}
