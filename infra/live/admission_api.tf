# The Admission API: everything specific to this one service, in one
# file. Cloned from the proven hello-world pattern — see
# infra/reference/hello-world-blue-green/. Attaches to the shared ALB
# (alb.tf) and cluster (ecs_cluster.tf).

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

resource "aws_ecr_repository" "admission_api" {
  name                 = "${var.project}/admission-api"
  image_tag_mutability = "MUTABLE" # deploy.py reuses version tags across deployments

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.project}-ecr-admission-api" }
}

resource "aws_ecr_lifecycle_policy" "admission_api" {
  repository = aws_ecr_repository.admission_api.name
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

resource "aws_cloudwatch_log_group" "admission_api" {
  name              = "/ecs/${var.project}-admission-api"
  retention_in_days = 7

  tags = { Name = "${var.project}-admission-api-logs" }
}

# What the container itself assumes to call DynamoDB. Distinct from the
# shared execution role (iam.tf) — scoped to exactly what app.py does, on
# exactly this table.
resource "aws_iam_role" "admission_api_task" {
  name               = "${var.project}-admission-api-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json

  tags = { Name = "${var.project}-admission-api-task-role" }
}

resource "aws_iam_role_policy" "admission_api_dynamodb" {
  name = "${var.project}-admission-api-dynamodb"
  role = aws_iam_role.admission_api_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
      Resource = aws_dynamodb_table.main.arn
    }]
  })
}

# This is only ever the FIRST task definition revision (image tag "v1").
# Every deployment after this one registers a brand-new revision out of
# band via scripts/deploy.py; Terraform never touches it again — see the
# ignore_changes below.
resource "aws_ecs_task_definition" "admission_api" {
  family                   = "${var.project}-admission-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.admission_api_task.arn

  container_definitions = jsonencode([{
    name      = "admission-api"
    image     = "${aws_ecr_repository.admission_api.repository_url}:v1"
    essential = true
    portMappings = [{
      containerPort = var.admission_api_container_port
      protocol      = "tcp"
    }]
    environment = [
      { name = "TABLE_NAME", value = aws_dynamodb_table.main.name },
      { name = "AWS_REGION", value = var.region },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.admission_api.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "admission-api"
      }
    }
  }])

  tags = { Name = "${var.project}-admission-api-task" }
}

resource "aws_ecs_service" "admission_api" {
  name            = "${var.project}-admission-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.admission_api.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.admission_api_blue.arn
    container_name   = "admission-api"
    container_port   = var.admission_api_container_port
  }

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  # CodeDeploy owns both of these after the first deploy: it registers new
  # task definitions and repoints the service at whichever target group is
  # currently live. Terraform must not fight it for control.
  lifecycle {
    ignore_changes = [task_definition, load_balancer]
  }

  depends_on = [aws_lb_listener.admission_api_prod, aws_lb_listener.admission_api_test]

  tags = { Name = "${var.project}-admission-api-service" }
}

resource "aws_codedeploy_app" "admission_api" {
  name             = "${var.project}-admission-api"
  compute_platform = "ECS"

  tags = { Name = "${var.project}-admission-api-app" }
}

resource "aws_codedeploy_deployment_group" "admission_api" {
  app_name               = aws_codedeploy_app.admission_api.name
  deployment_group_name  = "${var.project}-admission-api-dg"
  service_role_arn       = aws_iam_role.codedeploy_ecs.arn
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.admission_api.name
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

  # CodeDeploy decides which of these two target groups is currently idle
  # at deploy time — the AppSpec deploy.py sends never has to name "blue"
  # or "green" explicitly.
  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.admission_api_prod.arn]
      }
      test_traffic_route {
        listener_arns = [aws_lb_listener.admission_api_test.arn]
      }
      target_group {
        name = aws_lb_target_group.admission_api_blue.name
      }
      target_group {
        name = aws_lb_target_group.admission_api_green.name
      }
    }
  }

  tags = { Name = "${var.project}-admission-api-dg" }
}

# boto3 ships in the Lambda Python runtime by default, so the single source
# file is all that needs zipping — no dependency packaging step.
data "archive_file" "admission_api_validate" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/admission_api_validate"
  output_path = "${path.module}/.build/admission_api_validate.zip"
}

resource "aws_iam_role" "admission_api_validate" {
  name               = "${var.project}-admission-api-validate-role"
  assume_role_policy = data.aws_iam_policy_document.validation_lambda_assume.json

  tags = { Name = "${var.project}-admission-api-validate-role" }
}

resource "aws_iam_role_policy_attachment" "admission_api_validate_logs" {
  role       = aws_iam_role.admission_api_validate.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "admission_api_validate_codedeploy" {
  name = "${var.project}-admission-api-validate-codedeploy"
  role = aws_iam_role.admission_api_validate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codedeploy:PutLifecycleEventHookExecutionStatus"
      Resource = "*"
    }]
  })
}

resource "aws_lambda_function" "admission_api_validate" {
  function_name    = "${var.project}-admission-api-validate"
  role             = aws_iam_role.admission_api_validate.arn
  handler          = "validate.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.admission_api_validate.output_path
  source_code_hash = data.archive_file.admission_api_validate.output_base64sha256
  timeout          = 10

  # No VPC config: the ALB is internet-facing, so the Lambda reaches the
  # test listener over the public internet directly.
  environment {
    variables = {
      TEST_ENDPOINT = "http://${aws_lb.hello_world.dns_name}:8080/health"
    }
  }

  tags = { Name = "${var.project}-admission-api-validate" }
}

resource "aws_cloudwatch_log_group" "admission_api_validate" {
  name              = "/aws/lambda/${aws_lambda_function.admission_api_validate.function_name}"
  retention_in_days = 7

  tags = { Name = "${var.project}-admission-api-validate-logs" }
}
