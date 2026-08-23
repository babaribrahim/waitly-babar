output "region" {
  value = var.region
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "alb_dns_name" {
  value = aws_lb.hello_world.dns_name
}

output "prod_listener_arn" {
  value = aws_lb_listener.admission_api_prod.arn
}

output "test_listener_arn" {
  value = aws_lb_listener.admission_api_test.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.admission_api.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.admission_api.name
}

output "container_name" {
  value = "admission-api"
}

output "task_definition_family" {
  value = aws_ecs_task_definition.admission_api.family
}

output "ecs_task_execution_role_arn" {
  value = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_role_arn" {
  value = aws_iam_role.admission_api_task.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.admission_api.name
}

output "codedeploy_app_name" {
  value = aws_codedeploy_app.admission_api.name
}

output "codedeploy_deployment_group_name" {
  value = aws_codedeploy_deployment_group.admission_api.deployment_group_name
}

output "validation_lambda_arn" {
  value = aws_lambda_function.admission_api_validate.arn
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.main.name
}

output "dynamodb_table_arn" {
  value = aws_dynamodb_table.main.arn
}
