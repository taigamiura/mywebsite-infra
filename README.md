# infra

Terraform で静的サイト配信用の AWS インフラを管理します。

このリポジトリは次の 2 段構成です。

- bootstrap
    - Terraform の state を保存する S3 バケット
    - Terraform のロック管理に使う DynamoDB テーブル
- envs/prod
    - Route 53 ホストゾーン
    - ACM 証明書
    - CloudFront
    - 静的ファイル配置用 S3 バケット

## ディレクトリ構成

```text
.
├── bootstrap/
│   ├── main.tf
│   ├── outputs.tf
│   └── variables.tf
└── envs/
        └── prod/
                ├── main.tf
                ├── outputs.tf
                └── variables.tf
```

## 前提条件

- Terraform 1.5 以上
- AWS CLI が利用可能であること
- 対象 AWS アカウントへ操作できること
- ローカルに AWS 認証情報が設定済みであること

確認コマンド:

```bash
terraform version
aws sts get-caller-identity
```

## 初回構築の流れ

初回は必ず bootstrap から作成します。prod 環境の state を保存する S3 backend を先に用意する必要があるためです。

1. bootstrap を apply する
2. state バケット名と lock テーブル名を確認する
3. prod 用 backend 設定を作る
4. prod を terraform init する
5. prod を plan / apply する
6. Route 53 の NS レコードをドメイン管理事業者へ登録する

## bootstrap の作成

bootstrap ディレクトリへ移動します。

```bash
cd bootstrap
```

初期化します。

```bash
terraform init
```

実行計画を確認します。

```bash
terraform plan
```

問題なければ適用します。

```bash
terraform apply
```

作成後、次の出力値を確認します。

- terraform_state_bucket_name
- terraform_lock_table_name

```bash
terraform output
```

## prod 用 backend 設定

prod 側は S3 backend を使います。backend の詳細値は外部ファイルから渡します。

まず、envs/prod/backend.hcl.example をコピーして envs/prod/backend.hcl をローカルに作成します。

```bash
cd envs/prod
cp backend.hcl.example backend.hcl
```

backend.hcl の中身を bootstrap の output に合わせて編集してください。

```hcl
bucket         = "mywebsite-terraform-state-123456789012"
key            = "prod/terraform.tfstate"
region         = "ap-northeast-1"
dynamodb_table = "mywebsite-terraform-lock"
encrypt        = true
```

値の意味:

- bucket: bootstrap が作成した state 用 S3 バケット名
- key: prod 環境の state 保存先キー
- region: state バケットのリージョン
- dynamodb_table: bootstrap が作成した lock テーブル名
- encrypt: state 保存時の暗号化

backend.hcl は環境依存の値を含むため Git 管理しません。共有用の雛形として backend.hcl.example のみを管理します。

## prod の初期化と適用

prod ディレクトリへ移動します。

```bash
cd envs/prod
```

backend 設定を指定して初期化します。

```bash
terraform init -backend-config=backend.hcl
```

実行計画を確認します。

```bash
terraform plan
```

問題なければ適用します。

```bash
terraform apply
```

apply 後は次の出力値を確認します。

- name_servers
- s3_bucket_name

```bash
terraform output
```

## ドメイン側の設定

prod の apply 後、name_servers の値をドメイン管理事業者側に登録してください。これを行わないと Route 53 側の DNS が有効になりません。

対象例:

- お名前.com
- ムームードメイン
- その他のレジストラ

## 静的ファイルの配置

HTML / CSS / JavaScript などの静的ファイルは、terraform output で確認した s3_bucket_name に配置します。

```bash
aws s3 sync ./dist s3://<s3_bucket_name> --delete
```

CloudFront 経由で配信されるため、必要に応じてキャッシュ無効化を実施してください。

## 日常運用

差分確認:

```bash
cd envs/prod
terraform plan
```

反映:

```bash
terraform apply
```

state の確認:

```bash
terraform state list
```

出力値の確認:

```bash
terraform output
```

## 既存 local state からの移行

もし prod を以前ローカル state で運用していた場合、backend 設定後の初期化で state 移行が必要です。

```bash
terraform init -backend-config=backend.hcl -migrate-state
```

## destroy の注意点

bootstrap 側の state バケットと lock テーブルには削除防止設定が入っています。そのため bootstrap に対する単純な destroy は失敗します。これは意図した挙動です。

prod 側を削除する場合は、先に envs/prod を対象に実行してください。

```bash
cd envs/prod
terraform destroy
```

## 補足

- ACM 証明書は CloudFront 用のため us-east-1 で作成されます
- Web 配信用 S3 バケットは CloudFront OAC 経由のアクセスを前提としています
- prod の state は bootstrap で作成した S3 / DynamoDB を利用します