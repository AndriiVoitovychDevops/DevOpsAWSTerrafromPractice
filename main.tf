# group1
resource "aws_iam_group" "group1" {
  name = "group1"
  path = "/cli-only/"
}

# cli users
resource "aws_iam_user" "cli" {
  for_each      = toset(["ci", "engine"])
  name          = each.value
  path          = "/cli-only/"
  force_destroy = true
}

resource "aws_iam_user_group_membership" "cli" {
  for_each = aws_iam_user.cli
  user     = each.value.name
  groups   = [aws_iam_group.group1.name]
}

resource "aws_iam_access_key" "cli" {
  for_each = aws_iam_user.cli
  user     = each.value.name
}

# group2
resource "aws_iam_group" "group2" {
  name = "group2"
  path = "/console-users/"
}

# console users
resource "aws_iam_user" "console" {
  for_each = {
    "denys.platon"  = "Denys Platon"
    "ivan.petrenko" = "Ivan Petrenko"
  }
  name          = each.key
  path          = "/console-users/"
  force_destroy = true

  tags = {
    FullName = each.value
  }
}

resource "aws_iam_user_group_membership" "console" {
  for_each = aws_iam_user.console
  user     = each.value.name
  groups   = [aws_iam_group.group2.name]
}

# access for console users with random pass
resource "aws_iam_user_login_profile" "console" {
  for_each                = aws_iam_user.console
  user                    = each.value.name
  password_length         = 20
  password_reset_required = true

  lifecycle {
    ignore_changes = [password_length, password_reset_required]
  }
}

# creating politics for users \ groups

# get current accountID

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  account_b_id = local.account_id
}


# policy to manage only own access keys

resource "aws_iam_policy" "manage_own_keys" {
  name        = "manage-own-access-keys"
  description = "Users can manage only their own access keys"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageOwnAccessKeys"
        Effect = "Allow"
        Action = [
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:ListAccessKeys",
          "iam:UpdateAccessKey",
          "iam:GetAccessKeyLastUsed",
        ]
        Resource = "arn:aws:iam::${local.account_id}:user/*/$${aws:username}"
      }
    ]
  })
}


# policy for group1
resource "aws_iam_group_policy_attachment" "group1_readonly" {
  group      = aws_iam_group.group1.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_group_policy_attachment" "group1_own_keys" {
  group      = aws_iam_group.group1.name
  policy_arn = aws_iam_policy.manage_own_keys.arn
}


# policy for group2
resource "aws_iam_group_policy_attachment" "group2_readonly" {
  group      = aws_iam_group.group2.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_group_policy_attachment" "group2_own_keys" {
  group      = aws_iam_group.group2.name
  policy_arn = aws_iam_policy.manage_own_keys.arn
}


resource "aws_iam_group_policy_attachment" "group2_change_password" {
  group      = aws_iam_group.group2.name
  policy_arn = "arn:aws:iam::aws:policy/IAMUserChangePassword"
}

# creating roleA

resource "aws_iam_role" "role_a" {
  name                 = "roleA"
  description          = "Administator with all right except IAM"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "role_a_admin_except_iam" {
  name        = "roleA-admin-without-iam"
  description = "Allow everything except IAM"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      NotAction = ["iam:*"]
      Resource  = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "role_a" {
  role       = aws_iam_role.role_a.name
  policy_arn = aws_iam_policy.role_a_admin_except_iam.arn
}

resource "aws_iam_policy" "assume_role_a" {
  name = "assume-roleA"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Resource = aws_iam_role.role_a.arn
      Action   = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_group_policy_attachment" "group2_assume_role_a" {
  group      = aws_iam_group.group2.name
  policy_arn = aws_iam_policy.assume_role_a.arn
}

# creating roleB

resource "aws_iam_role" "role_b" {
  name        = "roleB"
  description = "Service role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
      }, {
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "role_b_assume_role_c" {
  name = "assume-roleC"
  role = aws_iam_role.role_b.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = "arn:aws:iam::${local.account_b_id}:role/roleC"
    }]
  })
}

resource "aws_iam_instance_profile" "role_b" {
  name = "roleB-instance-profile"
  role = aws_iam_role.role_b.name
}

# creating bucket for roleC

resource "aws_s3_bucket" "test" {
  bucket        = "aws-test-bucket-${local.account_b_id}"
  force_destroy = true
}

# bucket restrict public access

resource "aws_s3_bucket_public_access_block" "test" {
  bucket = aws_s3_bucket.test.id

  block_public_policy = true
}

# creating roleC


resource "aws_iam_role" "role_c" {
  name        = "roleC"
  description = "roleC-bucket-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.role_b.arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "role_c_s3" {
  name = "s3-bucket-access"
  role = aws_iam_role.role_c.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
      Resource = aws_s3_bucket.test.arn
      }, {
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.test.arn}/*"
    }]
  })
}
