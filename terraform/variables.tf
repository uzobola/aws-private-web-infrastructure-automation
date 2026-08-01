variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used for tagging and resource names"
  type        = string
  default     = "challenge3"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}


variable "environment" {
  description = "Deployment stage (dev, staging, prod)"
  type        = string
  default     = "dev"
}