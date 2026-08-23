# Shared ALB — previously fronted the hello-world proof (see
# infra/reference/hello-world-blue-green/ for that history and the two
# successful deployments run against it), now fronts the real Admission
# API on the same ports. Terraform address/name kept as "hello_world" /
# "waitly-hw-alb" deliberately: renaming either forces a full ALB replace
# (new DNS name, ~3min downtime) for a purely cosmetic gain — not worth it.
resource "aws_lb" "hello_world" {
  name               = "${var.project}-hw-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "${var.project}-alb" }
}

resource "aws_lb_target_group" "admission_api_blue" {
  name        = "${var.project}-adm-blue"
  port        = var.admission_api_container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # required for Fargate awsvpc networking

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.project}-adm-blue-tg" }
}

resource "aws_lb_target_group" "admission_api_green" {
  name        = "${var.project}-adm-green"
  port        = var.admission_api_container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.project}-adm-green-tg" }
}

# Prod listener: what visitor browsers hit directly.
resource "aws_lb_listener" "admission_api_prod" {
  load_balancer_arn = aws_lb.hello_world.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.admission_api_blue.arn
  }

  # CodeDeploy repoints this listener directly via the ELB API on every
  # blue/green deployment. Without ignoring default_action, the next
  # unrelated `terraform apply` would silently revert a live traffic shift
  # back to whichever target group Terraform originally wrote here.
  lifecycle {
    ignore_changes = [default_action]
  }
}

# Test listener: where CodeDeploy sends canary/validation traffic against
# the "other" color before any of it reaches the prod listener.
resource "aws_lb_listener" "admission_api_test" {
  load_balancer_arn = aws_lb.hello_world.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.admission_api_green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}
