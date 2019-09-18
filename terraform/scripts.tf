# download terraform-providers/null plugin
# with reference to https://github.com/hashicorp/terraform/issues/17621#issuecomment-477749470

resource "null_resource" "startup" {
  depends_on = [
    aws_volume_attachment.this,
    aws_eip_association.this,
  ]

  provisioner "file" {
    source = "./terraform/scripts/startup.sh"
    destination = "/tmp/startup.sh"
  }

  connection {
    host = aws_eip.this.public_ip
    type = "ssh"
    user  = "ec2-user"
    password = ""
    private_key = file("${path.module}/wordpress-docker-terraform")
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/startup.sh",
      "/tmp/startup.sh"
    ]
  }
}

resource "null_resource" "create_volume" {
  depends_on = [
    null_resource.startup
  ]

  triggers = {
    build_number = "${timestamp()}"
  }

  provisioner "file" {
    source = "./terraform/scripts/create_volume.sh"
    destination = "/tmp/create_volume.sh"
  }

  connection {
    host = aws_eip.this.public_ip
    type = "ssh"
    user  = "ec2-user"
    password = ""
    private_key = file("${path.module}/wordpress-docker-terraform")
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/create_volume.sh",
      "/tmp/create_volume.sh"
    ]
  }
}

resource "null_resource" "reboot" {
  depends_on = [
    null_resource.create_volume
  ]

  provisioner "file" {
    source = "./terraform/scripts/reboot.sh"
    destination = "/tmp/reboot.sh"
  }

  connection {
    host = aws_eip.this.public_ip
    type = "ssh"
    user  = "ec2-user"
    password = ""
    private_key = file("${path.module}/wordpress-docker-terraform")
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/reboot.sh",
      "/tmp/reboot.sh"
    ]
  }
}

resource "null_resource" "app" {
  depends_on = [
    null_resource.reboot,
  ]

  triggers = {
    build_number = "${timestamp()}"
  }

  # copy folder 'docker-compose'
  provisioner "file" {
    source = "./docker-compose"
    destination = "/wordpress-docker-terraform"
  }

  provisioner "file" {
    source = "./terraform/scripts/app.sh"
    # copied to root as it needs to refer to docker-compose and nginx folders
    destination = "/wordpress-docker-terraform/app.sh"
  }

  connection {
    host = aws_eip.this.public_ip
    type = "ssh"
    user  = "ec2-user"
    password = ""
    private_key = file("${path.module}/wordpress-docker-terraform")
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /wordpress-docker-terraform/app.sh",
      "/wordpress-docker-terraform/app.sh"
    ]
  }
}
