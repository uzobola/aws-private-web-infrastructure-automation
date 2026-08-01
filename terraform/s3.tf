# Current account identity, used to make the bucket name globally unique
data "aws_caller_identity" "current" {}

# This bucket holds the web content
resource "aws_s3_bucket" "web" {
  bucket = "${var.project_name}-web-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "${var.project_name}-web" }
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

# Versioning - Keeps every version of an object
resource "aws_s3_bucket_versioning" "web" {
  bucket = aws_s3_bucket.web.id
  versioning_configuration {
    status = "Enabled"
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

# Upload the Hello World page into the bucket. 
# Hashes the file, so if index.html is edited later, Terraform notices the hash changed and re-uploads it. 
# Without it, Terraform wouldn't detect content changes.
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.web.id
  key          = "index.html"
  source       = "${path.module}/files/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/files/index.html")

  depends_on = [aws_s3_bucket_versioning.web]
}