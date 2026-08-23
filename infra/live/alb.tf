# Shared ALB — previously fronted the hello-world proof (see
# infra/reference/hello-world-blue-green/ for that history and the two
# successful deployments run against it). Terraform address/name kept as
# "hello_world" / "waitly-hw-alb" deliberately: renaming either forces a
# full ALB replace (new DNS name, ~3min downtime) for a purely cosmetic
# gain — not worth it. Every service's target groups and listeners live
# in that service's own file (admission_api.tf, queue_controller.tf, ...)
# and all attach to this one ALB.
resource "aws_lb" "hello_world" {
  name               = "${var.project}-hw-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "${var.project}-alb" }
}
