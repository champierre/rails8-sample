# ============================================================
# Terraform設定 - Rails 8 Sample on Google Cloud Run
# ============================================================
#
# 使い方:
#
# 1. 環境を作成（初回でもOK）
#    terraform apply
#    → すべてのリソースを作成し、Dockerイメージを自動ビルド＆プッシュして、Cloud Runをデプロイします
#
# 2. 環境を削除
#    terraform destroy
#    → すべてのリソースを削除します
#
# 3. 環境を再作成
#    terraform apply
#    → 完全にゼロから環境を再構築します
#
# ============================================================

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# 変数定義は variables.tf に記述してください
# variables.tf.example をコピーして variables.tf を作成してください

# ローカル変数
locals {
  default_compute_sa = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
  docker_image_url   = "${google_artifact_registry_repository.app.location}-docker.pkg.dev/${google_artifact_registry_repository.app.project}/${google_artifact_registry_repository.app.repository_id}/${var.app_name}:latest"
}

# 必要なAPIの有効化
resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifact_registry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secret_manager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudbuild" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

# Artifact Registry - Dockerイメージ保存用
resource "google_artifact_registry_repository" "app" {
  location      = var.region
  repository_id = var.app_name
  description   = "Docker repository for ${var.app_name}"
  format        = "DOCKER"

  depends_on = [google_project_service.artifact_registry]
}

# Dockerイメージのビルド＆プッシュ
resource "null_resource" "docker_build" {
  depends_on = [
    google_artifact_registry_repository.app,
    google_project_service.cloudbuild
  ]

  # Dockerfileが変更されたら再ビルド
  triggers = {
    dockerfile_hash = filemd5("${path.module}/Dockerfile")
    image_tag       = "${google_artifact_registry_repository.app.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}/${var.app_name}:latest"
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud builds submit \
        --tag ${google_artifact_registry_repository.app.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}/${var.app_name}:latest \
        --project ${var.project_id} \
        ${path.module}
    EOT
  }
}

# Cloud Storage バケット - SQLite3データベース用
resource "google_storage_bucket" "database" {
  name          = "${var.app_name}-database"
  location      = upper(var.region)
  force_destroy = true # terraform destroyで削除可能にする

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  depends_on = [google_project_service.storage]
}

# Cloud Storage バケット - Active Storage用
resource "google_storage_bucket" "storage" {
  name          = "${var.app_name}-storage"
  location      = upper(var.region)
  force_destroy = true # terraform destroyで削除可能にする

  uniform_bucket_level_access = true

  cors {
    origin          = ["*"]
    method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
    response_header = ["*"]
    max_age_seconds = 3600
  }

  depends_on = [google_project_service.storage]
}

# Cloud Run サービス
resource "google_cloud_run_v2_service" "app" {
  name                = var.app_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  depends_on = [
    google_project_service.run,
    google_project_service.compute,
    google_secret_manager_secret_version.secret_key_base,
    null_resource.docker_build
  ]

  template {
    containers {
      # Dockerイメージ（自動ビルド＆プッシュ）
      image = local.docker_image_url

      ports {
        container_port = 3000
      }

      # 環境変数
      env {
        name  = "RAILS_ENV"
        value = "production"
      }

      env {
        name  = "RAILS_LOG_TO_STDOUT"
        value = "true"
      }

      env {
        name  = "RAILS_SERVE_STATIC_FILES"
        value = "true"
      }

      # Active Storage設定
      env {
        name  = "ACTIVE_STORAGE_SERVICE"
        value = "google"
      }

      env {
        name  = "GCS_BUCKET"
        value = google_storage_bucket.storage.name
      }

      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }

      # Secret Managerから環境変数を読み込む
      env {
        name = "SECRET_KEY_BASE"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.secret_key_base.secret_id
            version = "latest"
          }
        }
      }

      # Cloud Storageボリュームマウント
      volume_mounts {
        name       = "database"
        mount_path = "/app/db/data"
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      # Startup probe with longer timeout for database initialization
      startup_probe {
        tcp_socket {
          port = 3000
        }
        initial_delay_seconds = 0
        timeout_seconds       = 10
        period_seconds        = 10
        failure_threshold     = 18  # 18 * 10 = 180 seconds total
      }
    }

    # GCSボリューム定義
    volumes {
      name = "database"
      gcs {
        bucket    = google_storage_bucket.database.name
        read_only = false
      }
    }

    scaling {
      min_instance_count = 0
      max_instance_count = 1 # SQLite3を使うため、1インスタンスに制限
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

# Cloud Run サービスを公開アクセス可能にする
resource "google_cloud_run_v2_service_iam_member" "public_access" {
  name     = google_cloud_run_v2_service.app.name
  location = google_cloud_run_v2_service.app.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Cloud Storageへのアクセス権限 - データベースバケット
resource "google_storage_bucket_iam_member" "database_access" {
  bucket = google_storage_bucket.database.name
  role   = "roles/storage.objectAdmin"
  member = local.default_compute_sa
}

# Cloud Storageへのアクセス権限 - Active Storageバケット
resource "google_storage_bucket_iam_member" "storage_access" {
  bucket = google_storage_bucket.storage.name
  role   = "roles/storage.objectAdmin"
  member = local.default_compute_sa
}

# Cloud Storageへの公開読み取りアクセス - Active Storageバケット
resource "google_storage_bucket_iam_member" "storage_public_access" {
  bucket = google_storage_bucket.storage.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# プロジェクト情報取得
data "google_project" "project" {
  project_id = var.project_id
}

# SECRET_KEY_BASEの生成
resource "random_password" "secret_key_base" {
  length  = 128
  special = false

  # 一度生成されたら変更しない
  lifecycle {
    ignore_changes = [length, special]
  }
}

# Secret Manager
resource "google_secret_manager_secret" "secret_key_base" {
  secret_id = "${var.app_name}-secret-key-base"
  replication {
    auto {}
  }

  depends_on = [google_project_service.secret_manager]
}

# Secret Managerにシークレット値を保存
resource "google_secret_manager_secret_version" "secret_key_base" {
  secret      = google_secret_manager_secret.secret_key_base.id
  secret_data = random_password.secret_key_base.result
}

# Secret Managerへのアクセス権限
resource "google_secret_manager_secret_iam_member" "secret_key_base_access" {
  secret_id = google_secret_manager_secret.secret_key_base.id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.default_compute_sa
}

# 出力
output "cloud_run_url" {
  description = "Cloud Run service URL"
  value       = google_cloud_run_v2_service.app.uri
}

output "artifact_registry_url" {
  description = "Artifact Registry repository URL"
  value       = "${google_artifact_registry_repository.app.location}-docker.pkg.dev/${google_artifact_registry_repository.app.project}/${google_artifact_registry_repository.app.repository_id}"
}

output "database_bucket" {
  description = "Cloud Storage bucket for SQLite database"
  value       = google_storage_bucket.database.name
}

output "storage_bucket" {
  description = "Cloud Storage bucket for Active Storage"
  value       = google_storage_bucket.storage.name
}

output "secret_key_base" {
  description = "Generated SECRET_KEY_BASE (sensitive)"
  value       = random_password.secret_key_base.result
  sensitive   = true
}
