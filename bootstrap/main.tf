# Terraform 自体の設定を開始する
terraform {
  # 利用する Terraform の最低バージョンを指定する
  required_version = ">= 1.5.0"

  # この構成で使う Provider を定義する
  required_providers {
    # AWS Provider を使うことを宣言する
    aws = {
      # AWS Provider の配布元を HashiCorp に指定する
      source  = "hashicorp/aws"
      # AWS Provider のバージョン範囲を 5 系に固定する
      version = "~> 5.0"
    }
  }
}

# デフォルトで使う AWS Provider の設定を開始する
provider "aws" {
  # この bootstrap 構成で操作するリージョンを東京にする
  region = var.region_name

  # この Provider で作る AWS リソースに共通タグを自動付与する
  default_tags {
    # 付与するタグの一覧を定義する
    tags = {
      # このリソースが Terraform により作成されたことを示す
      CreatedBy = "terraform",
      Project   = "mywebsite-bootstrap",
    }
  }
}

# 現在の AWS アカウント情報を取得するデータソースを定義する
data "aws_caller_identity" "current" {}

# 複数箇所で使う名前をまとめるローカル変数を定義する
locals {
  # state 保存用 S3 バケット名をアカウント ID を含めて一意になりやすくする
  terraform_state_bucket_name = "mywebsite-terraform-state-${data.aws_caller_identity.current.account_id}"

  # Terraform のロック管理に使う DynamoDB テーブル名を定義する
  terraform_lock_table_name   = "mywebsite-terraform-lock"
}

# Terraform の state ファイルを保存するための S3 バケットを作成する
resource "aws_s3_bucket" "terraform_state" {
  # 作成する S3 バケット名として local で定義した名前を使う
  bucket = local.terraform_state_bucket_name
  lifecycle {
    # state バケットは一度作ったら削除されないようにする
    prevent_destroy = true
  }
}

# state バケットでバージョニングを有効にする
resource "aws_s3_bucket_versioning" "terraform_state" {
  # 設定対象のバケットとして上で作成した S3 バケットを指定する
  bucket = aws_s3_bucket.terraform_state.id

  # バージョニング設定の中身を定義する
  versioning_configuration {
    # state の更新履歴を残せるように有効化する
    status = "Enabled"
  }
}

# state バケットに対してサーバーサイド暗号化を有効にする
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  # 暗号化設定を適用する対象バケットを指定する
  bucket = aws_s3_bucket.terraform_state.id

  # 暗号化ルールを定義する
  rule {
    # オブジェクト保存時のデフォルト暗号化方式を定義する
    apply_server_side_encryption_by_default {
      # S3 管理キーによる AES256 暗号化を使う
      sse_algorithm = "AES256"
    }
  }
}

# state バケットが公開設定されないようにブロックする
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  # 公開アクセス制御の対象バケットを指定する
  bucket = aws_s3_bucket.terraform_state.id

  # Public ACL の付与を禁止する
  block_public_acls       = true
  # Public Policy の設定を禁止する
  block_public_policy     = true
  # 既存の Public ACL も無視する
  ignore_public_acls      = true
  # 公開バケット化を強く制限する
  restrict_public_buckets = true
}

# Terraform 実行時の競合ロックに使う DynamoDB テーブルを作成する
resource "aws_dynamodb_table" "terraform_lock" {
  # 作成する DynamoDB テーブル名を local で定義した値にする
  name         = local.terraform_lock_table_name

  # 読み書きキャパシティを自動課金のオンデマンド方式にする
  billing_mode = "PAY_PER_REQUEST"

  # 主キーとして使う属性名を LockID にする
  hash_key     = "LockID"

  # テーブル属性を定義する
  attribute {
    # 主キー属性の名前を LockID にする
    name = "LockID"

    # 主キー属性の型を文字列にする
    type = "S"
  }
  # AWSサービスレベルでの削除保護
  deletion_protection_enabled = true

  # Terraformレベルでの削除保護
  lifecycle {
    prevent_destroy = true
  }
}