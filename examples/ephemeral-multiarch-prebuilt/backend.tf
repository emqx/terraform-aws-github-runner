terraform {
  backend "s3" {
    bucket         = "emqx-terraform-state"
    key            = "github-runners/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}
