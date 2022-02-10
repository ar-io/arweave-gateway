resource "aws_sqs_queue" "import_txs_dlq" {
  name = "import-txs-dlq"
}

resource "aws_sqs_queue" "import_txs" {
  name                      = "import-txs"
  delay_seconds             = 90
  message_retention_seconds = 1209600 #14 days in seconds, max supported value
  receive_wait_time_seconds = 10
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.import_txs_dlq.arn
    maxReceiveCount     = 4
  })
}

resource "aws_sqs_queue" "export_txs_dlq" {
  name = "export-txs-dlq"
}

resource "aws_sqs_queue" "export_txs" {
  name                      = "export-txs"
  delay_seconds             = 90
  message_retention_seconds = 1209600 #14 days in seconds, max supported value
  receive_wait_time_seconds = 10
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.export_txs_dlq.arn
    maxReceiveCount     = 4
  })
}

resource "aws_sqs_queue" "import_chunks_dlq" {
  name = "import-chunks-dlq"
}

resource "aws_sqs_queue" "import_chunks" {
  name                      = "import-chunks"
  delay_seconds             = 90
  message_retention_seconds = 1209600 #14 days in seconds, max supported value
  receive_wait_time_seconds = 10
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.import_chunks_dlq.arn
    maxReceiveCount     = 4
  })
}

resource "aws_sqs_queue" "export_chunks_dlq" {
  name = "export-chunks-dlq"
}

resource "aws_sqs_queue" "export_chunks" {
  name                      = "export-chunks"
  delay_seconds             = 90
  message_retention_seconds = 1209600 #14 days in seconds, max supported value
  receive_wait_time_seconds = 10
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.export_chunks_dlq.arn
    maxReceiveCount     = 4
  })
}

resource "aws_sqs_queue" "import_bundles_dlq" {
  name = "import-bundles-dlq"
}

resource "aws_sqs_queue" "import_bundles" {
  name                      = "import-bundles"
  delay_seconds             = 90
  message_retention_seconds = 1209600 #14 days in seconds, max supported value
  receive_wait_time_seconds = 10
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.import_bundles_dlq.arn
    maxReceiveCount     = 4
  })
}
