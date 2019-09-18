#!/usr/bin/env bash

chmod 400 terraform/wordpress-docker-terraform
chmod 400 terraform/wordpress-docker-terraform.pub

echo Enter your AWS named profile:
read aws_profile
AWS_ACCESS_KEY_ID=$(aws --profile $aws_profile configure get aws_access_key_id)
if [ "$?" -ne 0 ]; then exit 1; fi
AWS_SECRET_ACCESS_KEY=$(aws --profile $aws_profile configure get aws_secret_access_key)
if [ "$?" -ne 0 ]; then exit 1; fi
echo AWS_ACCESS_KEY_ID is $AWS_ACCESS_KEY_ID
echo AWS_SECRET_ACCESS_KEY is $AWS_SECRET_ACCESS_KEY

echo ""

echo "Enter your site's fully qualified domain name (eg. www1.example.com, domain.com):"
domain_name="initial value"
while ! [[ $domain_name == $(echo $domain_name | grep -P '(?=^.{1,254}$)(^(?>(?!\d+\.)[a-zA-Z0-9_\-]{1,63}\.?)+(?:[a-zA-Z]{2,})$)') ]] || [[ $domain_name == "" ]]
do
  if [[ $domain_name != "initial value" ]]
  then
    echo Invalid FQDN. Please try again.
  fi
  domain_name=""
  read domain_name
done
dns_valid_domain_name="${domain_name//\./-}"

echo ""

echo "Enter your main AWS Route53 hosted zone's id:"
read main_zone_id

if [[ -f "docker-compose/production/${domain_name}.yml" ]] || [[ -f "docker-compose/development/${domain_name}.yml" ]] || [[ -f "terraform/cloudfront/${dns_valid_domain_name}.tf" ]]
then
  cat <<EOF
Domain name ${domain_name} has been processed before.
Duplicated domains will be blocked to prevent overriding of generated files. Some of the generated files contain passwords, so if they are overridden after being provisioned once, they are gone forever.
Exiting...
EOF
  exit 1
fi

######################################
######## START files creation ########
######################################

MYSQL_PASSWORD=`openssl rand -base64 10`
MYSQL_ROOT_PASSWORD=`openssl rand -base64 10`

domain_names=()

dev_file_list=""
prod_file_list=""

# remove `docker-compose/development/*.yml` from appearing as a file in loop
shopt -s nullglob
for file_path in docker-compose/development/*.yml
do
  dev_file_list+="-f ${file_path} "
  prod_file_list+="-c ${file_path/development/production} "

  # TODO use regex
  _DOMAINNAME=${file_path/\.yml/}
  _DOMAINNAME=${_DOMAINNAME/docker-compose\/development\//}

  domain_names[${#domain_names[@]}]=$_DOMAINNAME
done

the_port=$((1024 + ${#domain_names[@]}))
cf_domain_name="cf-${domain_name}"

environments=("development" "production")

# mount point taken relative to where the script is run
# root diirectory during development by start.sh
# root diirectory during production by app.sh
for environment in "${environments[@]}"
do
  absolute_path=""
  if [[ $environment == "development" ]]
  then
    absolute_path="$(pwd)"
  elif [[ $environment == "production" ]]
  then
    absolute_path="/wordpress-docker-terraform"
  fi
  cat > "docker-compose/${environment}/${domain_name}.yml" <<EOF
version: '3.7'

services:
  db-${dns_valid_domain_name}:
    image: mysql:5.7
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: "${domain_name}-db"
      MYSQL_USER: "${domain_name}-dbuser"
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ${absolute_path}/volumes/db-${dns_valid_domain_name}:/var/lib/mysql

  wp-${dns_valid_domain_name}:
    image: wordpress:5
    restart: always
    ports:
      - ${the_port}:80
    volumes:
      - ${absolute_path}/volumes/wp-${dns_valid_domain_name}:/var/www/html
    depends_on:
      - db-${dns_valid_domain_name}
    environment:
      WORDPRESS_DB_HOST: db-${dns_valid_domain_name}:3306
      WORDPRESS_DB_USER: "${domain_name}-dbuser"
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: "${domain_name}-db"
$(
if [[ $environment == "production" ]]
then
  cat <<EXTRA_WP_CONFIG
      WORDPRESS_CONFIG_EXTRA: |
        # define('WP_SITEURL', 'https://${domain_name}');
        # define('WP_HOME', 'https://${domain_name}');
        # define('FORCE_SSL_ADMIN', true );
        # define('COOKIE_DOMAIN', '${domain_name}');
        # \$\$_SERVER['SERVER_NAME'] = preg_replace(['/cloudfront\./'], [''], '${domain_name}');
        # \$\$_SERVER['HTTP_HOST'] = preg_replace(['/cloudfront\./'], [''], '${domain_name}');
        \$\$_SERVER['HTTPS'] = 'on';
EXTRA_WP_CONFIG
fi
)
EOF
done

cat > "terraform/cloudfront/${dns_valid_domain_name}.tf" <<EOF
data "aws_route53_zone" "${dns_valid_domain_name}" {
  zone_id = "${main_zone_id}"
}

resource "aws_acm_certificate" "${dns_valid_domain_name}" {
  domain_name = "${domain_name}"
  validation_method = "DNS"

  tags = {
    Name = var.project_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "${dns_valid_domain_name}" {
  depends_on = [
    aws_eip.this,
  ]

  name = "${domain_name}"
  type = "A"
  zone_id = data.aws_route53_zone.${dns_valid_domain_name}.id

  alias {
    name = aws_cloudfront_distribution.${dns_valid_domain_name}.domain_name
    zone_id = aws_cloudfront_distribution.${dns_valid_domain_name}.hosted_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "cf-${dns_valid_domain_name}" {
  name = "${cf_domain_name}"
  type = "A"
  zone_id = data.aws_route53_zone.${dns_valid_domain_name}.id
  ttl = 300
  records = [
    aws_eip.this.public_ip
  ]
}

resource "aws_route53_record" "validation-${dns_valid_domain_name}" {
  name = aws_acm_certificate.${dns_valid_domain_name}.domain_validation_options.0.resource_record_name
  type = aws_acm_certificate.${dns_valid_domain_name}.domain_validation_options.0.resource_record_type
  zone_id = data.aws_route53_zone.${dns_valid_domain_name}.id
  records = [ aws_acm_certificate.${dns_valid_domain_name}.domain_validation_options.0.resource_record_value ]
  ttl = 604800
}

resource "aws_acm_certificate_validation" "${dns_valid_domain_name}" {
  certificate_arn = aws_acm_certificate.${dns_valid_domain_name}.arn
  validation_record_fqdns = [
    aws_route53_record.validation-${dns_valid_domain_name}.fqdn
  ]
}

resource "aws_cloudfront_distribution" "${dns_valid_domain_name}" {
  price_class = "PriceClass_100"

  depends_on = [
    aws_acm_certificate_validation.${dns_valid_domain_name},
  ]

  enabled = true

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = var.project_name
  }

  aliases = ["${domain_name}"]

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.${dns_valid_domain_name}.arn
    ssl_support_method = "sni-only"
  }

  origin {
    domain_name = "${cf_domain_name}"
    origin_id = "cf-${dns_valid_domain_name}"

    custom_origin_config {
      http_port = ${the_port}
      https_port = 443 # invalid; cloudfront will only talk to custom origin http
      origin_protocol_policy = "http-only"
      origin_ssl_protocols = [
        "TLSv1",
        "TLSv1.1",
        "TLSv1.2",
      ] # required although not necessary since we not using https protocol
    }
  }

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "cf-${dns_valid_domain_name}"

    forwarded_values {
      query_string = true

      headers = [
        "Host",
        "Origin"
      ]

      cookies {
        forward = "whitelist"
        whitelisted_names = [
          "PHPSESSID",
          "comment_author_*",
          "comment_author_email_*",
          "comment_author_url_*",
          "wordpress_*",
          "wordpress_logged_in_*",
          "wordpress_test_cookie",
          "wp-settings-*"
        ]
      }
    }

    min_ttl = 0
    default_ttl = 300
    max_ttl = 31536000
    compress = true
    viewer_protocol_policy = "redirect-to-https"
  }

  ordered_cache_behavior {
    path_pattern = "wp-login.php"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "cf-${dns_valid_domain_name}"

    forwarded_values {
      query_string = true

      headers = [ "*" ]

      cookies {
        forward = "all"
      }
    }

    # use origin cache headers
    compress = true
    viewer_protocol_policy = "redirect-to-https"
  }

  ordered_cache_behavior {
    path_pattern = "wp-admin/*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = "cf-${dns_valid_domain_name}"

    forwarded_values {
      query_string = true

      headers = [ "*" ]

      cookies {
        forward = "all"
      }
    }

    # use origin cache headers
    compress = true
    viewer_protocol_policy = "redirect-to-https"
  }
}
EOF

# overide start.sh and stop.sh with updated list of docker-compose file for all the sites
new_compose_file_name="${domain_name}.yml"
dev_file_list+="-f docker-compose/development/${new_compose_file_name} "
prod_file_list+="-c docker-compose/production/${new_compose_file_name} "

cat > "start.sh" <<EOF
#!/usr/bin/env bash

docker-compose ${dev_file_list} up -d
EOF
chmod +x start.sh
cat > "stop.sh" <<EOF
#!/usr/bin/env bash

docker-compose ${dev_file_list} down
EOF
chmod +x stop.sh

##### DEPLOY #####

if ! [ -f terraform.tfstate ]
then
  touch terraform.tfstate
  echo terraform.tfstate file created.
fi

cat > terraform/scripts/create_volume.sh <<EOF
#!/usr/bin/env bash

echo "Creating volumes required for app"
# Loop because permissions propagation have delay
# conditional check for more than 1 directory instead of 0
# because "lost+found" folder is created automatically

until [[ \$(ls -lA  /wordpress-docker-terraform/ | egrep -c '^d') > 1 ]]
do
  echo "Permission of folder for mounted volume not propagated. Retrying mkdir using 'ec2-user'..."
  mkdir -p /wordpress-docker-terraform/docker-compose/production
  mkdir -p /wordpress-docker-terraform/volumes/
  mkdir -p /wordpress-docker-terraform/volumes/db-${domain_name//\./-}
  mkdir -p /wordpress-docker-terraform/volumes/wp-${domain_name//\./-}
  mkdir -p /wordpress-docker-terraform/volumes/logs-${domain_name//\./-}
$(
for domain in ${domain_names[@]}
do
  cat <<MKDIRS
  mkdir -p /wordpress-docker-terraform/volumes/db-${domain//\./-}
  mkdir -p /wordpress-docker-terraform/volumes/wp-${domain//\./-}
  mkdir -p /wordpress-docker-terraform/volumes/logs-${domain//\./-}
MKDIRS
done
)
done

echo Successfully created folders!
EOF

cat > deploy.sh <<EOF
#!/usr/bin/env bash

AWS_DEFAULT_REGION="us-east-1"

docker build -t wordpress-docker-terraform:latest .

docker run \\
  --rm \\
  -it \\
  -v $(pwd)/terraform.tfstate:/workspace/terraform.tfstate \\
  --env AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \\
  --env AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \\
  wordpress-docker-terraform \\
  apply
EOF
chmod +x deploy.sh

cat > destroy.sh <<EOF
#!/usr/bin/env bash

AWS_DEFAULT_REGION="us-east-1"

echo NOTE: This operation will NOT destroy the "aws_ebs_volume"

docker run \\
  --rm \\
  -it \\
  -v $(PWD)/terraform.tfstate:/workspace/terraform.tfstate \\
  --env AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \\
  --env AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \\
  wordpress-docker-terraform \\
  destroy
  # destroy \\
  # -target aws_key_pair.this \\
  # -target aws_security_group.this \\
  # -target aws_volume_attachment.this \\
  # -target aws_eip_association.this \\
  # -target aws_instance.this
EOF
chmod +x destroy.sh

cat > terraform/scripts/app.sh <<EOF
#!/usr/bin/env bash

cd /wordpress-docker-terraform
# TODO run these commands only when necessary
docker swarm init

docker stack rm wordpress-docker-terraform
# wait for stack to remove https://github.com/moby/moby/issues/30942#issuecomment-444611989
limit=15
until [ -z "\$(docker service ls --filter label=com.docker.stack.namespace=wordpress-docker-terraform -q)" ] || [ "\$limit" -lt 0 ]; do
  sleep 2
  limit="$((limit-1))"
done

limit=15;
until [ -z "\$(docker network ls --filter label=com.docker.stack.namespace=wordpress-docker-terraform -q)" ] || [ "\$limit" -lt 0 ]; do
  sleep 2;
  limit="$((limit-1))";
done

sleep 10

docker stack deploy ${prod_file_list} wordpress-docker-terraform
EOF

##### DONE #####

cat << EOF
########################################
Your mysql root password for ${domain_name} is ${MYSQL_ROOT_PASSWORD}.
Your mysql user password for ${domain_name} is ${MYSQL_PASSWORD}.
These passwords are stored in the generated docker-compose/${domain_name}.yml file.

This hash is required to be added automatically to the custom header that your cloudfront distribution will forward to the origin server. The key for the header should be "cloudfront-hash".
Lower casing for the key name is used as Amazon Cloudfront will convert the key to lower case anyway following RFC 2616 Section 4.2 (https://tools.ietf.org/html/rfc2616#section-4.2) that headers are to be case-insensitive.

Please store them securely elsewhere as a backup.
########################################
EOF