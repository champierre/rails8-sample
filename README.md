# Rails 8 Sample on Google Cloud Run

Rails 8アプリケーションをGoogle Cloud Runにデプロイするサンプルプロジェクトです。

## 技術スタック

- Ruby 3.3.6
- Rails 8.0
- SQLite3（Cloud Storageマウント）
- Active Storage（Google Cloud Storage）
- Google Cloud Run
- Terraform（インフラ管理）

## Terraformによる環境構築

### 前提条件

- Google Cloud SDKがインストールされていること
- `gcloud auth login`でGCPにログインしていること
- Terraformがインストールされていること

### セットアップ手順

#### 1. variables.tfファイルの作成

```bash
cp variables.tf.example variables.tf
```

`variables.tf`を編集して、`project_id`をご自身のGCPプロジェクトIDに変更してください：

```hcl
variable "project_id" {
  description = "GCP Project ID"
  default     = "your-gcp-project-id"  # ← ここを変更
}
```

**重要:** `variables.tf`は`.gitignore`に追加されており、Gitリポジトリには含まれません。

#### 2. Terraformの初期化

```bash
terraform init
```

#### 3. 環境の作成

```bash
terraform apply
```

このコマンド一発で以下がすべて自動実行されます：

1. 必要なGCP APIの有効化
2. Artifact Registryリポジトリの作成
3. Cloud Storageバケットの作成
4. Secret Managerの設定
5. **Dockerイメージの自動ビルド＆プッシュ**（Cloud Build使用）
6. Cloud Runサービスのデプロイ

#### 4. 環境の削除

```bash
terraform destroy
```

#### 5. 環境の再作成

```bash
terraform destroy
terraform apply
```

完全にゼロから環境を再構築できます。

## ローカル開発

### 依存関係のインストール

```bash
bundle install
```

### データベースのセットアップ

```bash
rails db:create
rails db:migrate
```

### サーバーの起動

```bash
rails server
```

http://localhost:3000 でアクセスできます。

## デプロイ済み環境へのアクセス

デプロイ後、以下のコマンドでCloud RunのURLを確認できます：

```bash
terraform output cloud_run_url
```
