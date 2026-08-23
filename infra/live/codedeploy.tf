# Direct clone of the proven hello-world CodeDeploy shape — see
# infra/reference/hello-world-blue-green/codedeploy.tf. Same canary config,
# same blue/green + validation-hook wiring, now against the real service.
resource "aws_codedeploy_app" "admission_api" {
  name             = "${var.project}-admission-api"
  compute_platform = "ECS"

  tags = { Name = "${var.project}-admission-api-app" }
}

resource "aws_codedeploy_deployment_group" "admission_api" {
  app_name               = aws_codedeploy_app.admission_api.name
  deployment_group_name  = "${var.project}-admission-api-dg"
  service_role_arn       = aws_iam_role.codedeploy_ecs.arn
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.admission_api.name
  }

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  # CodeDeploy decides which of these two target groups is currently idle
  # at deploy time — the AppSpec deploy.py sends never has to name "blue"
  # or "green" explicitly.
  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.admission_api_prod.arn]
      }
      test_traffic_route {
        listener_arns = [aws_lb_listener.admission_api_test.arn]
      }
      target_group {
        name = aws_lb_target_group.admission_api_blue.name
      }
      target_group {
        name = aws_lb_target_group.admission_api_green.name
      }
    }
  }

  tags = { Name = "${var.project}-admission-api-dg" }
}
