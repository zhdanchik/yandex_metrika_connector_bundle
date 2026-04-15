terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.120"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}
