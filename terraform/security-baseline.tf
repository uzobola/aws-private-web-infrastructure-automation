# ---------------------------------------------------------------------------
# VPC Flow Logs -> CloudWatch (network traffic audit record)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/vpc/${var.project_name}/flow-logs"
  retention_in_days = 14
  tags              = { Name = "${var.project_name}-flow-logs" }
}

# Trust policy: allow the VPC Flow Logs service to assume the role
data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.project_name}-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

# Permission policy: allow writing log events to CloudWatch
data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.vpc_flow.arn}:*"]
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