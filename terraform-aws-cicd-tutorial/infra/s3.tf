resource "aws_s3_bucket" "artifact" {
  bucket_prefix = "${local.name_prefix}-artifact-"

  # チュートリアルでは destroy しやすいように true にする。
  # 実務では誤削除防止のため、要件に応じて false も検討する。
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-artifact"
  })
}

resource "aws_s3_bucket_public_access_block" "artifact" {
  bucket = aws_s3_bucket.artifact.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifact" {
  bucket = aws_s3_bucket.artifact.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifact" {
  bucket = aws_s3_bucket.artifact.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}