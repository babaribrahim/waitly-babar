# Protected-site fixture: NOT one of the three real microservices (see
# CLAUDE.md's demo/testing section). Exists purely so the Queue
# Controller has something real to react to. Deliberately simpler infra
# than the real services: one target group, plain rolling ECS deployment,
# no CodeDeploy/blue-green/canary - that mechanism was already proven
# properly three times over; this is a demo prop, not a fourth example.

resource "aws_ssm_parameter" "protected_site_mode" {
  name        = "/${var.project}/protected-site/mode"
  description = "Toggles the protected-site fixture's behavior at runtime, no redeploy needed. One of: healthy, slow, error."
  type        = "String" # not sensitive - a demo toggle, SecureString isn't warranted
  value       = "healthy"

  # The fixture's own toggle script (scripts/toggle_protected_site.py) is
  # the operational way to change this during a demo - Terraform owning
  # the value would just mean every toggle also has to fight the next
  # `terraform apply` reverting it back to "healthy".
  lifecycle {
    ignore_changes = [value]
  }

  tags = { Name = "${var.project}-protected-site-mode" }
}

resource "aws_lb_target_group" "protected_site" {
  name        = "${var.project}-protsite"
  port        = 80
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

  tags = { Name = "${var.project}-protsite-tg" }
}

resource "aws_lb_listener" "protected_site" {
  load_balancer_arn = aws_lb.hello_world.arn
  port              = 8100
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.protected_site.arn
  }
}

resource "aws_ecr_repository" "protected_site" {
  name                 = "${var.project}/protected-site"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.project}-ecr-protected-site" }
}

resource "aws_ecr_lifecycle_policy" "protected_site" {
  repository = aws_ecr_repository.protected_site.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recently pushed images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "protected_site" {
  name              = "/ecs/${var.project}-protected-site"
  retention_in_days = 7

  tags = { Name = "${var.project}-protected-site-logs" }
}

resource "aws_iam_role" "protected_site_task" {
  name               = "${var.project}-protected-site-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json

  tags = { Name = "${var.project}-protected-site-task-role" }
}

resource "aws_iam_role_policy" "protected_site_ssm" {
  name = "${var.project}-protected-site-ssm"
  role = aws_iam_role.protected_site_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = aws_ssm_parameter.protected_site_mode.arn
    }]
  })
}

resource "aws_ecs_task_definition" "protected_site" {
  family                   = "${var.project}-protected-site"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.protected_site_task.arn

  container_definitions = jsonencode([{
    name      = "protected-site"
    image     = "${aws_ecr_repository.protected_site.repository_url}:v1"
    essential = true
    portMappings = [{
      containerPort = 80
      protocol      = "tcp"
    }]
    environment = [
      { name = "MODE_PARAMETER_NAME", value = aws_ssm_parameter.protected_site_mode.name },
      { name = "SLOW_DELAY_SECONDS", value = "3" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.protected_site.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "protected-site"
      }
    }
  }])

  tags = { Name = "${var.project}-protected-site-task" }
}

# No deployment_controller block - defaults to plain ECS rolling
# deployment. No CodeDeploy, no lifecycle ignore_changes on
# task_definition: `terraform apply` after a task-def change (e.g. a new
# image tag) is how this one redeploys. See scripts/deploy_protected_site.py.
resource "aws_ecs_service" "protected_site" {
  name            = "${var.project}-protected-site"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.protected_site.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.protected_site.arn
    container_name   = "protected-site"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.protected_site]

  tags = { Name = "${var.project}-protected-site-service" }
}
