# boto3 ships in the Lambda Python runtime by default, so the single source
# file is all that needs zipping — no dependency packaging step.
data "archive_file" "admission_api_validate" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src/admission_api_validate"
  output_path = "${path.module}/.build/admission_api_validate.zip"
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
