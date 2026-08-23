# Shared cluster — every Fargate service (admission_api.tf,
# queue_controller.tf, ...) runs in this one cluster.
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled" # cost minimization
  }

  tags = { Name = "${var.project}-cluster" }
}
