# download all necessary plugins for terraform
# set versions
terraform {
  required_version = "~> 0.12.0"
}

provider "aws" {
  version = "~> 2.24"
  region = "us-east-1"
}

provider "null" {
  version = "~> 2.1"
}
