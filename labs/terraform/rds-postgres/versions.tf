terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(
      {
        Project     = "pgdba-30day-program"
        Lab         = "day-15-rds-postgres"
        ManagedBy   = "Terraform"
      },
      var.tags
    )
  }
}
