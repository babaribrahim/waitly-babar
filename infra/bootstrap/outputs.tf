output "state_bucket_name" {
  description = "Pass this to `terraform init -backend-config=bucket=<value>` in infra/live."
  value       = aws_s3_bucket.tf_state.bucket
}

output "state_bucket_arn" {
  value = aws_s3_bucket.tf_state.arn
}

output "region" {
  value = var.region
}
