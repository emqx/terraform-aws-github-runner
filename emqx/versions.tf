terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.3.0"
  backend "s3" {
    bucket = "emqx-terraform-state"
    key    = "terraform-aws-github-runner"
    region = "eu-west-1"
  }
}
