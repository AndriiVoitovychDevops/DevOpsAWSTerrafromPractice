output "cli_access_key_ids" {
  value = { for name, key in aws_iam_access_key.cli : name => key.id }
}

output "cli_secret_keys" {
  value     = { for name, key in aws_iam_access_key.cli : name => key.secret }
  sensitive = true
}

output "console_login_url" {
  value = "https://${local.account_id}.signin.aws.amazon.com/console"
}

output "console_passwords" {
  value     = { for name, p in aws_iam_user_login_profile.console : name => p.password }
  sensitive = true
}

output "role_a_arn" {
  value = aws_iam_role.role_a.arn
}

output "role_b_arn" {
  value = aws_iam_role.role_b.arn
}

output "role_b_instance_profile" {
  value = aws_iam_instance_profile.role_b.name
}

output "role_c_arn" {
  value = aws_iam_role.role_c.arn
}

output "test_bucket" {
  value = aws_s3_bucket.test.bucket
}
