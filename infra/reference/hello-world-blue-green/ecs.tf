resource "aws_cloudwatch_log_group" "hello_world" {
  name              = "/ecs/${var.project}-hello-world"
  retention_in_days = 7

  tags = { Name = "${var.project}-hello-world-logs" }
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # cost minimization — not needed for a hello-world proof
  }

  tags = { Name = "${var.project}-cluster" }
}

# This is only ever the FIRST task definition revision (image tag "blue").
# Every deployment after this one registers a brand-new revision out of
# band via scripts/deploy.py; Terraform never touches it again — see the
# ignore_changes below.
resource "aws_ecs_task_definition" "hello_world" {
  family                   = "${var.project}-hello-world"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "hello-world"
    image     = "${aws_ecr_repository.hello_world.repository_url}:blue"
    essential = true
    portMappings = [{
      containerPort = var.hello_world_container_port
      protocol      = "tcp"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.hello_world.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "hello-world"
      }
    }
  }])

  tags = { Name = "${var.project}-hello-world-task" }
}

resource "aws_ecs_service" "hello_world" {
  name            = "${var.project}-hello-world"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.hello_world.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = "hello-world"
    container_port   = var.hello_world_container_port
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

  depends_on = [aws_lb_listener.prod, aws_lb_listener.test]

  tags = { Name = "${var.project}-hello-world-service" }
}
