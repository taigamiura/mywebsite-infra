# ==========================================
# 1. Terraform & Provider 設定
# ==========================================
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    key     = "prod/terraform.tfstate"
    encrypt = true
  }
}

# デフォルトプロバイダ（東京リージョン）
provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = {
      CreatedBy = "terraform"
    }
  }
}

# ACM用の別名プロバイダ（バージニア北部リージョン ※CloudFront用で必須）
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      CreatedBy = "terraform"
    }
  }
}

# ==========================================
# 2. Route 53 (ホストゾーン)
# ==========================================
resource "aws_route53_zone" "main" {
  name = var.domain_name
}

# ==========================================
# 3. ACM (SSL/TLS 証明書)
# ==========================================
resource "aws_acm_certificate" "cert" {
  provider                  = aws.us_east_1 # バージニア指定
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# DNS検証用のRoute 53レコード
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.main.zone_id
}

# 証明書検証の完了を待機するリソース
resource "aws_acm_certificate_validation" "cert" {
  provider                = aws.us_east_1 # バージニア指定
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ==========================================
# 4. S3 Bucket (静的ファイル配信用)
# ==========================================
resource "aws_s3_bucket" "web_bucket" {
  bucket        = "web-${var.domain_name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # 削除時にバケット内を空にする設定
}

data "aws_caller_identity" "current" {}

# S3バケットポリシー（CloudFront OACからのアクセスのみ許可）
resource "aws_s3_bucket_policy" "web_bucket_policy" {
  bucket = aws_s3_bucket.web_bucket.id
  policy = data.aws_iam_policy_document.s3_policy.json
}

data "aws_iam_policy_document" "s3_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web_bucket.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.s3_distribution.arn]
    }
  }
}

# ==========================================
# 5. CloudFront
# ==========================================
# Origin Access Control (OAC) の作成
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "s3-oac-${var.domain_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ディストリビューション
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = aws_s3_bucket.web_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
    origin_id                = "S3-${aws_s3_bucket.web_bucket.id}"
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = [var.domain_name]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.web_bucket.id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https" # HTTPをHTTPSへリダイレクト
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ==========================================
# 6. Route 53 (CloudFrontへのエイリアスレコード)
# ==========================================
resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}
