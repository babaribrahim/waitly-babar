# --- ECS task execution role: pulls the image from ECR, ships logs ---
# Generic (AWS-managed policy, no per-service scoping needed) — shared
# across every Fargate service in this project, not just Admission API.

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
  name               = "${var.project}-ecs-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume.json

  tags = { Name = "${var.project}-ecs-exec-role" }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- CodeDeploy service role: drives every ECS blue/green traffic shift ---
# Also generic/shared — CodeDeploy service roles aren't scoped per-app.

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
  name               = "${var.project}-codedeploy-ecs-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume.json

  tags = { Name = "${var.project}-codedeploy-ecs-role" }
}

resource "aws_iam_role_policy_attachment" "codedeploy_ecs" {
  role       = aws_iam_role.codedeploy_ecs.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# --- Admission API task role: what the container itself assumes to call DynamoDB ---
# Distinct from the execution role above — this is service-specific and
# scoped to exactly the operations app.py performs, on exactly this table.

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

# --- Admission API validation Lambda role: calls the test listener, reports back to CodeDeploy ---

data "aws_iam_policy_document" "validation_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
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
