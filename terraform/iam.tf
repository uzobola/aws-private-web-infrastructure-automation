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

data "aws_iam_user" "grc_engineer" {
  user_name = "grc-engineer01"
}


# The role the instance will assume
resource "aws_iam_role" "web_instance" {
  name               = "${var.project_name}-web-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${var.project_name}-web-instance-role" }
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


# ---------------------------------------------------------------------------
# Ansible controller role
# ---------------------------------------------------------------------------

# Trust policy:
# Only the grc-engineer01 IAM user may assume this role,
# and MFA must be present.
data "aws_iam_policy_document" "ansible_assume" {
  statement {
    sid     = "AllowGrcEngineerWithMFA"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_user.grc_engineer.arn]
    }

    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role" "ansible_execution" {
  name               = "${var.project_name}-ansible-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ansible_assume.json

  tags = {
    Name = "${var.project_name}-ansible-execution-role"
  }
}

data "aws_iam_policy_document" "ansible_permissions" {

  statement {
    sid    = "DiscoverEC2Instances"
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "StartSessionToChallenge3Instances"
    effect = "Allow"

    actions = [
      "ssm:StartSession"
    ]

    resources = concat(
      aws_instance.web[*].arn,
      [
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/SSM-SessionManagerRunShell"
      ]
    )

    condition {
      test     = "BoolIfExists"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }
  }

  statement {
    sid    = "ManageOwnSessions"
    effect = "Allow"

    actions = [
      "ssm:TerminateSession",
      "ssmmessages:OpenDataChannel"
    ]

    resources = [
      "arn:aws:ssm:*:*:session/$${aws:userid}-*"
    ]
  }

  statement {
    sid    = "UseAnsibleTransferBucket"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]

    resources = [
      aws_s3_bucket.web.arn
    ]
  }

  statement {
    sid    = "TransferAnsibleFiles"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [
      "${aws_s3_bucket.web.arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "ansible_permissions" {
  name   = "${var.project_name}-ansible-permissions"
  role   = aws_iam_role.ansible_execution.id
  policy = data.aws_iam_policy_document.ansible_permissions.json
}