# hello-world's task logs are left in place too — cheap, 7-day retention
# ages them out on its own, no reason to force a destroy on them.
resource "aws_cloudwatch_log_group" "hello_world" {
  name              = "/ecs/${var.project}-hello-world"
  retention_in_days = 7

  tags = { Name = "${var.project}-hello-world-logs" }
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # cost minimization
  }

  tags = { Name = "${var.project}-cluster" }
}

resource "aws_cloudwatch_log_group" "admission_api" {
  name              = "/ecs/${var.project}-admission-api"
  retention_in_days = 7

  tags = { Name = "${var.project}-admission-api-logs" }
}

# This is only ever the FIRST task definition revision (image tag "v1").
# Every deployment after this one registers a brand-new revision out of
# band via scripts/deploy.py; Terraform never touches it again — see the
# ignore_changes below. Cloned from the hello-world proof (see
# infra/reference/hello-world-blue-green/ecs.tf) with a real task role
# added for DynamoDB access.
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
