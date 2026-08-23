# The hello-world proof's ECR repo and task logs are deliberately left in
# place, untouched — see infra/reference/hello-world-blue-green/. Its two
# images (v1, v2) are the exact artifacts behind the proven blue/green
# deployments documented there. Negligible cost to keep as provenance.
resource "aws_ecr_repository" "hello_world" {
  name                 = "${var.project}/hello-world"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.project}-ecr-hello-world" }
}

resource "aws_ecr_lifecycle_policy" "hello_world" {
  repository = aws_ecr_repository.hello_world.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recently pushed images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "hello_world" {
  name              = "/ecs/${var.project}-hello-world"
  retention_in_days = 7

  tags = { Name = "${var.project}-hello-world-logs" }
}
