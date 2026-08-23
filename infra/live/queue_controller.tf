# The Queue Controller: background AIMD loop, no public API surface.
# Cloned from the Admission API's pattern (admission_api.tf), which was
# itself cloned from the hello-world proof. Nobody calls this service
# directly — its target groups/listeners exist only because CodeDeploy's
# ECS blue/green mechanism requires a load balancer regardless.

resource "aws_lb_target_group" "queue_controller_blue" {
  name        = "${var.project}-qc-blue"
  port        = var.queue_controller_container_port
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

  tags = { Name = "${var.project}-qc-blue-tg" }
}

resource "aws_lb_target_group" "queue_controller_green" {
  name        = "${var.project}-qc-green"
  port        = var.queue_controller_container_port
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

  tags = { Name = "${var.project}-qc-green-tg" }
}

resource "aws_lb_listener" "queue_controller_prod" {
  load_balancer_arn = aws_lb.hello_world.arn
  port              = 8090
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.queue_controller_blue.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "queue_controller_test" {
  load_balancer_arn = aws_lb.hello_world.arn
  port              = 8091
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.queue_controller_green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

resource "aws_ecr_repository" "queue_controller" {
  name                 = "${var.project}/queue-controller"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.project}-ecr-queue-controller" }
}

resource "aws_ecr_lifecycle_policy" "queue_controller" {
  repository = aws_ecr_repository.queue_controller.name
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

resource "aws_cloudwatch_log_group" "queue_controller" {
  name              = "/ecs/${var.project}-queue-controller"
  retention_in_days = 7

  tags = { Name = "${var.project}-queue-controller-logs" }
}

# Scan + UpdateItem on the table (advances every room's admittedCount),
# plus read-only CloudWatch access to poll the protected site's ALB
# metrics. GetMetricData has no resource-level restriction in IAM — AWS
# requires Resource "*" for it.
resource "aws_iam_role" "queue_controller_task" {
  name               = "${var.project}-queue-controller-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json

  tags = { Name = "${var.project}-queue-controller-task-role" }
}

resource "aws_iam_role_policy" "queue_controller_dynamodb" {
  name = "${var.project}-queue-controller-dynamodb"
  role = aws_iam_role.queue_controller_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:Scan", "dynamodb:UpdateItem"]
      Resource = aws_dynamodb_table.main.arn
    }]
  })
}

resource "aws_iam_role_policy" "queue_controller_cloudwatch" {
  name = "${var.project}-queue-controller-cloudwatch"
  role = aws_iam_role.queue_controller_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["cloudwatch:GetMetricData"]
      Resource = "*"
    }]
  })
}

# This is only ever the FIRST task definition revision. Every deployment
# after this one registers a brand-new revision out of band via
# scripts/deploy.py; Terraform never touches it again.
resource "aws_ecs_task_definition" "queue_controller" {
  family                   = "${var.project}-queue-controller"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.queue_controller_task.arn

  container_definitions = jsonencode([{
    name      = "queue-controller"
    image     = "${aws_ecr_repository.queue_controller.repository_url}:v1"
    essential = true
    portMappings = [{
      containerPort = var.queue_controller_container_port
      protocol      = "tcp"
    }]
    environment = [
      { name = "TABLE_NAME", value = aws_dynamodb_table.main.name },
      { name = "AWS_REGION", value = var.region },
      # Wired to the real protected-site fixture now that it exists.
      # This is only what the FIRST task-def revision gets, same as
      # everything else here — CodeDeploy owns the running service after
      # that. A real `deploy.py queue-controller vN` run is what actually
      # rolls a new revision (with these values) out to the live service.
      { name = "PROTECTED_SITE_LB_ARN_SUFFIX", value = aws_lb.hello_world.arn_suffix },
      { name = "PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX", value = aws_lb_target_group.protected_site.arn_suffix },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.queue_controller.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "queue-controller"
      }
    }
  }])

  tags = { Name = "${var.project}-queue-controller-task" }
}

resource "aws_ecs_service" "queue_controller" {
  name    = "${var.project}-queue-controller"
  cluster = aws_ecs_cluster.main.id

  # Single instance, deliberately: the AIMD rate is a control-loop value
  # read/written to each room's targetRate on every tick. Two instances
  # running independently would both read the same rate and race to write
  # it back, double-counting the adjustment. Scaling this loop out safely
  # needs leader election, which is out of scope at this project's scale
  # (same "documented, not engineered around" spirit as the DynamoDB
  # single-counter tradeoff in CLAUDE.md). Blue/green deploys still work
  # fine at desired_count=1 — CodeDeploy briefly runs one blue + one green
  # task during cutover, then settles back to one.
  task_definition = aws_ecs_task_definition.queue_controller.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.queue_controller_blue.arn
    container_name   = "queue-controller"
    container_port   = var.queue_controller_container_port
  }

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  lifecycle {
    ignore_changes = [task_definition, load_balancer]
  }

  depends_on = [aws_lb_listener.queue_controller_prod, aws_lb_listener.queue_controller_test]

  tags = { Name = "${var.project}-queue-controller-service" }
}

resource "aws_codedeploy_app" "queue_controller" {
  name             = "${var.project}-queue-controller"
  compute_platform = "ECS"

  tags = { Name = "${var.project}-queue-controller-app" }
}

resource "aws_codedeploy_deployment_group" "queue_controller" {
  app_name               = aws_codedeploy_app.queue_controller.name
  deployment_group_name  = "${var.project}-queue-controller-dg"
  service_role_arn       = aws_iam_role.codedeploy_ecs.arn
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.queue_controller.name
  }

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.queue_controller_prod.arn]
      }
      test_traffic_route {
        listener_arns = [aws_lb_listener.queue_controller_test.arn]
      }
      target_group {
        name = aws_lb_target_group.queue_controller_blue.name
      }
      target_group {
        name = aws_lb_target_group.queue_controller_green.name
      }
    }
  }

  tags = { Name = "${var.project}-queue-controller-dg" }
}

data "archive_file" "queue_controller_validate" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/queue_controller_validate"
  output_path = "${path.module}/.build/queue_controller_validate.zip"
}

resource "aws_iam_role" "queue_controller_validate" {
  name               = "${var.project}-queue-controller-validate-role"
  assume_role_policy = data.aws_iam_policy_document.validation_lambda_assume.json

  tags = { Name = "${var.project}-queue-controller-validate-role" }
}

resource "aws_iam_role_policy_attachment" "queue_controller_validate_logs" {
  role       = aws_iam_role.queue_controller_validate.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "queue_controller_validate_codedeploy" {
  name = "${var.project}-queue-controller-validate-codedeploy"
  role = aws_iam_role.queue_controller_validate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codedeploy:PutLifecycleEventHookExecutionStatus"
      Resource = "*"
    }]
  })
}

resource "aws_lambda_function" "queue_controller_validate" {
  function_name    = "${var.project}-queue-controller-validate"
  role             = aws_iam_role.queue_controller_validate.arn
  handler          = "validate.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.queue_controller_validate.output_path
  source_code_hash = data.archive_file.queue_controller_validate.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      TEST_ENDPOINT = "http://${aws_lb.hello_world.dns_name}:8091/health"
    }
  }

  tags = { Name = "${var.project}-queue-controller-validate" }
}

resource "aws_cloudwatch_log_group" "queue_controller_validate" {
  name              = "/aws/lambda/${aws_lambda_function.queue_controller_validate.function_name}"
  retention_in_days = 7

  tags = { Name = "${var.project}-queue-controller-validate-logs" }
}
