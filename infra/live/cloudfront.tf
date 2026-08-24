# Frontend: S3 (private, OAC) + CloudFront, served from the shared
# hosted zone's waitly.* subdomain - per CLAUDE.md's DNS/TLS section.
#
# Serves apps/frontend AND apps/demo-control from the same distribution
# (demo-control under a /demo-control/ prefix) - demo-control isn't part
# of the real product UI, but it still needs to be reachable from a
# browser tab with no local server running, same as everything else.
#
# Mixed-content fix, not optional: once this is served over HTTPS, any
# fetch() from these pages to the ALB (Admission API, protected-site
# fixture - both HTTP-only, no ALB TLS listener per CLAUDE.md's "no
# custom subdomain for the ALB" decision) would be blocked by the
# browser outright. Fixed by adding the ALB as two more CloudFront
# origins (different ports) on this SAME distribution/cert - CloudFront
# terminates HTTPS for the browser and talks plain HTTP to the origin
# internally, so no ALB cert/subdomain is needed, and CLAUDE.md's "no
# custom subdomain for the ALB" still holds exactly as written: the ALB
# itself still has none, it's just an origin behind the one subdomain
# this project already has.

data "aws_route53_zone" "shared" {
  name = "internship.cloudelligent-sandbox.com"
}

locals {
  site_domain = "waitly.${data.aws_route53_zone.shared.name}"
}

# --- ACM certificate (us-east-1 only - CloudFront's one hard requirement) ---

resource "aws_acm_certificate" "site" {
  provider          = aws.us_east_1
  domain_name       = local.site_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${var.project}-site-cert" }
}

resource "aws_route53_record" "site_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.shared.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.site_cert_validation : r.fqdn]
}

# --- S3 bucket (private, no public access - CloudFront OAC only) ---

resource "random_id" "frontend_bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project}-frontend-${random_id.frontend_bucket_suffix.hex}"

  tags = { Name = "${var.project}-frontend" }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project}-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "frontend_bucket_policy" {
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_bucket_policy.json
}

# --- Frontend + demo-control file uploads ---
# Terraform-native, declarative (fileset() + one aws_s3_object per file,
# etag = filemd5 so changes are detected and re-uploaded on the next
# apply) rather than a separate sync script - keeps "everything in
# Terraform, applied manually" true for the frontend too.

locals {
  content_types = {
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "application/javascript"
  }

  frontend_files = {
    for f in fileset("${path.module}/../../apps/frontend", "**") :
    f => "${path.module}/../../apps/frontend/${f}"
  }

  demo_control_files = {
    for f in fileset("${path.module}/../../apps/demo-control", "**") :
    "demo-control/${f}" => "${path.module}/../../apps/demo-control/${f}"
  }

  site_files = merge(local.frontend_files, local.demo_control_files)
}

resource "aws_s3_object" "site" {
  for_each = local.site_files

  bucket       = aws_s3_bucket.frontend.id
  key          = each.key
  source       = each.value
  etag         = filemd5(each.value)
  content_type = lookup(local.content_types, regex("\\.[^.]+$", each.value), "application/octet-stream")
}

# --- CloudFront Function: strips the /fixture prefix before forwarding
# to the protected-site fixture origin, whose real routes are "/" and
# "/health" - the fixture app itself is unaware it's behind /fixture.

resource "aws_cloudfront_function" "strip_fixture_prefix" {
  name    = "${var.project}-strip-fixture-prefix"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrites /fixture/* -> /* before forwarding to the protected-site fixture origin"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      if (uri === "/fixture") {
        request.uri = "/";
      } else if (uri.indexOf("/fixture/") === 0) {
        request.uri = uri.substring("/fixture".length);
        if (request.uri === "") {
          request.uri = "/";
        }
      }
      return request;
    }
  EOT
}

# --- CloudFront distribution ---

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [local.site_domain]

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # Admission API - real traffic, cannot be cached.
  origin {
    domain_name = aws_lb.hello_world.dns_name
    origin_id   = "alb-admission-api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # the ALB has no TLS listener - see file header
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Protected-site fixture - same ALB, different port, its own origin
  # since CloudFront origins are one host:port each.
  origin {
    domain_name = aws_lb.hello_world.dns_name
    origin_id   = "alb-fixture"

    custom_origin_config {
      http_port              = 8100
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  # Admission API routes - /rooms/{roomId}/join|status|token - match the
  # app's own route prefix exactly, no rewriting needed.
  ordered_cache_behavior {
    path_pattern             = "/rooms/*"
    target_origin_id         = "alb-admission-api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  ordered_cache_behavior {
    path_pattern             = "/fixture/*"
    target_origin_id         = "alb-fixture"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.strip_fixture_prefix.arn
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/demo-control/*"
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "${var.project}-site" }
}

# AWS-managed policies - no reason to hand-roll these.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

# --- Route 53: one alias record in the SHARED zone, nothing else ---
# CLAUDE.md is explicit: this zone is shared with other interns, do not
# create a new hosted zone, only add what's genuinely needed. Checked
# live before writing this - no existing "waitly" record in the zone.

resource "aws_route53_record" "site" {
  zone_id = data.aws_route53_zone.shared.zone_id
  name    = local.site_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}
