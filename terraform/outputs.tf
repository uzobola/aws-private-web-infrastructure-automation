output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "web_bucket_name" {
  value = aws_s3_bucket.web.id
}

output "alb_dns_name" {
  description = "Public URL of the site (the load balancer)"
  value       = aws_lb.web.dns_name
}