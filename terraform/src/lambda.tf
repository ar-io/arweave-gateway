locals {
  import_txs_cnt = 1
  export_txs_cnt = 1
  import_chunks_cnt = 1
  export_chunks_cnt = 1
  environment_variables = {
    ARWEAVE_DB_READ_HOST = module.rds_proxy.db_proxy_endpoints.read_only.endpoint
    ARWEAVE_DB_WRITE_HOST = module.rds_proxy.db_proxy_endpoints.read_only.endpoint
    ARWEAVE_S3_TX_DATA_BUCKET = module.s3-bucket.s3_bucket_bucket_domain_name
    ENVIRONMENT = var.environment
    SANDBOX_HOST = var.domain_name
  }
}


resource "aws_s3_bucket" "lambdas" {
  bucket = "gateway-legacy-${var.environment}-lambdas"
}


resource "aws_cloudwatch_log_group" "import_txs" {
  for_each          = toset(flatten([ for i in range(1, sum([1, local.import_txs_cnt])) : tostring(i) ]))
  name              = "/aws/lambda/import-txs-${each.key}"
  retention_in_days = 14
}

resource "aws_lambda_function" "import_txs" {
  ## Bootstrap: uncomment
  # count = 0

  for_each = toset(flatten([ for i in range(1, sum([1, local.import_txs_cnt])) : tostring(i) ]))

  depends_on = [
    aws_s3_bucket.lambdas,
    aws_cloudwatch_log_group.import_txs
  ]
  function_name = "import-txs-${each.key}"
  handler = "dist/jobs/import-txs-min.handler"
  role = "${aws_iam_role.lambda_job.arn}"
  runtime = "nodejs14.x"

  s3_bucket = aws_s3_bucket.lambdas.id
  s3_key    = "import-txs.zip"

  timeout = 30
  memory_size = 128

  environment {
    variables = local.environment_variables
  }
}


resource "aws_lambda_event_source_mapping" "import_txs" {
  for_each = toset(flatten([ for i in range(1, sum([1, local.import_txs_cnt])) : tostring(i) ]))

  event_source_arn = aws_sqs_queue.import_txs.arn
  function_name    = aws_lambda_function.import_txs["${each.key}"].arn
}

resource "aws_cloudwatch_log_group" "export_txs" {
  for_each          = toset(flatten([ for i in range(1, sum([1, local.export_txs_cnt])) : tostring(i) ]))
  name              = "/aws/lambda/export-txs-${each.key}"
  retention_in_days = 14
}

resource "aws_lambda_function" "export_txs" {
  ## Bootstrap: uncomment
  # count = 0

  for_each = toset(flatten([ for i in range(1, sum([1, local.export_txs_cnt])) : tostring(i) ]))

  depends_on = [aws_s3_bucket.lambdas]
  function_name = "export-txs-${each.key}"
  handler = "dist/jobs/dispatch-txs-min.handler"
  role = "${aws_iam_role.lambda_job.arn}"
  runtime = "nodejs14.x"

  s3_bucket = aws_s3_bucket.lambdas.id
  s3_key    = "export-txs.zip"

  timeout = 30
  memory_size = 128

  environment {
    variables = local.environment_variables
  }
}

resource "aws_lambda_event_source_mapping" "export_txs" {
  for_each = toset(flatten([ for i in range(1, sum([1, local.export_txs_cnt])) : tostring(i) ]))

  event_source_arn = aws_sqs_queue.export_txs.arn
  function_name    = aws_lambda_function.export_txs["${each.key}"].arn
}

resource "aws_cloudwatch_log_group" "import_chunks" {
  for_each          = toset(flatten([ for i in range(1, sum([1, local.import_chunks_cnt])) : tostring(i)]))
  name              = "/aws/lambda/import-chunks-${each.key}"
  retention_in_days = 14
}

resource "aws_lambda_function" "import_chunks" {
  ## Bootstrap: uncomment
  # count = 0

  for_each = toset(flatten([ for i in range(1, sum([1, local.import_chunks_cnt])) : tostring(i)]))

  depends_on = [aws_s3_bucket.lambdas]
  function_name = "import-chunks-${each.key}"
  handler = "dist/jobs/import-chunks-min.handler"
  role = "${aws_iam_role.lambda_job.arn}"
  runtime = "nodejs14.x"

  s3_bucket = aws_s3_bucket.lambdas.id
  s3_key    = "import-chunks.zip"

  timeout = 30
  memory_size = 128

  environment {
    variables = local.environment_variables
  }
}

resource "aws_lambda_event_source_mapping" "import_chunks" {
  for_each = toset(flatten([ for i in range(1, sum([1, local.import_chunks_cnt])) : tostring(i)]))

  event_source_arn = aws_sqs_queue.import_chunks.arn
  function_name    = aws_lambda_function.import_chunks["${each.key}"].arn
}

resource "aws_cloudwatch_log_group" "export_chunks" {
  for_each          = toset(flatten([ for i in range(1, sum([1, local.export_chunks_cnt])) : tostring(i)]))
  name              = "/aws/lambda/export-chunks-${each.key}"
  retention_in_days = 14
}

resource "aws_lambda_function" "export_chunks" {
  ## Bootstrap: uncomment
  # count = 0

  for_each = toset(flatten([ for i in range(1, sum([1, local.export_chunks_cnt])) : tostring(i)]))

  depends_on = [aws_s3_bucket.lambdas]
  function_name = "export-chunks-${each.key}"
  handler = "dist/jobs/export-chunks-min.handler"
  role = "${aws_iam_role.lambda_job.arn}"
  runtime = "nodejs14.x"
  s3_bucket = aws_s3_bucket.lambdas.id
  s3_key    = "export-chunks.zip"

  timeout = 30
  memory_size = 128

  environment {
    variables = local.environment_variables
  }
}

resource "aws_lambda_event_source_mapping" "export_chunks" {
  for_each = toset(flatten([ for i in range(1, sum([1, local.export_chunks_cnt])) : tostring(i)]))

  event_source_arn = aws_sqs_queue.export_chunks.arn
  function_name    = aws_lambda_function.export_chunks["${each.key}"].arn
}