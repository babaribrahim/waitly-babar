# Protected-site fixture: NOT one of the three real microservices (see
# CLAUDE.md's demo/testing section). Exists purely so the Queue
# Controller has something real to react to. Deliberately simpler infra
# than the real services: one target group, plain rolling ECS deployment,
# no CodeDeploy/blue-green/canary - that mechanism was already proven
# properly three times over; this is a demo prop, not a fourth example.

# Mode toggle lives as one item in the existing DynamoDB table, not SSM
# Parameter Store: the fixture's task runs in a private, NAT-less subnet,
# and DynamoDB already has a free gateway endpoint reachable from there
# (see vpc_endpoints.tf) - SSM would have needed a new, paid interface
# endpoint (~$7.30/mo) purely to read one small string, found the hard
# way when app.py's SSM calls had no route out and hung every request.
resource "aws_dynamodb_table_item" "protected_site_mode" {
  table_name = aws_dynamodb_table.main.name
  hash_key   = aws_dynamodb_table.main.hash_key
  range_key  = aws_dynamodb_table.main.range_key

  item = jsonencode({
    PK   = { S = "CONFIG#protected-site" }
    SK   = { S = "MODE" }
    mode = { S = "healthy" }
  })

  # Toggling happens through the Room Admin API's POST /demo/mode (see
  # scripts/toggle_protected_site.py and apps/demo-control/index.html),
  # not Terraform - ignore_changes stops the next `terraform apply` from
  # fighting a live toggle and reverting it back to "healthy".
  lifecycle {
    ignore_changes = [item]
  }
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

resource "aws_iam_role_policy" "protected_site_dynamodb" {
  name = "${var.project}-protected-site-dynamodb"
  role = aws_iam_role.protected_site_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem"]
      Resource = aws_dynamodb_table.main.arn
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
      { name = "TABLE_NAME", value = aws_dynamodb_table.main.name },
      { name = "AWS_REGION", value = var.region },
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
# deployment. No CodeDeploy, same as the comment used to say - but that
# comment was wrong about ignore_changes, and it was a live bug, not
# just stale docs: scripts/deploy_protected_site.py registers task
# definitions OUT OF BAND (same pattern as scripts/deploy.py for the
# other two services), then calls update-service directly. Without
# ignore_changes here, every terraform apply on ANYTHING else in this
# module was silently reverting the running service back to whatever
# image tag this resource's own container_definitions still declared
# (:v1) - found live 2026-08-24 when a real fix (deploy_protected_site.py
# v2) kept vanishing after later, unrelated applies. Matches
# admission_api.tf / queue_controller.tf's existing protection now.
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

  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.protected_site]

  tags = { Name = "${var.project}-protected-site-service" }
}
