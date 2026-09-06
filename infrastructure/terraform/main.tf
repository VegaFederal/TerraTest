provider "aws" {
  region = var.aws_region
}

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

data "aws_caller_identity" "current" {}

# Use data sources to reference existing VPC and subnets
data "aws_vpc" "existing" {
  id = var.vpc_id
}

data "aws_subnets" "existing" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

data "aws_subnet" "selected" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

# Security Group for Web Servers — not attached to anything today (there's
# no VPC-attached compute in this template), kept as ready-made scaffolding
# for whenever a project adds EC2/ECS/RDS behind this VPC. 
resource "aws_security_group" "web" {
  name        = "${var.project_name}-web-sg"
  description = "Security group for web servers"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-web-sg"
    Environment = var.environment
  }
}

# S3 Bucket for static assets
resource "aws_s3_bucket" "website" {
  # Account ID makes this globally unique across all of AWS, not just this
  # account — S3 bucket names are a global namespace. force_destroy is on
  # since this is throwaway dev infrastructure, same risk tolerance as the
  # rest of this template.
  bucket        = "${var.project_name}-website-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name        = "${var.project_name}-website-bucket"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "website" {
  bucket = aws_s3_bucket.website.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "website" {
  bucket = aws_s3_bucket.website.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- Example Lambda, reachable at /api/* through CloudFront ---
# Zipped directly from source at plan/apply time — no separate CI packaging
# step needed, unlike the CloudFormation path where the code has to be in
# S3 before the stack references it.
data "archive_file" "example_function" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/lambda/example-function"
  output_path = "${path.module}/.terraform-build/example-function.zip"
}

resource "aws_cloudwatch_log_group" "example_function" {
  name              = "/aws/lambda/${var.project_name}-api-fn"
  retention_in_days = 14

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role" "lambda_execution" {
  name = "${var.project_name}-api-fn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "lambda_logging" {
  name = "${var.project_name}-api-fn-logging"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.example_function.arn}:*"
    }]
  })
}

resource "aws_lambda_function" "example" {
  function_name    = "${var.project_name}-api-fn"
  description      = "Example Lambda backing /api/* behind CloudFront"
  filename         = data.archive_file.example_function.output_path
  source_code_hash = data.archive_file.example_function.output_base64sha256
  handler          = "index.handler"
  runtime          = "nodejs22.x"
  role             = aws_iam_role.lambda_execution.arn
  timeout          = 10

  depends_on = [aws_cloudwatch_log_group.example_function]

  tags = {
    Name        = "${var.project_name}-api-fn"
    Environment = var.environment
  }
}

# --- HTTP API, fronted by CloudFront below ---
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"

  tags = {
    Environment = var.environment
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.example.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "root" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigateway_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.example.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# --- CloudFront: S3 origin for the site, API Gateway origin for /api/* ---
resource "aws_cloudfront_origin_access_control" "website" {
  name                              = "${var.project_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "website" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.website.bucket_regional_domain_name
    origin_id                = "S3Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.website.id
  }

  origin {
    domain_name = replace(aws_apigatewayv2_api.http_api.api_endpoint, "https://", "")
    origin_id   = "ApiOrigin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3Origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "ApiOrigin"
    viewer_protocol_policy = "https-only"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type"]
      cookies {
        forward = "all"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Environment = var.environment
  }
}

data "aws_iam_policy_document" "website_bucket_policy" {
  statement {
    sid       = "AllowCloudFrontServicePrincipal"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.website.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.website.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "website" {
  bucket = aws_s3_bucket.website.id
  policy = data.aws_iam_policy_document.website_bucket_policy.json
}
