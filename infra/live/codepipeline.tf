# CodePipeline: one pipeline in the console, covering all three services -
# source -> build -> deploy for each, per CLAUDE.md's CI/CD section.
# GitHub Actions isn't permitted in this environment; this is the
# AWS-native replacement, source-only via a CodeStar Connection (no
# GitHub-side compute involved).
#
# Reuses an already-authorized CodeStar connection ("ibrahim.babar",
# verified AVAILABLE) rather than creating a new one - GitHub OAuth
# authorization is a manual browser step outside Terraform's reach, no
# reason to make a second one when a working connection already exists.
#
# Watches feature/waiting-room-babar, not main - this project's repo
# convention (see CLAUDE.md's implementation log): every intern works on
# their own branch off the shared org repo, nobody touches main.
#
# Known, deliberate limitation: build-side path skip only (see
# buildspecs/ecs_service_build.yml's docstring for the full reasoning) -
# the Deploy stage runs on every execution regardless of whether its
# service changed. Terraform's AWS provider doesn't yet expose
# CodePipeline V2's native stage-skip condition
# (hashicorp/terraform-provider-aws#40454, #39284) - implementing it for
# real would mean managing part of the pipeline outside Terraform state,
# not worth the risk under this project's timeline. When it did change,
# it correctly deploys; when it didn't, it redeploys the same image
# (slower than ideal, still correct).

data "aws_caller_identity" "current" {}

locals {
  codestar_connection_arn = "arn:aws:codeconnections:us-west-2:395063533284:connection/b47e864f-7e26-48ad-a1c8-57f469fa5c20"
  github_repo_id          = "awabamjad1/internship-program-2026"
  github_branch           = "feature/waiting-room-babar"
}

resource "random_id" "pipeline_artifacts_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket = "${var.project}-pipeline-artifacts-${random_id.pipeline_artifacts_suffix.hex}"

  tags = { Name = "${var.project}-pipeline-artifacts" }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket                  = aws_s3_bucket.pipeline_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- CodePipeline service role ---

data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "${var.project}-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume.json

  tags = { Name = "${var.project}-codepipeline-role" }
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "${var.project}-codepipeline-policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"]
        Resource = [aws_s3_bucket.pipeline_artifacts.arn, "${aws_s3_bucket.pipeline_artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = [local.codestar_connection_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "codedeploy:CreateDeployment",
          "codedeploy:GetApplication",
          "codedeploy:GetApplicationRevision",
          "codedeploy:GetDeployment",
          "codedeploy:GetDeploymentConfig",
          "codedeploy:RegisterApplicationRevision",
        ]
        Resource = "*"
      },
      {
        # The CodeDeployToECS pipeline action registers the new task
        # definition itself (from taskdef.json) before handing the ARN to
        # CodeDeploy - so CodePipeline's own role needs this, not just
        # CodeBuild's or CodeDeploy's.
        Effect   = "Allow"
        Action   = ["ecs:RegisterTaskDefinition", "ecs:DescribeServices", "ecs:DescribeTaskDefinition"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "*"
        Condition = {
          StringEqualsIfExists = {
            "iam:PassedToService" = ["ecs-tasks.amazonaws.com"]
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction", "lambda:GetFunction"]
        Resource = "*"
      },
    ]
  })
}

# --- CodeBuild service role (shared across all per-service projects) ---

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.project}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json

  tags = { Name = "${var.project}-codebuild-role" }
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${var.project}-codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project}-*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.pipeline_artifacts.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${var.project}/*"
      },
      {
        # Scoped to the pipeline's own SSM namespace only - the build-skip
        # hash/tag markers, nothing else. See ecs_service_build.yml.
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/pipeline/*"
      },
    ]
  })
}

# --- Admission API: CodeBuild project ---

resource "aws_codebuild_project" "admission_api" {
  name         = "${var.project}-admission-api-build"
  service_role = aws_iam_role.codebuild.arn
  # 15 min default is plenty - a docker build here takes well under 5.

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    type                        = "LINUX_CONTAINER"
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    privileged_mode             = true # docker build/push needs this
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "SERVICE_DIR"
      value = "admission-api"
    }
    environment_variable {
      name  = "ECR_REPO_URI"
      value = aws_ecr_repository.admission_api.repository_url
    }
    environment_variable {
      name  = "SSM_HASH_PARAM"
      value = "/${var.project}/pipeline/admission-api/last-built-hash"
    }
    environment_variable {
      name  = "SSM_IMAGE_TAG_PARAM"
      value = "/${var.project}/pipeline/admission-api/last-built-image-tag"
    }
    environment_variable {
      name  = "TASK_FAMILY"
      value = aws_ecs_task_definition.admission_api.family
    }
    environment_variable {
      name  = "CONTAINER_NAME"
      value = "admission-api"
    }
    environment_variable {
      name  = "CONTAINER_PORT"
      value = tostring(var.admission_api_container_port)
    }
    environment_variable {
      name  = "EXEC_ROLE_ARN"
      value = aws_iam_role.ecs_task_execution.arn
    }
    environment_variable {
      name  = "TASK_ROLE_ARN"
      value = aws_iam_role.admission_api_task.arn
    }
    environment_variable {
      name  = "LOG_GROUP"
      value = aws_cloudwatch_log_group.admission_api.name
    }
    environment_variable {
      name  = "VALIDATION_LAMBDA_ARN"
      value = aws_lambda_function.admission_api_validate.arn
    }
    environment_variable {
      name = "CONTAINER_ENV_JSON"
      value = jsonencode([
        { name = "TABLE_NAME", value = aws_dynamodb_table.main.name },
        { name = "AWS_REGION", value = var.region },
      ])
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspecs/ecs_service_build.yml")
  }

  tags = { Name = "${var.project}-admission-api-build" }
}

# --- The pipeline itself ---
# Only the Admission API's stages are wired so far - deliberate, per the
# "get one service working end to end before wiring the other two" build
# order. Queue Controller and Room Admin API stages follow the same
# Source -> Build -> Deploy shape once this one's verified.

resource "aws_codepipeline" "main" {
  name     = "${var.project}-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = local.codestar_connection_arn
        FullRepositoryId = local.github_repo_id
        BranchName       = local.github_branch
      }
    }
  }

  stage {
    name = "Build-AdmissionAPI"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["admission_api_build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.admission_api.name
      }
    }
  }

  stage {
    name = "Deploy-AdmissionAPI"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeployToECS"
      version         = "1"
      input_artifacts = ["admission_api_build_output"]

      configuration = {
        ApplicationName                = aws_codedeploy_app.admission_api.name
        DeploymentGroupName            = aws_codedeploy_deployment_group.admission_api.deployment_group_name
        TaskDefinitionTemplateArtifact = "admission_api_build_output"
        TaskDefinitionTemplatePath     = "taskdef.json"
        AppSpecTemplateArtifact        = "admission_api_build_output"
        AppSpecTemplatePath            = "appspec.yaml"
        Image1ArtifactName             = "admission_api_build_output"
        Image1ContainerName            = "IMAGE1_NAME"
      }
    }
  }

  tags = { Name = "${var.project}-pipeline" }
}
