# ---------------------------------------------------------------------------
# VPC Flow Logs -> CloudWatch (network traffic audit record)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/vpc/${var.project_name}/flow-logs"
  retention_in_days = 14
  tags              = { Name = "${var.project_name}-flow-logs" }
}


# Trust policy: allow VPC Flow Logs to assume this role
# only when acting on behalf of this AWS account.
data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"
      ]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.project_name}-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

# Permission policy: allow writing log events to CloudWatch
data "aws_iam_policy_document" "flow_logs_write" {

  # Write flow-log data to this project's CloudWatch log streams.
  statement {
    sid    = "WriteVpcFlowLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    resources = [
      "${aws_cloudwatch_log_group.vpc_flow.arn}:*"
    ]
  }

  # DescribeLogGroups does not support resource-level IAM scoping.
  statement {
    sid    = "DescribeLogGroups"
    effect = "Allow"

    actions = [
      "logs:DescribeLogGroups"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "${var.project_name}-flow-logs-write"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

# The flow log itself: capture ALL traffic on the VPC
resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow.arn
  tags            = { Name = "${var.project_name}-flow-log" }
}

# ---------------------------------------------------------------------------
# Lock down the VPC's default security group (deny all)
# ---------------------------------------------------------------------------

resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id
  # No ingress or egress rules = deny all. Intentionally empty.
  tags = { Name = "${var.project_name}-default-sg-locked" }
}