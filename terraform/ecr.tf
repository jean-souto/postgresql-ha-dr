# =============================================================================
# Amazon ECR - Container Registry
# =============================================================================
# Stores Docker images for the PostgreSQL HA/DR Demo API

# -----------------------------------------------------------------------------
# ECR Repository - Python API
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "api_python" {
  name                 = "${local.name_prefix}-api-python"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, {
    Name     = "${local.name_prefix}-api-python"
    Language = "Python"
  })
}

resource "aws_ecr_lifecycle_policy" "api_python" {
  repository = aws_ecr_repository.api_python.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# ECR Repository - Go API
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "api_go" {
  name                 = "${local.name_prefix}-api-go"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, {
    Name     = "${local.name_prefix}-api-go"
    Language = "Go"
  })
}

resource "aws_ecr_lifecycle_policy" "api_go" {
  repository = aws_ecr_repository.api_go.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "ecr_repository_python_url" {
  description = "ECR repository URL for Python API"
  value       = aws_ecr_repository.api_python.repository_url
}

output "ecr_repository_go_url" {
  description = "ECR repository URL for Go API"
  value       = aws_ecr_repository.api_go.repository_url
}

output "ecr_push_commands_python" {
  description = "Commands to push Python API image to ECR"
  value       = <<-EOT
    # Authenticate Docker to ECR
    aws ecr get-login-password --region ${var.aws_region} --profile postgresql-ha-profile | docker login --username AWS --password-stdin ${aws_ecr_repository.api_python.repository_url}

    # Build and push Python API
    cd api
    docker build -t ${aws_ecr_repository.api_python.repository_url}:latest .
    docker push ${aws_ecr_repository.api_python.repository_url}:latest
  EOT
}

output "ecr_push_commands_go" {
  description = "Commands to push Go API image to ECR"
  value       = <<-EOT
    # Authenticate Docker to ECR
    aws ecr get-login-password --region ${var.aws_region} --profile postgresql-ha-profile | docker login --username AWS --password-stdin ${aws_ecr_repository.api_go.repository_url}

    # Build and push Go API
    cd api-go
    docker build -t ${aws_ecr_repository.api_go.repository_url}:latest .
    docker push ${aws_ecr_repository.api_go.repository_url}:latest
  EOT
}
