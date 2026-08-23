output "region" {
  value = var.region
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "alb_dns_name" {
  value = aws_lb.hello_world.dns_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_task_execution_role_arn" {
  value = aws_iam_role.ecs_task_execution.arn
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.main.name
}

output "dynamodb_table_arn" {
  value = aws_dynamodb_table.main.arn
}

# One object per deployable service — scripts/deploy.py picks a service by
# name (matching this output's key) and reads everything it needs from it.
# Add a new object here, matching this shape, whenever a new service is
# cloned from the pattern.

output "admission_api" {
  value = {
    ecr_repository_url               = aws_ecr_repository.admission_api.repository_url
    container_name                   = "admission-api"
    task_definition_family           = aws_ecs_task_definition.admission_api.family
    task_role_arn                    = aws_iam_role.admission_api_task.arn
    log_group_name                   = aws_cloudwatch_log_group.admission_api.name
    codedeploy_app_name              = aws_codedeploy_app.admission_api.name
    codedeploy_deployment_group_name = aws_codedeploy_deployment_group.admission_api.deployment_group_name
    validation_lambda_arn            = aws_lambda_function.admission_api_validate.arn
    prod_listener_arn                = aws_lb_listener.admission_api_prod.arn
    test_listener_arn                = aws_lb_listener.admission_api_test.arn
  }
}

output "queue_controller" {
  value = {
    ecr_repository_url               = aws_ecr_repository.queue_controller.repository_url
    container_name                   = "queue-controller"
    task_definition_family           = aws_ecs_task_definition.queue_controller.family
    task_role_arn                    = aws_iam_role.queue_controller_task.arn
    log_group_name                   = aws_cloudwatch_log_group.queue_controller.name
    codedeploy_app_name              = aws_codedeploy_app.queue_controller.name
    codedeploy_deployment_group_name = aws_codedeploy_deployment_group.queue_controller.deployment_group_name
    validation_lambda_arn            = aws_lambda_function.queue_controller_validate.arn
    prod_listener_arn                = aws_lb_listener.queue_controller_prod.arn
    test_listener_arn                = aws_lb_listener.queue_controller_test.arn
  }
}

# Lambda services use a different shape (no ECR/ECS fields) - read by
# scripts/deploy_lambda.py instead of scripts/deploy.py.
output "room_admin_api" {
  value = {
    function_name                    = aws_lambda_function.room_admin_api.function_name
    alias_name                       = aws_lambda_alias.room_admin_api_live.name
    codedeploy_app_name              = aws_codedeploy_app.room_admin_api.name
    codedeploy_deployment_group_name = aws_codedeploy_deployment_group.room_admin_api.deployment_group_name
    api_endpoint                     = aws_apigatewayv2_stage.room_admin_api_default.invoke_url
  }
}
