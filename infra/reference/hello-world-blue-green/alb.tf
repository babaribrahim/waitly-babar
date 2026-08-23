resource "aws_lb" "hello_world" {
  name               = "${var.project}-hw-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "${var.project}-hello-world-alb" }
}

resource "aws_lb_target_group" "blue" {
  name        = "${var.project}-hw-blue"
  port        = var.hello_world_container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # required for Fargate awsvpc networking

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.project}-hw-blue-tg" }
}

resource "aws_lb_target_group" "green" {
  name        = "${var.project}-hw-green"
  port        = var.hello_world_container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }

  tags = { Name = "${var.project}-hw-green-tg" }
}

# Prod listener: what real visitors hit.
resource "aws_lb_listener" "prod" {
  load_balancer_arn = aws_lb.hello_world.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
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
resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.hello_world.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}
