# Single table, no GSIs — every access pattern in CLAUDE.md is a direct
# PK/SK lookup (room metadata, a visitor record, a token). See that file's
# DynamoDB section for the full key-schema table and the atomic-counter /
# conditional-write / TTL mechanisms the application layer builds on top of
# this.
#
# PAY_PER_REQUEST, not provisioned capacity: this workload's whole point is
# bursty, unpredictable traffic (that's what the waiting room protects
# against) — provisioned capacity would mean either paying for headroom
# that sits idle 99% of the time, or under-provisioning right when a burst
# hits. On-demand costs a little more per request but nothing sits idle.
resource "aws_dynamodb_table" "main" {
  name         = "${var.project}-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = { Name = "${var.project}-table" }
}
