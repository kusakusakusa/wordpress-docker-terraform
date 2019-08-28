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
wp_admin_url="wp$((10 + RANDOM % 100)).${domain_name}"

if [[ -f "docker-compose/production/${domain_name}.yml" ]] || [[ -f "docker-compose/development/${domain_name}.yml" ]] || [[ -f "nginx/development/${domain_name}.conf" ]] || [[ -f "nginx/production/${domain_name}.conf" ]] || [[ -f "terraform/cloudfront/${dns_valid_domain_name}.tf" ]]
then
  cat <<EOF
Domain name ${domain_name} has been processed before.
Duplicated domains will be blocked to prevent overriding of generated files. Some of the generated files contain passwords, so if they are overridden after being provisioned once, they are gone forever.
Exiting...
EOF
  exit 1
fi

MYSQL_PASSWORD=`openssl rand -base64 10`
MYSQL_ROOT_PASSWORD=`openssl rand -base64 10`
CLOUDFRONT_HASH=`openssl rand -base64 10`

### START - Files that will be generated only once ###

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
    image: wordpress:5-fpm
    restart: always
    volumes:
      - ${absolute_path}/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini
      - ${absolute_path}/volumes/wp-${dns_valid_domain_name}:/var/www/html/wp-${dns_valid_domain_name}
    depends_on:
      - db-${dns_valid_domain_name}
    environment:
      WORDPRESS_DB_HOST: db-${dns_valid_domain_name}:3306
      WORDPRESS_DB_USER: "${domain_name}-dbuser"
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: "${domain_name}-db"
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_SITEURL', 'https://${domain_name}');
        define('WP_HOME', 'https://${domain_name}');
        define('FORCE_SSL_ADMIN', true );
        define('COOKIE_DOMAIN', '${domain_name}');
$(
if [[ $environment == "production" ]]
then
echo "        \$\$_SERVER['SERVER_NAME'] = preg_replace(['/cloudfront\./'], [''], '${domain_name}');"
echo "        \$\$_SERVER['HTTP_HOST'] = preg_replace(['/cloudfront\./'], [''], '${domain_name}');"
echo "        \$\$_SERVER['HTTPS'] = 'on';"
fi
)
    working_dir: /var/www/html/wp-${dns_valid_domain_name}
EOF

  cat > "nginx/${environment}/${domain_name}.conf" <<EOF
server {
$(
if [[ $environment == "development" ]]
then
nginx_dev_files=(nginx/development/*.conf)
echo "  listen $((8000 + ${#nginx_dev_files[@]}));"
elif [[ $environment == "production" ]]
then
echo "  listen 80;"
echo "  server_name cloudfront.${domain_name} cloudfront.${wp_admin_url};"
fi
)

  root /var/www/html/wp-${dns_valid_domain_name};
  index index.php;

  access_log /var/log/nginx/wp-${dns_valid_domain_name}/access.log;
  error_log /var/log/nginx/wp-${dns_valid_domain_name}/error.log;

  client_max_body_size 64M;

$(
if [[ $environment == "production" ]]
then
echo "  if (\$http_cloudfront_hash != '${CLOUDFRONT_HASH}') {"
echo "    return 301 https://${domain_name}\$request_uri;"
echo "  }"
fi
)
  location / {
      try_files \$uri \$uri/ /index.php?\$args;
  }

  location ~ \.php\$ {
    try_files \$uri =404;
    fastcgi_split_path_info ^(.+\.php)(/.+)\$;
    fastcgi_pass wp-${dns_valid_domain_name}:9000;
    fastcgi_index index.php;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param PATH_INFO \$fastcgi_path_info;
  }
}
EOF
done

cat > "terraform/cloudfront/${dns_valid_domain_name}.tf" <<EOF
data "aws_route53_zone" "main-zone-${dns_valid_domain_name}" {
  zone_id = "${main_zone_id}"
}

resource "aws_route53_record" "main-zone-record-${dns_valid_domain_name}" {
  zone_id = "${main_zone_id}"
  name = "${domain_name}"
  type = "NS"
  ttl = 604800
  records = [
    aws_route53_zone.${dns_valid_domain_name}.name_servers.0,
    aws_route53_zone.${dns_valid_domain_name}.name_servers.1,
    aws_route53_zone.${dns_valid_domain_name}.name_servers.2,
    aws_route53_zone.${dns_valid_domain_name}.name_servers.3,
  ]
}

resource "aws_route53_zone" "${dns_valid_domain_name}" {
  name = "${domain_name}"
  
  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "aws_acm_certificate" "${dns_valid_domain_name}" {
  domain_name = "${domain_name}"
  validation_method = "DNS"

  subject_alternative_names = [
    "${wp_admin_url}"
  ]

  tags = {
    Name = var.project_name
  }

  lifecycle {
    create_before_destroy = true
    # prevent_destroy = true
  }
}

##### START - cloudfront and route53 #####

resource "aws_route53_record" "cloudfront-admin-${dns_valid_domain_name}" {
  depends_on = [
    aws_eip.this,
  ]

  name = "${wp_admin_url}"
  type = "A"
  zone_id = aws_route53_zone.${dns_valid_domain_name}.id

  alias {
    name = aws_cloudfront_distribution.admin-${dns_valid_domain_name}.domain_name
    zone_id = aws_cloudfront_distribution.admin-${dns_valid_domain_name}.hosted_zone_id
    evaluate_target_health = true
  }

  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "aws_route53_record" "cloudfront-admin-origin-${dns_valid_domain_name}" {
  depends_on = [
    aws_eip.this,
  ]

  name = "cloudfront.${wp_admin_url}"
  type = "A"
  zone_id = aws_route53_zone.${dns_valid_domain_name}.id
  records = [ aws_eip.this.public_ip ]
  ttl = 604800

  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "aws_route53_record" "cloudfront-${dns_valid_domain_name}" {
  depends_on = [
    aws_eip.this,
  ]

  name = "${domain_name}"
  type = "A"
  zone_id = aws_route53_zone.${dns_valid_domain_name}.id

  alias {
    name = aws_cloudfront_distribution.site-${dns_valid_domain_name}.domain_name
    zone_id = aws_cloudfront_distribution.site-${dns_valid_domain_name}.hosted_zone_id
    evaluate_target_health = true
  }

  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "aws_route53_record" "cloudfront-origin-${dns_valid_domain_name}" {
  depends_on = [
    aws_eip.this,
  ]

  name = "cloudfront.${domain_name}"
  type = "A"
  zone_id = aws_route53_zone.${dns_valid_domain_name}.id
  records = [ aws_eip.this.public_ip ]
  ttl = 604800

  # lifecycle {
  #   prevent_destroy = true
  # }
}

##### END - cloudfront and route53 #####

##### START - certificate validations #####
resource "aws_route53_record" "validation-${dns_valid_domain_name}" {
  name = aws_acm_certificate.${dns_valid_domain_name}.domain_validation_options.0.resource_record_name
  type = aws_acm_certificate.${dns_valid_domain_name}.domain_validation_options.0.resource_record_type
  zone_id = aws_route53_zone.${dns_valid_domain_name}.id
  records = [ aws_acm_certificate.${dns_valid_domain_name}.domain_validation_options.0.resource_record_value ]
  ttl = 604800

  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "aws_route53_record" "validation-admin-${dns_valid_domain_name}" {
  name = aws_acm_certificate.${dns_valid_domain_name}.domain_validation_options.1.resource_record_name
  type = aws_acm_certificate.${dns_valid_domain_name}.domain_validation_options.1.resource_record_type
  zone_id = aws_route53_zone.${dns_valid_domain_name}.id
  records = [ aws_acm_certificate.${dns_valid_domain_name}.domain_validation_options.1.resource_record_value ]
  ttl = 604800

  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "aws_acm_certificate_validation" "${dns_valid_domain_name}" {
  certificate_arn = aws_acm_certificate.${dns_valid_domain_name}.arn
  validation_record_fqdns = [
    aws_route53_record.validation-${dns_valid_domain_name}.fqdn,
    aws_route53_record.validation-admin-${dns_valid_domain_name}.fqdn
  ]

  # lifecycle {
  #   prevent_destroy = true
  # }
}

##### END - certificate validations #####

resource "aws_cloudfront_distribution" "site-${dns_valid_domain_name}" {
  price_class = "PriceClass_100"

  depends_on = [
    aws_acm_certificate_validation.${dns_valid_domain_name},
  ]

  enabled = true
  comment = "site"

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
    domain_name = "cloudfront.${domain_name}"
    origin_id = "cloudfront-${dns_valid_domain_name}"

    custom_origin_config {
      http_port = 80
      https_port = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols = [
        "TLSv1",
        "TLSv1.1",
        "TLSv1.2",
      ] # required although not necessary since we not using https protocol
    }

    custom_header {
      name = "cloudfront-hash"
      value = "${CLOUDFRONT_HASH}"
    }
  }

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "cloudfront-${dns_valid_domain_name}"

    forwarded_values {
      query_string = true

      cookies {
        forward = "all"
      }
    }

    min_ttl = 604800
    default_ttl = 604800
    max_ttl = 604800
    compress = true
    viewer_protocol_policy = "redirect-to-https"
  }

  # lifecycle {
  #   prevent_destroy = true
  # }
}

resource "aws_cloudfront_distribution" "admin-${dns_valid_domain_name}" {
  price_class = "PriceClass_100"

  depends_on = [
    aws_acm_certificate_validation.${dns_valid_domain_name},
  ]

  enabled = true
  comment = "admin"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = var.project_name
  }

  aliases = ["${wp_admin_url}"]

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.${dns_valid_domain_name}.arn
    ssl_support_method = "sni-only"
  }

  origin {
    domain_name = "cloudfront.${wp_admin_url}"
    origin_id = "cloudfront-admin-${dns_valid_domain_name}"

    custom_origin_config {
      http_port = 80
      https_port = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols = [
        "TLSv1",
        "TLSv1.1",
        "TLSv1.2",
      ] # required although not necessary since we not using https protocol
    }

    custom_header {
      name = "cloudfront-hash"
      value = "${CLOUDFRONT_HASH}"
    }
  }

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "cloudfront-admin-${dns_valid_domain_name}"

    forwarded_values {
      query_string = true

      cookies {
        forward = "all"
      }
    }

    min_ttl = 0
    default_ttl = 0
    max_ttl = 0
    compress = true
    viewer_protocol_policy = "redirect-to-https"
  }

  # lifecycle {
  #   prevent_destroy = true
  # }
}
EOF

### END - Files that will be generated only once ###

DOMAINNAME_LIST=()
EXPOSE_PORTS=()

DEV_FILE_LIST="-f docker-compose/base.yml "
PROD_FILE_LIST="-c docker-compose/base.yml "

for file_path in docker-compose/development/*.yml
do
  DEV_FILE_LIST+="-f ${file_path} "
  PROD_FILE_LIST+="-c ${file_path/development/production} "

  # TODO use regex
  _DOMAINNAME=${file_path/\.yml/}
  _DOMAINNAME=${_DOMAINNAME/docker-compose\/development\//}

  DOMAINNAME_LIST[${#DOMAINNAME_LIST[@]}]=$_DOMAINNAME
  EXPOSE_PORTS[${#EXPOSE_PORTS[@]}]="${PORT}:${PORT}"
done

# add the dependencies and volumes for nginx in development
cat > docker-compose/development.yml <<EOF
version: '3.7'

services:
  web:
    depends_on:
$(
for DOMAIN in ${DOMAINNAME_LIST[@]}
do
echo "      - wp-${DOMAIN//\./-}"
done
)
    volumes:
$(
for DOMAIN in ${DOMAINNAME_LIST[@]}
do
echo "      - $(pwd)/nginx/development/${DOMAIN}.conf:/etc/nginx/conf.d/${DOMAIN}.conf"
echo "      - $(pwd)/volumes/logs-${DOMAIN//\./-}:/var/log/nginx/wp-${DOMAIN//\./-}"
echo "      - $(pwd)/volumes/wp-${DOMAIN//\./-}:/var/www/html/wp-${DOMAIN//\./-}"
done
)
    ports:
$(
for i in ${!DOMAINNAME_LIST[@]}
do
  echo "      - $((8000 + i)):$((8000 + i))"
done
)
  
  # visualizer
  visualizer:
    image: dockersamples/visualizer
    ports:
      - 9999:8080

EOF

# add the dependencies and volumes for nginx in production
cat > docker-compose/production.yml <<EOF
version: '3.7'

services:
  web:
    depends_on:
$(
for DOMAIN in ${DOMAINNAME_LIST[@]}
do
echo "      - wp-${DOMAIN//\./-}"
done
)
    volumes:
$(
for DOMAIN in ${DOMAINNAME_LIST[@]}
do
echo "      - /wordpress-docker-terraform/nginx/production/${DOMAIN}.conf:/etc/nginx/conf.d/${DOMAIN}.conf"
echo "      - /wordpress-docker-terraform/volumes/logs-${DOMAIN//\./-}:/var/log/nginx/wp-${DOMAIN//\./-}"
echo "      - /wordpress-docker-terraform/volumes/wp-${DOMAIN//\./-}:/var/www/html/wp-${DOMAIN//\./-}"
done
)
    ports:
      - 80:80
EOF

# overide start.sh and stop.sh with updated list of docker-compose file for all the sites
cat > "start.sh" <<EOF
#!/usr/bin/env bash

docker-compose ${DEV_FILE_LIST} -f docker-compose/development.yml up -d
EOF
chmod +x start.sh
cat > "stop.sh" <<EOF
#!/usr/bin/env bash

docker-compose ${DEV_FILE_LIST} -f docker-compose/development.yml down
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
$(
for domain in ${DOMAINNAME_LIST[@]}
do
  echo "mkdir -p /wordpress-docker-terraform/docker-compose/production"
  echo "mkdir -p /wordpress-docker-terraform/nginx/production"
  echo "mkdir -p /wordpress-docker-terraform/volumes/"
echo "mkdir -p /wordpress-docker-terraform/volumes/db-${domain//\./-}"
echo "mkdir -p /wordpress-docker-terraform/volumes/wp-${domain//\./-}"
echo "mkdir -p /wordpress-docker-terraform/volumes/logs-${domain//\./-}"
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

echo NOTE: This operation will NOT destroy the "aws_ebs_volume", "aws_eip", "aws_route53_zone", "aws_acm_certificate", "aws_route53_record", "aws_acm_certificate_validation", "aws_cloudfront_distribution" resources.

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
if ! test -f docker-compose/production.yml
then
  echo "docker-compose/production.yml file is not present. Make sure you run \`./setup.sh\` and go through the instructions before you deploy."
else
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

  docker stack deploy ${PROD_FILE_LIST} -c docker-compose/production.yml wordpress-docker-terraform
fi
EOF

##### DONE #####

cat << EOF
########################################
Your mysql root password for ${domain_name} is ${MYSQL_ROOT_PASSWORD}.
Your mysql user password for ${domain_name} is ${MYSQL_PASSWORD}.
These passwords are stored in the generated docker-compose/${domain_name}.yml file.

Your Cloudfront distribution hash for ${domain_name} is ${CLOUDFRONT_HASH}.
This hash is required to be added automatically to the custom header that your cloudfront distribution will forward to the origin server. The key for the header should be "cloudfront-hash".
'-' will be used for the key name instead of '_' as nginx will drop without setting 'underscores_in_headers on;' https://www.nginx.com/resources/wiki/start/topics/tutorials/config_pitfalls/?highlight=disappearing%20http%20headers#missing-disappearing-http-headers
Lower casing for the key name is used as Amazon Cloudfront will convert the key to lower case anyway following RFC 2616 Section 4.2 (https://tools.ietf.org/html/rfc2616#section-4.2) that headers are to be case-insensitive.

Please store them securely elsewhere as a backup.

Your wordpress admin url is ${wp_admin_url}
########################################
EOF