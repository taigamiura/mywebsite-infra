# Terraform Apply Failure Checklist

GitHub Actions で `terraform apply` が途中失敗したときに毎回確認する手順です。

Terraform は CloudFormation のような自動ロールバックをしないため、失敗時に AWS 実体と Terraform state がずれることがあります。

## 対象

このリポジトリの bootstrap 構成では、主な確認対象は次です。

- S3 state バケット
- S3 versioning 設定
- S3 デフォルト暗号化設定
- S3 Public Access Block 設定
- DynamoDB lock テーブル

対応する Terraform 定義:

- [bootstrap/main.tf](bootstrap/main.tf#L46)
- [bootstrap/main.tf](bootstrap/main.tf#L52)
- [bootstrap/main.tf](bootstrap/main.tf#L64)
- [bootstrap/main.tf](bootstrap/main.tf#L79)
- [bootstrap/main.tf](bootstrap/main.tf#L94)

## 1. 失敗ログを保存する

最初に GitHub Actions のジョブログを保存し、どこで止まったかを確認します。

確認ポイント:

- どの resource で止まったか
- `AccessDenied` か
- `already exists` か
- `has been deleted` か
- `tainted` か
- `prevent_destroy` か
- 手動キャンセルやタイムアウトか

## 2. Terraform state の状態を確認する

失敗直後に state と plan を確認します。

```bash
terraform state list
terraform plan
```

確認ポイント:

- resource が state に載っているか
- `Objects have changed outside of Terraform` が出ていないか
- `tainted, so must be replaced` が出ていないか
- `-/+` の replacement が出ていないか

## 3. AWS 実体が残っているか確認する

`apply` 途中失敗時は、成功済み resource が残ることがあります。

### S3

対象バケット:

- `mywebsite-terraform-state-<account_id>`

確認内容:

- バケットが存在するか
- versioning が有効か
- デフォルト暗号化が有効か
- Public Access Block が有効か
- タグが付いているか

CLI 例:

```bash
aws s3api head-bucket --bucket mywebsite-terraform-state-<account_id>
aws s3api get-bucket-versioning --bucket mywebsite-terraform-state-<account_id>
aws s3api get-bucket-encryption --bucket mywebsite-terraform-state-<account_id>
aws s3api get-public-access-block --bucket mywebsite-terraform-state-<account_id>
aws s3api get-bucket-tagging --bucket mywebsite-terraform-state-<account_id>
```

### DynamoDB

対象テーブル:

- `mywebsite-terraform-lock`

確認内容:

- テーブルが存在するか
- hash key が期待通りか
- タグが付いているか
- TTL 状態を読めるか
- Continuous Backups 状態を読めるか
- 削除保護が有効か

CLI 例:

```bash
aws dynamodb describe-table --table-name mywebsite-terraform-lock
aws dynamodb describe-time-to-live --table-name mywebsite-terraform-lock
aws dynamodb describe-continuous-backups --table-name mywebsite-terraform-lock
aws dynamodb list-tags-of-resource --resource-arn arn:aws:dynamodb:ap-northeast-1:<account_id>:table/mywebsite-terraform-lock
```

## 4. エラーの種類を判定する

### パターンA: AccessDenied

意味:

- IAM policy が不足している

対応:

- 失敗した API 名をそのまま追加候補にする
- `Create*` だけでなく `Describe*` と `Get*` も確認する
- `default_tags` を使っている場合は tag 系 action も確認する

よくある不足例:

- `dynamodb:DescribeTimeToLive`
- `dynamodb:DescribeContinuousBackups`
- `s3:GetBucketTagging`
- `s3:ListTagsForResource`

### パターンB: has been deleted

意味:

- state にはあるが AWS 実体が消えている

対応:

- AWS 側で本当に消えているか確認する
- 再作成が妥当か判断する
- bootstrap 基盤なら削除原因を先に特定する

### パターンC: already exists

意味:

- AWS 実体はあるが state に無い可能性が高い

対応:

- import を検討する

例:

```bash
terraform import aws_s3_bucket.terraform_state mywebsite-terraform-state-<account_id>
terraform import aws_dynamodb_table.terraform_lock mywebsite-terraform-lock
```

### パターンD: tainted

意味:

- 前回の失敗や中断により Terraform が再作成対象とみなしている

対応:

- AWS 実体が正常か先に確認する
- 再作成が本当に必要か判断する
- bootstrap 基盤は安易に destroy しない

### パターンE: prevent_destroy

意味:

- Terraform は destroy したいが、設定で削除禁止になっている

このリポジトリの該当箇所:

- [bootstrap/main.tf](bootstrap/main.tf#L49)
- [bootstrap/main.tf](bootstrap/main.tf#L116)

対応:

- すぐに `prevent_destroy` を外さない
- なぜ destroy 計画になったのかを先に確認する
- taint、drift、import 漏れのどれかを切り分ける

## 5. GitHub Actions 側を確認する

確認内容:

- タイムアウトで止まっていないか
- 手動キャンセルされていないか
- 同じ backend に対する並列実行がないか
- `terraform init` の backend 設定が正しいか
- apply 対象の commit と plan 対象の commit が一致しているか

## 6. 再実行前の確認

再実行前に最低限これを確認します。

- IAM policy が更新済み
- AWS 実体の有無を確認済み
- import が必要なら実施済み
- `terraform plan` の差分理由を説明できる
- bootstrap 基盤に対する destroy が出る場合は理由を理解している

## 7. 再実行の基本順序

安全な順序:

1. `terraform plan` で差分理由を確認する
2. AWS 実体の有無を確認する
3. 必要なら import する
4. 不足 IAM policy を追加する
5. もう一度 `terraform plan` を実行する
6. 想定通りなら `terraform apply` を実行する

## 8. このリポジトリで特に注意する点

- bootstrap は state 管理基盤なので通常のアプリ用リソースより壊してはいけない
- [bootstrap/main.tf](bootstrap/main.tf#L23) の `default_tags` により tag 系 API が必要になる
- [bootstrap/main.tf](bootstrap/main.tf#L112) の `deletion_protection_enabled = true` により DynamoDB は AWS 側でも削除保護される
- [bootstrap/main.tf](bootstrap/main.tf#L116) の `prevent_destroy = true` により Terraform 側でも削除保護される

## 9. 最短確認コマンド

```bash
terraform state list
terraform plan
aws s3api head-bucket --bucket mywebsite-terraform-state-<account_id>
aws dynamodb describe-table --table-name mywebsite-terraform-lock
```

## 10. 迷ったときの優先確認順

1. GitHub Actions の失敗ログ
2. `terraform plan`
3. AWS 実体
4. Terraform state
5. IAM policy