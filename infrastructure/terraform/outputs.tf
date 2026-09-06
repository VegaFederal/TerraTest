output "vpc_id" {
  description = "ID of the existing VPC resources were deployed into"
  value       = data.aws_vpc.existing.id
}

output "subnet_ids" {
  description = "IDs of the subnets resources were deployed into"
  value       = var.subnet_ids
}

output "web_security_group_id" {
  description = "ID of the web security group"
  value       = aws_security_group.web.id
}

output "website_bucket_name" {
  description = "S3 bucket for website content"
  value       = aws_s3_bucket.website.bucket
}

output "cloudfront_distribution_domain_name" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.website.domain_name
}

output "website_url" {
  description = "URL of the static website"
  value       = "https://${aws_cloudfront_distribution.website.domain_name}"
}

output "api_endpoint" {
  description = "API Gateway HTTP API endpoint (also reachable via the CloudFront distribution's /api/* path)"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}
