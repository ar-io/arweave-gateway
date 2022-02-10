module "s3-bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "2.11.1"
  bucket = "arweave-gateway-legacy-${var.environment}-tx-data"

  acl = "private"

  versioning = {
    enabled = false
  }
}
