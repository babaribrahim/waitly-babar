resource "aws_ecr_repository" "hello_world" {
  name                 = "${var.project}/hello-world"
  image_tag_mutability = "MUTABLE" # deploy.py reuses the "blue"/"green" tags across deployments

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
