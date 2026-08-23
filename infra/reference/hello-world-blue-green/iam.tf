# --- ECS task execution role: pulls the image from ECR, ships logs ---

data "aws_iam_policy_document" "ecs_task_execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project}-hw-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json

  tags = { Name = "${var.project}-hw-exec-role" }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- CodeDeploy service role: drives the ECS blue/green traffic shift ---

data "aws_iam_policy_document" "codedeploy_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy_ecs" {
  name               = "${var.project}-hw-codedeploy-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume.json

  tags = { Name = "${var.project}-hw-codedeploy-role" }
}

resource "aws_iam_role_policy_attachment" "codedeploy_ecs" {
  role       = aws_iam_role.codedeploy_ecs.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# --- Validation Lambda role: calls the test listener, reports back to CodeDeploy ---

data "aws_iam_policy_document" "validation_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "validation_lambda" {
  name               = "${var.project}-hw-validate-role"
  assume_role_policy = data.aws_iam_policy_document.validation_lambda_assume.json

  tags = { Name = "${var.project}-hw-validate-role" }
}

resource "aws_iam_role_policy_attachment" "validation_lambda_logs" {
  role       = aws_iam_role.validation_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "validation_lambda_codedeploy" {
  name = "${var.project}-hw-validate-codedeploy"
  role = aws_iam_role.validation_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codedeploy:PutLifecycleEventHookExecutionStatus"
      Resource = "*"
    }]
  })
}
