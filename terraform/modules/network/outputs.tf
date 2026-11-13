output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IP range of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "The two Availability Zones in use."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnets, for the load balancer."
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "Private subnets for the application containers."
  value       = aws_subnet.private_app[*].id
}

output "private_tooling_subnet_id" {
  description = "Private subnet for the Jenkins server."
  value       = aws_subnet.private_tooling.id
}

output "nat_public_ip" {
  description = "Public IP that all outbound traffic from private subnets appears from."
  value       = aws_eip.nat.public_ip
}

output "flow_log_group_name" {
  description = "CloudWatch log group that holds the VPC Flow Logs."
  value       = aws_cloudwatch_log_group.flow_logs.name
}
