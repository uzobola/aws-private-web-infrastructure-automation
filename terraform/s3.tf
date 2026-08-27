# Current account identity, used to make the bucket name globally unique
data "aws_caller_identity" "current" {}

# Ansible/SSM staging bucket for temporary module and file transfer.
# It is not the source of the webpage.
resource "aws_s3_bucket" "web" {
  bucket        = "${var.project_name}-web-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.project_name}-web" }
}

# Ownership controls set to BucketOwnerEnforced - Disables ACLs entirely so that
# the bucket owner owns every object
resource "aws_s3_bucket_ownership_controls" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Block Public Access- Blocks all four public-access vectors
resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning suspended so leftover Ansible payloads cannot persist as old versions.
resource "aws_s3_bucket_versioning" "web" {
  bucket = aws_s3_bucket.web.id
  versioning_configuration {
    status = "Suspended"
  }
}

# Encryption - Server-side Encryption for data at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Expire transfer objects after one day so the bucket does not retain playbook payloads.
resource "aws_s3_bucket_lifecycle_configuration" "web" {
  bucket = aws_s3_bucket.web.id

  rule {
    id     = "expire-ansible-transfer-objects"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}