# Wordpress Docker Terraform

This project will create a wordpress instance running on top of `docker stack`.

During deployment, terraform will provision the necessary resources on AWS and run the application using docker stack. The configurations are setup in a way that makes it portable and the data  persisted.

## Motivation

Fast setup of wordpress at the lowest cost possible without compromising control of the whole application and setup.

## Preparation

1. Setup AWS named profile.
2. Install docker and docker-compose
3. Get a domain on AWS Route 53.
4. Generate a ssh private key and save it as "ssh_key(.pub). It is for the key pair generation on AWS EC2.

## Architecture

### Application

The docker images used are `nginx`, `wordpress:5-fpm` and `mysql:5.7`. `FastCGI` will be used, hence the need for nginx.

The `docker-compose.base.yml` file will serve as the base `docker-compose` file and will contain only the nginx service with minimal configuration. Each wordpress site will share the nginx service and have their own separated `wordpress` and `mysql` services.

Volumes are binded to subdirectories in the `volumes` folder. The folder is pre-created.

### In the Cloud

An AWS EC2 instance of `t2.nano` will be provisioned upon deployed. The EC2 instance will be associated with an Elastic IP.
A Cloudfront distribution will provisioned and have the eip as the origin.
In order to [use the ACM with Cloudfront to serve the site with HTTPS](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html#https-requirements-aws-region), the default region `us-east-1`, also known as `N. Virginia`, is selected.

The intention is to allow requests to enter the sites via the Cloudfront distribution and, base on the `server_name` in the `nginx` directive, be directed to the correct servers to serve the correct site. This will require the corresponding domain names to be routed to the cloudfront distribution's domain using a CNAME record in the DNS zone file.

The part on provisioning this DNS file on a hosted zone in AWS Route53 will not be provisioned and will reqiure manual intervention. This is because there may be other configurations involved with the DNS zone file that is not within the scope of this project, like Google Search Console verification for instance.

## Usage

Create your ssh key using the command below. The ssh key will be use to generate the key pair for your EC2 instance. Keep the generated keys, especially the private key, securely. Do NOT change any part in the command below except `<COMMENT>`.
```
ssh-keygen -t rsa -f terraform/wordpress-docker-terraform -C <COMMENT>
```

Run `./setup.sh`. Follow the instructions to generate the files required for development and production.

The setup will require these inputs:
* Your AWS named profile (make sure it has the required permission to do the deployment - TODO compile minimum list necessary permissions)
* Fully qualified domain name that you will like to host the site on

To create more sites, keep running `./setup.sh`.

Duplicated domains will be blocked to prevent overriding of generated files. Some of the generated files contain passwords, so if they are overriden after being provisioned once, they are gone forever.

Each run will generate these files:
* `terraform.tfstate` is the state file that terraform will refer to on the provisioning information for this project.
* `start.sh` for running development instance locally using `docker-compose`. This will start all your wordpress sites.
* `stop.sh` for running instance locally using `docker-compose`. This will stop all your wordpress sites.
* `deploy.sh` for deploying to AWS using `terraform`.
* `destroy.sh` for destroying your resources using `terraform`. Note that only `aws_eip` and `aws_ebs_volume` are not going to be destroyed due to need for persistence. These resources cost money so do take note to remove them manually if intended.
* `docker-compose.DOMAIN_NAME.yml` for each site that will contain the wordpress and database services to be deployed in docker stack in the AWS instance.
* `nginx.DOMAIN_NAME.conf` for each site that will the location directive for each site listening on port 80 for the domain name as the `server_name`.

These files will be uploaded to your instance via terraform when you deploy them by running './deploy.sh'. The `Dockerfile` will copy the relevant `docker-compose` and `nginx` files to the instances.

These files are ignored by git by default as they can be generated. Do keep them safely as they contain passwords that the application(s) need to function.

### Development

Run the command:
```
./dev.sh
```

### Deployment

To provision, run the command
```
./deploy.sh
```

To destroy the resources, run the command
```
./destroy.sh
```
Note that the `aws_eip` and `aws_ebs_volume` resources will not be destroyed. These resources cost money so do take note to remove them manually if intended.

## Considerations

TODO