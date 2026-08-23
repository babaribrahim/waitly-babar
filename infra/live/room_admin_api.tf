# Room Admin API: AWS Lambda + API Gateway (HTTP API), no VPC. Low,
# occasional organizer traffic - doesn't need to stay warm, so a
# full-time container isn't justified (see CLAUDE.md's compute rationale).
#
# Deployed via CodeDeploy too, but a different mechanism from the ECS
# services: Lambda alias weighted-routing traffic shift, not ALB
# target-group blue/green. scripts/deploy_lambda.py drives it.

resource "aws_iam_role" "room_admin_api" {
  name               = "${var.project}-room-admin-api-role"
  assume_role_policy = data.aws_iam_policy_document.validation_lambda_assume.json

  tags = { Name = "${var.project}-room-admin-api-role" }
}

resource "aws_iam_role_policy_attachment" "room_admin_api_logs" {
  role       = aws_iam_role.room_admin_api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "room_admin_api_dynamodb" {
  name = "${var.project}-room-admin-api-dynamodb"
  role = aws_iam_role.room_admin_api.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Scan"]
      Resource = aws_dynamodb_table.main.arn
    }]
  })
}

# No separate SSM/demo-mode IAM policy needed: the /demo/mode route
# (apps/demo-control/index.html) writes to the same DynamoDB table via
# room_admin_api_dynamodb above (PK=CONFIG#protected-site, SK=MODE) -
# see protected_site.tf for why this lives in DynamoDB, not SSM.

data "archive_file" "room_admin_api" {
  type        = "zip"
  source_dir  = "${path.module}/../../apps/room-admin-api"
  output_path = "${path.module}/.build/room_admin_api.zip"
}

# publish = true is required for CodeDeploy Lambda traffic shifting - it
# needs real numbered versions to shift weight between, not just $LATEST.
# This is only ever the FIRST version; every deploy after this one
# publishes a new one out of band via scripts/deploy_lambda.py.
resource "aws_lambda_function" "room_admin_api" {
  function_name    = "${var.project}-room-admin-api"
  role             = aws_iam_role.room_admin_api.arn
  handler          = "app.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.room_admin_api.output_path
  source_code_hash = data.archive_file.room_admin_api.output_base64sha256
  timeout          = 10
  publish          = true

  # AWS_REGION is deliberately not set here: Lambda reserves that key and
  # provides it automatically, rejecting CreateFunction if you also try
  # to set it yourself. app.py's os.environ.get("AWS_REGION", ...) picks
  # up the runtime-provided value with no code change needed.
  environment {
    variables = {
      TABLE_NAME            = aws_dynamodb_table.main.name
      POLL_INTERVAL_SECONDS = "5"
      DEMO_ROOM_ID          = "demo"
      # FRONTEND_BASE_URL deliberately unset until the frontend phase
      # exists - publicLink comes back null until then, no code change
      # needed later, just set this variable.
    }
  }

  tags = { Name = "${var.project}-room-admin-api" }
}

resource "aws_cloudwatch_log_group" "room_admin_api" {
  name              = "/aws/lambda/${aws_lambda_function.room_admin_api.function_name}"
  retention_in_days = 7

  tags = { Name = "${var.project}-room-admin-api-logs" }
}

# API Gateway's integration points at this alias, not the bare function.
# CodeDeploy repoints the alias's weighted routing config directly during
# every deployment - Terraform must not fight it for control after the
# first deploy.
resource "aws_lambda_alias" "room_admin_api_live" {
  name             = "live"
  function_name    = aws_lambda_function.room_admin_api.function_name
  function_version = aws_lambda_function.room_admin_api.version

  lifecycle {
    ignore_changes = [function_version, routing_config]
  }
}

resource "aws_apigatewayv2_api" "room_admin_api" {
  name          = "${var.project}-room-admin-api"
  protocol_type = "HTTP"

  # Permissive default: the frontend doesn't exist yet, so its real
  # origin isn't known. Worth tightening to the real origin once the
  # frontend's CloudFront domain exists.
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PATCH", "OPTIONS"]
    allow_headers = ["content-type", "x-admin-key"]
  }

  tags = { Name = "${var.project}-room-admin-api" }
}

resource "aws_apigatewayv2_stage" "room_admin_api_default" {
  api_id      = aws_apigatewayv2_api.room_admin_api.id
  name        = "$default"
  auto_deploy = true

  tags = { Name = "${var.project}-room-admin-api-stage" }
}

resource "aws_apigatewayv2_integration" "room_admin_api" {
  api_id                 = aws_apigatewayv2_api.room_admin_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.room_admin_api_live.invoke_arn
  payload_format_version = "2.0"
}

locals {
  room_admin_api_routes = [
    "POST /rooms",
    "GET /rooms",
    "GET /rooms/{roomId}",
    "PATCH /rooms/{roomId}",
    "GET /demo/status",
    "POST /demo/mode",
  ]
}

# Known, deliberate limitation, reviewed not overlooked: none of these
# routes has an API Gateway authorizer attached. GET /rooms/{roomId} and
# PATCH /rooms/{roomId} are gated inside the Lambda itself via the
# per-room admin-key-hash check (app.py). POST /rooms and GET /rooms are
# intentionally open - there is no owner/tenant model in the schema, so
# GET /rooms means anyone can enumerate all room names and ids. Acceptable
# at this project's scope (matches CLAUDE.md's "proportionate to scope,
# not a full auth system"); the same treatment as the :8091 ALB exposure
# in security_groups.tf.
#
# GET/POST /demo/* are also unauthenticated, same reasoning: they back
# apps/demo-control/index.html, a demo-only page (not the real product
# UI), and the worst anyone can do with them is flip a fake site's mode
# or read a demo room's stats - no real user data involved.
resource "aws_apigatewayv2_route" "room_admin_api" {
  for_each = toset(local.room_admin_api_routes)

  api_id    = aws_apigatewayv2_api.room_admin_api.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.room_admin_api.id}"
}

resource "aws_lambda_permission" "room_admin_api_apigateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.room_admin_api.function_name
  qualifier     = aws_lambda_alias.room_admin_api_live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.room_admin_api.execution_arn}/*/*"
}

resource "aws_codedeploy_app" "room_admin_api" {
  name             = "${var.project}-room-admin-api"
  compute_platform = "Lambda"

  tags = { Name = "${var.project}-room-admin-api-app" }
}

resource "aws_codedeploy_deployment_group" "room_admin_api" {
  app_name               = aws_codedeploy_app.room_admin_api.name
  deployment_group_name  = "${var.project}-room-admin-api-dg"
  service_role_arn       = aws_iam_role.codedeploy_lambda.arn
  deployment_config_name = "CodeDeployDefault.LambdaCanary10Percent5Minutes"

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  # No ecs_service / load_balancer_info block here - unlike the ECS
  # deployment groups, Lambda CodeDeploy deployments don't pre-declare
  # their target in Terraform. Which function/alias/version to shift is
  # carried entirely in the AppSpec sent at deploy time (see
  # scripts/deploy_lambda.py).

  tags = { Name = "${var.project}-room-admin-api-dg" }
}
