resource "aws_key_pair" "this" {
  key_name   = var.project_name
  public_key = file("${path.module}/wordpress-docker-terraform.pub")
}

resource "aws_security_group" "this" {
  name = var.project_name
  description = "Security group for ${var.project_name} project"
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }

  tags = {
    Name = var.project_name
  }
}

resource "aws_ebs_volume" "this" {
  # needs to persist
  lifecycle {
    prevent_destroy = true
  }

  availability_zone = var.availability_zone

  # NOTE: When changing the size, iops or type of an instance, there are considerations to be aware of that Amazon have written about this.

  size = var.aws_ebs_volume.size
  type = "gp2"
  # iops = 

  encrypted = false
  # kms_key_id = 

  tags = {
    Name = var.project_name
  }
}

resource "aws_volume_attachment" "this" {
  # refer to https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/device_naming.html#available-ec2-device-names
  device_name = "/dev/sdf"
  volume_id   = "${aws_ebs_volume.this.id}"
  instance_id = "${aws_instance.this.id}"
  skip_destroy = true
}

resource "aws_eip" "this" {
  vpc = true
  tags = {
    Name = var.project_name
  }

  # needs to persist
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_eip_association" "this" {
  instance_id   = "${aws_instance.this.id}"
  allocation_id = "${aws_eip.this.id}"
}

resource "aws_instance" "this" {
  ami = "ami-035b3c7efe6d061d5" # Amazon Linux 2018
  instance_type = "t2.nano"
  availability_zone = var.availability_zone
  key_name = aws_key_pair.this.key_name
  security_groups = [
    aws_security_group.this.name
  ]
  
  tags = {
    Name = var.project_name
  }
}
