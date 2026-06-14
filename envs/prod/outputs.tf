output "name_servers" {
  description = "ドメインを取得した事業者（お名前.com等）に登録するNSレコードです"
  value       = aws_route53_zone.main.name_servers
}

# output "s3_bucket_name" {
#   description = "HTML等をアップロードするS3バケット名"
#   value       = aws_s3_bucket.web_bucket.id
# }
