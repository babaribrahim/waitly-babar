# Gateway endpoints — free, no hourly or data-processing charge.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project}-vpce-s3" }
}

# Not used by the hello-world proof — provisioned now, while the VPC is
# already being touched, so the Admission API / Queue Controller phase
# doesn't need to come back and modify networking again.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.project}-vpce-dynamodb" }
}

# Interface endpoints — the minimum set for Fargate tasks in a NAT-less
# private subnet to pull images from ECR and ship logs to CloudWatch. Both
# ecr.api and ecr.dkr are required together (auth + the actual registry
# API) — dropping either breaks image pulls. "logs" is required because the
# task definitions use the awslogs driver with no NAT fallback.
locals {
  interface_endpoint_services = ["ecr.api", "ecr.dkr", "logs"]
}

# Deliberately single-AZ (one ENI per service, not one per AZ): AWS bills
# interface endpoints per AZ they're deployed in, so replicating all 3
# across both AZs would cost ~$43.80/mo (3 services x 2 AZs x $0.01/hr x
# 730h) — more than the NAT Gateway this design exists to avoid (~$32.85/mo
# at $0.045/hr). Single-AZ brings it to ~$21.90/mo. Tasks in the other AZ
# still reach these endpoints fine — same-VPC traffic to an ENI is locally
# routable regardless of which subnet/AZ it sits in — so this only becomes
# a real gap if this specific AZ itself has an outage, which is an accepted
# tradeoff at this project's scale, not an oversight.
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoint_services)

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private[0].id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.project}-vpce-${each.value}" }
}
