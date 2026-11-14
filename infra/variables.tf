variable "project" {
  description = "Prefix used for every resource name."
  type        = string
  default     = "url-shortener"
}

variable "region" {
  description = "AWS region (AWS Emulator serves a single region)."
  type        = string
  default     = "us-east-1"
}

variable "stage_name" {
  description = "API Gateway stage name."
  type        = string
  default     = "v1"
}

variable "emulator_dir" {
  description = <<-EOT
    Directory where AWS Emulator writes its credentials, config and CA
    (e.g. ~/.aws/emulator/9297, as an absolute path). Leave empty when
    deploying to real AWS.
  EOT
  type        = string
  default     = ""
}

variable "emulator_endpoint" {
  description = "AWS Emulator endpoint, only used when emulator_dir is set."
  type        = string
  default     = "https://127.0.0.1:9297"
}
