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

# extra_env carries any service-specific environment variables beyond the
# generic AWS_REGION/TABLE_NAME scripts/deploy.py already knows about.
# Without this, any env var set only in a service's *initial* Terraform
# task definition (like queue_controller's PROTECTED_SITE_* below) gets
# silently dropped the moment deploy.py registers the next revision -
# found the hard way. Every service output should include this field,
# even if empty, so deploy.py's merge logic never has to special-case one.

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
    extra_env                        = {}
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
    extra_env = {
      PROTECTED_SITE_LB_ARN_SUFFIX           = aws_lb.hello_world.arn_suffix
      PROTECTED_SITE_TARGET_GROUP_ARN_SUFFIX = aws_lb_target_group.protected_site.arn_suffix
    }
  }
}

# Protected-site fixture: not deployed via scripts/deploy.py (plain ECS
# rolling deploy, not CodeDeploy) - see scripts/deploy_protected_site.py.
output "protected_site_ecr_repository_url" {
  value = aws_ecr_repository.protected_site.repository_url
}

output "protected_site_task_definition_family" {
  value = aws_ecs_task_definition.protected_site.family
}

output "protected_site_task_role_arn" {
  value = aws_iam_role.protected_site_task.arn
}

output "protected_site_log_group_name" {
  value = aws_cloudwatch_log_group.protected_site.name
}

output "protected_site_service_name" {
  value = aws_ecs_service.protected_site.name
}

output "protected_site_url" {
  value = "http://${aws_lb.hello_world.dns_name}:8100/"
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
