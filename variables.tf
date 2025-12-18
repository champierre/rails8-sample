# ============================================================
# Terraform変数定義ファイル
# ============================================================
#
# 注意: このファイルは .gitignore に追加されており、
#       Gitリポジトリには含まれません。
# ============================================================

variable "project_id" {
  description = "GCP Project ID"
  default     = "meishi-418507"
}

variable "region" {
  description = "GCP Region"
  default     = "asia-northeast1"
}

variable "zone" {
  description = "GCP Zone"
  default     = "asia-northeast1-a"
}

variable "app_name" {
  description = "Application name"
  default     = "rails8-sample"
}
