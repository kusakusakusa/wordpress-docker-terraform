variable "project_name" {
  type = string
  default = "wordpress-docker-terraform"
}

variable "availability_zone" {
  type = string
  default = "us-east-1a"
}

variable "aws_ebs_volume" {
  type = map
  default = {
    size = 16
  }
}
