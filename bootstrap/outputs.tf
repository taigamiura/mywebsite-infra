output "terraform_state_bucket_name" {
  description = "Terraformの状態ファイルを保存するS3バケット名"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "terraform_lock_table_name" {
  description = "Terraformのロック用DynamoDBテーブル名"
  value       = aws_dynamodb_table.terraform_lock.name
}