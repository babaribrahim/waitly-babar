# Shared roles only. Per-service task roles and validation Lambda roles
# live in that service's own file (admission_api.tf, queue_controller.tf).

# --- ECS task execution role: pulls the image from ECR, ships logs ---
# Generic (AWS-managed policy, no per-service scoping needed) — shared
# across every Fargate service in this project.

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

# --- CodeDeploy service role: drives Lambda alias traffic shifting ---
# A separate managed policy from the ECS one above (Lambda deployments use
# alias weighted-routing, not target groups), otherwise the same idea.

resource "aws_iam_role" "codedeploy_lambda" {
  name               = "${var.project}-codedeploy-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume.json

  tags = { Name = "${var.project}-codedeploy-lambda-role" }
}

resource "aws_iam_role_policy_attachment" "codedeploy_lambda" {
  role       = aws_iam_role.codedeploy_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRoleForLambda"
}

# scripts/deploy_lambda.py never needed this - it always passes the
# AppSpec inline (AppSpecContent), so CodeDeploy never had to read it
# from anywhere. CodePipeline's CodeDeploy action is different: it hands
# CodeDeploy an S3-based revision (the AppSpec artifact sitting in the
# pipeline's own bucket), so the first time that path actually ran it
# failed with IAM_ROLE_PERMISSIONS - AWSCodeDeployRoleForLambda covers
# Lambda alias/version operations and CloudWatch alarms, not S3 reads.
resource "aws_iam_role_policy" "codedeploy_lambda_pipeline_artifacts" {
  name = "${var.project}-codedeploy-lambda-s3"
  role = aws_iam_role.codedeploy_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:GetObjectVersion"]
      Resource = "${aws_s3_bucket.pipeline_artifacts.arn}/*"
    }]
  })
}

# --- Shared assume-role policy for every service's Lambda functions ---
# (validation-hook Lambdas and any real Lambda service, e.g. Room Admin API)

data "aws_iam_policy_document" "validation_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
