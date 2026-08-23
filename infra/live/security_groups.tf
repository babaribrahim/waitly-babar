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
    description = "CodeDeploy test listener (canary validation traffic)"
    from_port   = 8080
    to_port     = 8080
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
