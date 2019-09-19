FROM hashicorp/terraform:light
WORKDIR /workspace

COPY ./terraform/setup.tf .
RUN terraform init

# copy scripts for terraform to run
COPY ./terraform/variables.tf .
COPY ./terraform/scripts.tf .
COPY ./terraform/main.tf .

# copy scripts for instance to run
COPY ./terraform/scripts ./terraform/scripts
COPY ./docker-compose ./docker-compose
COPY ./terraform/wordpress-docker-terraform .
COPY ./terraform/wordpress-docker-terraform.pub .
COPY ./terraform/cloudfront .
COPY ./terraform/uploads.ini ./uploads.ini
