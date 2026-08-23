# --- Known, deliberate tradeoff: CodeDeploy test listeners are public ---
#
# Every service's CodeDeploy test listener (:8080 admission-api, :8091
# queue-controller, and any future service's) is open to 0.0.0.0/0. This
# is intentional, not an oversight -- reviewed and accepted below.
#
# What's exposed: a GET-only, no-auth /health endpoint per service,
# returning a static {"status":"ok"} shape. No data, no state change, no
# secrets.
#
# Why it's open: each service's validation Lambda (the AfterAllowTestTraffic
# CodeDeploy hook) calls its test listener over the public internet, because
# the Lambda deliberately has no VPC config -- see CLAUDE.md's rationale for
# keeping Lambda services VPC-free. A non-VPC Lambda's outbound IP is an
# unpredictable AWS-managed address, so there's no real CIDR to scope
# ingress to.
#
# The production fix, if this were a real system instead of a portfolio
# project: put every validation Lambda inside the VPC (its own subnet +
# security group), restrict each test listener's ingress to just that
# Lambda's security group, and add one interface VPC endpoint for
# `codedeploy` (~$7.30/mo, single-AZ) so the now-VPC-attached Lambdas can
# still call codedeploy:PutLifecycleEventHookExecutionStatus without
# internet egress. Deliberately not done here: the cost and added
# complexity aren't justified by the actual exposure (a read-only health
# check) at this project's scale.
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Hello-world ALB: inbound HTTP from the internet on the prod and CodeDeploy test listeners"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Prod listener"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "CodeDeploy test listener (canary validation traffic) -- see tradeoff note above"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Queue Controller's prod listener (:8090) deliberately gets NO ingress
  # rule at all. Nothing ever routes real traffic to it -- it only exists
  # because CodeDeploy's target_group_pair_info schema requires a prod
  # route alongside the test route. ALB-to-target health checks don't go
  # through this either; those are governed by the ECS tasks' security
  # group, not the listener's. So there is nothing for this port to serve.
  ingress {
    description = "Queue Controller CodeDeploy test listener -- see tradeoff note above"
    from_port   = 8091
    to_port     = 8091
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Protected-site fixture (:8100): open to 0.0.0.0/0 for a different
  # reason than the test listeners above -- this one is meant to be hit,
  # by scripts/probe_protected_site.py, standing in for real admitted
  # visitors until the frontend exists. The prober can run from anywhere
  # (a laptop during a demo), so there's no fixed CIDR to scope this to
  # either. It's a demo prop with no real data behind it either way.
  ingress {
    description = "Protected-site fixture (demo prop, driven by scripts/probe_protected_site.py)"
    from_port   = 8100
    to_port     = 8100
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-alb-sg" }
}

# description text is stale ("Hello-world") on purpose: it's now reused by
# the Admission API, but AWS treats aws_security_group.description as
# immutable — editing it would force a pointless replace of this SG (and a
# knock-on update to vpc_endpoints's SG, which references it by id).
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project}-ecs-tasks-sg"
  description = "Hello-world Fargate tasks: inbound only from the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Container port from the ALB"
    from_port       = var.admission_api_container_port
    to_port         = var.admission_api_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Wide open, but harmless: the private subnets' route table (vpc.tf) has
  # no route to anywhere except the VPC itself and the AWS service prefix
  # lists used by the gateway endpoints — there is no path out to the
  # public internet for this rule to actually expose.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-ecs-tasks-sg" }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project}-vpce-sg"
  description = "Interface VPC endpoints: HTTPS from the ECS tasks only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTPS from ECS tasks"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-vpce-sg" }
}
