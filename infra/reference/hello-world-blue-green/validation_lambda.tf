# boto3 ships in the Lambda Python runtime by default, so the single source
# file is all that needs zipping — no dependency packaging step.
data "archive_file" "validation_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src"
  output_path = "${path.module}/.build/validate_hello_world.zip"
}

resource "aws_lambda_function" "validate_hello_world" {
  function_name    = "${var.project}-hw-validate"
  role             = aws_iam_role.validation_lambda.arn
  handler          = "validate_hello_world.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.validation_lambda.output_path
  source_code_hash = data.archive_file.validation_lambda.output_base64sha256
  timeout          = 10

  # No VPC config: the ALB is internet-facing, so the Lambda reaches the
  # test listener over the public internet directly — matches CLAUDE.md's
  # rationale for keeping Lambda services (Room Admin API) VPC-free.
  environment {
    variables = {
      TEST_ENDPOINT = "http://${aws_lb.hello_world.dns_name}:8080/"
    }
  }

  tags = { Name = "${var.project}-hw-validate" }
}

resource "aws_cloudwatch_log_group" "validation_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.validate_hello_world.function_name}"
  retention_in_days = 7

  tags = { Name = "${var.project}-hw-validate-logs" }
}
