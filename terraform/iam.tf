# Trust policy: allow the EC2 service to assume this role
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# The role the instance will assume
resource "aws_iam_role" "web_instance" {
  name               = "${var.project_name}-web-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${var.project_name}-web-instance-role" }
}

# Permission policy: read ONLY the one object, nothing more-allow the EC2 instance to read the index.html 
# file from the S3 bucket -Reducing the risk of the instance being compromised and gaining access to the bucket ( Reduced blast radius)
data "aws_iam_policy_document" "s3_read_index" {
  statement {
    sid     = "ReadIndexObject"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.web.arn}/index.html"
    ]
  }
}

resource "aws_iam_role_policy" "s3_read_index" {
  name   = "${var.project_name}-s3-read-index"
  role   = aws_iam_role.web_instance.id
  policy = data.aws_iam_policy_document.s3_read_index.json
}

# Instance profile: the wrapper that attaches the role to an EC2 instance
resource "aws_iam_instance_profile" "web_instance" {
  name = "${var.project_name}-web-instance-profile"
  role = aws_iam_role.web_instance.name
}

# Allow the instance to be managed by SSM (Session Manager, no SSH needed)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.web_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}