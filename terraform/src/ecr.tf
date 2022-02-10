resource "aws_ecr_repository" "gateway_legacy_ecr" {
  name                 = "gateway-legacy-${var.environment}-ecr"
  image_tag_mutability = "MUTABLE"
}

resource "aws_ecr_repository_policy" "gateway_legacy_ecr_policy" {
  repository = aws_ecr_repository.gateway_legacy_ecr.name
  policy     = <<EOF
  {
    "Version": "2008-10-17",
    "Statement": [
      {
        "Sid": "gateway_legacy_ecr full access",
        "Effect": "Allow",
        "Principal": "*",
        "Action": [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetLifecyclePolicy",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
      }
    ]
  }
  EOF
}

resource "aws_ecr_repository" "import_bundles_ecr" {
  name                 = "import-bundles-${var.environment}-ecr"
  image_tag_mutability = "MUTABLE"
}


resource "aws_ecr_repository_policy" "import_bundles_ecr_policy" {
  repository = aws_ecr_repository.import_bundles_ecr.name
  policy     = <<EOF
  {
    "Version": "2008-10-17",
    "Statement": [
      {
        "Sid": "import_bundles_ecr full access",
        "Effect": "Allow",
        "Principal": "*",
        "Action": [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetLifecyclePolicy",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
      }
    ]
  }
  EOF
}
