locals {
  postgres_read_password = jsondecode(aws_secretsmanager_secret_version.postgres_read_user.secret_string)["password"]
  postgres_write_password = jsondecode(aws_secretsmanager_secret_version.postgres_write_user.secret_string)["password"]
  ecs_environment = [
    {
      name: "ARWEAVE_S3_TX_DATA_BUCKET"
      value: module.s3-bucket.s3_bucket_bucket_domain_name
    },
    {
      name: "ARWEAVE_DB_READ_HOST"
      value: module.rds_proxy.db_proxy_endpoints.read_only.endpoint
    },
    {
      name: "ARWEAVE_DB_WRITE_HOST"
      value: module.rds_proxy.db_proxy_endpoints.read_write.endpoint
    },
    {
      name: "ARWEAVE_SQS_IMPORT_BUNDLES_URL",
      value: aws_sqs_queue.import_bundles.url
    },
    {
      name: "APP_PORT"
      value: "3000"
    },
    {
      name: "SANDBOX_HOST"
      value: var.domain_name
    },
    {
      name: "ENVIRONMENT"
      value: var.environment
    },
    {
      name: "AWS_DEFAULT_REGION"
      value: var.region
    },
    {
      name: "AWS_REGION"
      value: var.region
    },
    {
      name: "PGSSLMODE",
      value: "require"
    },
    {
      name: "PSQL_READ_ID",
      value: aws_secretsmanager_secret.postgres_read_user.id
    },
    {
      name: "PSQL_READ_PASSWORD",
      value: local.postgres_read_password
    },
    {
      name: "PSQL_WRITE_ID",
      value: aws_secretsmanager_secret.postgres_write_user.id
    },
    {
      name: "PSQL_WRITE_PASSWORD",
      value: local.postgres_write_password
    }
  ]
}

## GATEWAY START

resource "aws_ecs_cluster" "gateway_legacy_cluster" {
  name               = "gateway-legacy-cluster-${var.environment}"
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = "100"
  }
}

resource "aws_security_group" "gateway_legacy_ecs_security_group" {
  name        = "ECS Gateway Legacy Security Group"
  description = "ECS Gateway Legacy Security Group"
  vpc_id      = aws_vpc.default.id

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = aws_subnet.public[*].cidr_block
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


resource "aws_cloudwatch_log_group" "gateway_legacy_cluster" {
  name = "/ecs/gateway-legacy-cluster-${var.environment}"

  tags = {
    Environment = var.environment
  }
}

resource "aws_ecs_task_definition" "gateway_legacy_task" {
  family = "gateway-legacy-${var.environment}"
  requires_compatibilities = [
    "FARGATE",
  ]
  execution_role_arn = aws_iam_role.gateway_legacy_fargate.arn
  network_mode       = "awsvpc"
  cpu                = 256
  memory             = 512

  container_definitions = jsonencode([
    {
      name      = "gateway-legacy-task-definition-${var.environment}"
      image     = "${aws_ecr_repository.gateway_legacy_ecr.repository_url}:latest"
      essential = true
      environment = local.ecs_environment
      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
        }
      ]
      logConfiguration : {
        logDriver : "awslogs",
        options : {
          awslogs-group : aws_cloudwatch_log_group.gateway_legacy_cluster.name
          awslogs-region : var.region,
          awslogs-stream-prefix : "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "gateway_legacy_service" {
  name            = "gateway-legacy-service-${var.environment}"
  cluster         = aws_ecs_cluster.gateway_legacy_cluster.id
  task_definition = aws_ecs_task_definition.gateway_legacy_task.arn
  desired_count   = 1

  network_configuration {
    security_groups  = [aws_security_group.gateway_legacy_ecs_security_group.id]
    subnets          = aws_subnet.private[*].id
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway_legacy_tg.arn
    container_name   = "gateway-legacy-task-definition-${var.environment}"
    container_port   = 3000
  }
  deployment_controller {
    type = "ECS"
  }
  capacity_provider_strategy {
    base              = 0
    capacity_provider = "FARGATE"
    weight            = 100
  }
}

## GATEWAY END

## IMPORT-BUNDLES START

resource "aws_ecs_cluster" "import_bundles_cluster" {
  name               = "import-bundles-cluster-${var.environment}"
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = "100"
  }
}

resource "aws_cloudwatch_log_group" "import_bundles_cluster" {
  name = "/ecs/import-bundles-cluster-${var.environment}"

  tags = {
    Environment = var.environment
  }
}

resource "aws_ecs_task_definition" "import_bundles_task" {
  family = "import-bundles-${var.environment}"

  requires_compatibilities = [
    "FARGATE",
  ]
  execution_role_arn = aws_iam_role.gateway_legacy_fargate.arn
  network_mode       = "awsvpc"
  cpu                = 256
  memory             = 512

  container_definitions = jsonencode([
    {
      name      = "import-bundles-task-definition-${var.environment}"
      image     = "${aws_ecr_repository.import_bundles_ecr.repository_url}:latest"
      essential = true
      environment = local.ecs_environment
      logConfiguration : {
        logDriver : "awslogs",
        options : {
          awslogs-group : aws_cloudwatch_log_group.import_bundles_cluster.name
          awslogs-region : var.region,
          awslogs-stream-prefix : "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "import_bundles_service" {
  name            = "import-bundles-service-${var.environment}"
  cluster         = aws_ecs_cluster.import_bundles_cluster.id
  task_definition = aws_ecs_task_definition.import_bundles_task.arn
  desired_count   = 1

  network_configuration {
    security_groups  = [aws_security_group.gateway_legacy_ecs_security_group.id]
    subnets          = aws_subnet.private[*].id
  }

  deployment_controller {
    type = "ECS"
  }

  capacity_provider_strategy {
    base              = 0
    capacity_provider = "FARGATE"
    weight            = 100
  }
}
