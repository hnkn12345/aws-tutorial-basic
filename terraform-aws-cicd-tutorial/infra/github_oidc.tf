# ============================================================
# GitHub Actions OIDC Provider
# ============================================================

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-github-oidc"
  })
}


# ============================================================
# GitHub Actions Role
# ============================================================

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    sid    = "AllowGitHubActionsAssumeRole"
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"
      identifiers = [
        aws_iam_openid_connect_provider.github.arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name_prefix        = "${local.name_prefix}-gha-"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-github-actions-role"
  })
}


# ============================================================
# GitHub Actions Permissions
# ============================================================

data "aws_iam_policy_document" "github_actions_deploy" {
  statement {
    sid    = "AllowReadArtifactBucketMetadata"
    effect = "Allow"

    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]

    resources = [
      aws_s3_bucket.artifact.arn
    ]
  }

  statement {
    sid    = "AllowUploadDeploymentArtifacts"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload"
    ]

    resources = [
      "${aws_s3_bucket.artifact.arn}/revisions/*"
    ]
  }

  statement {
    sid    = "AllowCreateAndCheckCodeDeployDeployment"
    effect = "Allow"

    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:GetApplication",
      "codedeploy:GetDeploymentGroup",
      "codedeploy:ListDeployments"
    ]

    resources = [
      "*"
    ]
  }
}

resource "aws_iam_policy" "github_actions_deploy" {
  name_prefix = "${local.name_prefix}-gha-deploy-"
  description = "Allow GitHub Actions to upload artifacts and create CodeDeploy deployments"
  policy      = data.aws_iam_policy_document.github_actions_deploy.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-github-actions-deploy"
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_deploy" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_deploy.arn
}