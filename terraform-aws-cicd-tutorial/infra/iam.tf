# ============================================================
# EC2 Instance Role
# ============================================================

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid    = "AllowEC2AssumeRole"
    effect = "Allow"

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "ec2.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name_prefix        = "${local.name_prefix}-ec2-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-role"
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "${local.name_prefix}-ec2-"
  role        = aws_iam_role.ec2.name

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-instance-profile"
  })
}

# SSM Session Manager を使うためのAWS管理ポリシー
resource "aws_iam_role_policy_attachment" "ec2_ssm_managed_instance_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EC2上のCodeDeploy AgentがS3 artifact bucketから成果物を取得するためのポリシー
data "aws_iam_policy_document" "ec2_artifact_read" {
  statement {
    sid    = "AllowGetBucketLocation"
    effect = "Allow"

    actions = [
      "s3:GetBucketLocation"
    ]

    resources = [
      aws_s3_bucket.artifact.arn
    ]
  }

  statement {
    sid    = "AllowListArtifactBucket"
    effect = "Allow"

    actions = [
      "s3:ListBucket"
    ]

    resources = [
      aws_s3_bucket.artifact.arn
    ]
  }

  statement {
    sid    = "AllowReadArtifactObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion"
    ]

    resources = [
      "${aws_s3_bucket.artifact.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "ec2_artifact_read" {
  name_prefix = "${local.name_prefix}-ec2-artifact-read-"
  description = "Allow EC2 instances to read CodeDeploy artifacts from S3"
  policy      = data.aws_iam_policy_document.ec2_artifact_read.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-artifact-read"
  })
}

resource "aws_iam_role_policy_attachment" "ec2_artifact_read" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.ec2_artifact_read.arn
}


# ============================================================
# CodeDeploy Service Role
# ============================================================

data "aws_iam_policy_document" "codedeploy_assume_role" {
  statement {
    sid    = "AllowCodeDeployAssumeRole"
    effect = "Allow"

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "codedeploy.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name_prefix        = "${local.name_prefix}-codedeploy-"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-codedeploy-role"
  })
}

# EC2/オンプレミス向けCodeDeployで使うAWS管理ポリシー
resource "aws_iam_role_policy_attachment" "codedeploy_service_role" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}