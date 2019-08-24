#!/usr/bin/env bash

chmod 400 terraform/wordpress-docker-terraform
chmod 400 terraform/wordpress-docker-terraform.pub

echo Enter your AWS named profile:
read AWS_PROFILE
AWS_ACCESS_KEY_ID=$(aws --profile $AWS_PROFILE configure get aws_access_key_id)
if [ "$?" -ne 0 ]; then exit 1; fi
AWS_SECRET_ACCESS_KEY=$(aws --profile $AWS_PROFILE configure get aws_secret_access_key)
if [ "$?" -ne 0 ]; then exit 1; fi
echo AWS_ACCESS_KEY_ID is $AWS_ACCESS_KEY_ID
echo AWS_SECRET_ACCESS_KEY is $AWS_SECRET_ACCESS_KEY

echo "Enter your site's fully qualified domain name (eg. www1.example.com, domain.com):"
DOMAIN_NAME="initial value"
while ! [[ $DOMAIN_NAME == $(echo $DOMAIN_NAME | grep -P '(?=^.{1,254}$)(^(?>(?!\d+\.)[a-zA-Z0-9_\-]{1,63}\.?)+(?:[a-zA-Z]{2,})$)') ]] || [[ $DOMAIN_NAME == "" ]]
do
  if [[ $DOMAIN_NAME != "initial value" ]]
  then
    echo Invalid FQDN. Please try again.
  fi
  DOMAIN_NAME=""
  read DOMAIN_NAME
done

if [[ -f "docker-compose/${DOMAIN_NAME}.yml" ]] || [[ -f "nginx/production/${DOMAIN_NAME}.conf" ]]
then
  cat <<EOF
Domain name ${DOMAIN_NAME} has been processed before.
Duplicated domains will be blocked to prevent overriding of generated files. Some of the generated files contain passwords, so if they are overridden after being provisioned once, they are gone forever.
Exiting...
EOF
  exit 1
fi

MYSQL_PASSWORD=`openssl rand -base64 10`
MYSQL_ROOT_PASSWORD=`openssl rand -base64 10`
CLOUDFRONT_HASH=`openssl rand -base64 10`

cat << EOF
########################################
Your mysql root password for ${DOMAIN_NAME} is ${MYSQL_ROOT_PASSWORD}.
Your mysql user password for ${DOMAIN_NAME} is ${MYSQL_PASSWORD}.
These passwords are stored in the generated docker-compose/${DOMAIN_NAME}.yml file.

Your Cloudfront distribution hash for ${DOMAIN_NAME} is ${CLOUDFRONT_HASH}.
This hash is required to be added manually by you to the custom header that your cloudfront distribution will forward to the origin server. The key for the header should be "cloudfront_hash"; Amazon Cloudfront will convert it to lower case anyway following RFC 2616 Section 4.2 (https://tools.ietf.org/html/rfc2616#section-4.2) that headers are to be case-insensitive.

Please store them securely elsewhere as a backup.
########################################
EOF

######
# NOTE: the syntax `${SOME_VAR//\./-}` is due to a requirement that docker service require dns valid domain name for the naming the service
######

### START - Files that will be generated only once ###

cat > "docker-compose/${DOMAIN_NAME}.yml" <<EOF
version: '3.7'

services:
  db-${DOMAIN_NAME//\./-}:
    image: mysql:5.7
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: "${DOMAIN_NAME}-db"
      MYSQL_USER: "${DOMAIN_NAME}-dbuser"
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ../volumes/db-${DOMAIN_NAME//\./-}:/var/lib/mysql

  wp-${DOMAIN_NAME//\./-}:
    image: wordpress:5-fpm
    restart: always
    volumes:
      - ../php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini
      - ../volumes/wp-${DOMAIN_NAME//\./-}:/var/www/html/wp-${DOMAIN_NAME//\./-}
    depends_on:
      - db-${DOMAIN_NAME//\./-}
    environment:
      WORDPRESS_DB_HOST: db-${DOMAIN_NAME//\./-}:3306
      WORDPRESS_DB_USER: "${DOMAIN_NAME}-dbuser"
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: "${DOMAIN_NAME}-db"
    working_dir: /var/www/html/wp-${DOMAIN_NAME//\./-}
EOF

cat > "nginx/production/${DOMAIN_NAME}.conf" <<EOF
server {
  listen 80;
  server_name cloudfront.${DOMAIN_NAME};

  root /var/www/html/wp-${DOMAIN_NAME//\./-};
  index index.php;

  access_log /var/log/nginx/wp-${DOMAIN_NAME//\./-}/access.log;
  error_log /var/log/nginx/wp-${DOMAIN_NAME//\./-}/error.log;

  client_max_body_size 64M;

  if (\$http_cloudfront_hash != '${CLOUDFRONT_HASH}') {
    return 301 https://${DOMAIN_NAME}\$request_uri;
  }

  location / {
      try_files \$uri \$uri/ /index.php?\$args;
  }

  location ~ \.php\$ {
    try_files \$uri =404;
    fastcgi_split_path_info ^(.+\.php)(/.+)\$;
    fastcgi_pass wp-${DOMAIN_NAME//\./-}:9000;
    fastcgi_index index.php;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param PATH_INFO \$fastcgi_path_info;
  }
}
EOF

### END - Files that will be generated only once ###

DOMAINNAME_LIST=()
EXPOSE_PORTS=()

DEV_FILE_LIST="-f docker-compose/base.yml "
PROD_FILE_LIST="-c docker-compose/base.yml "
PORT=8000 # starts port from 8000 onwards for each subsequent site
for FILENAME in docker-compose/*.yml
do
  if [[ $FILENAME != "docker-compose/base.yml" ]] && [[ $FILENAME != "docker-compose/development.yml" ]] && [[ $FILENAME != "docker-compose/production.yml" ]]
  then
    DEV_FILE_LIST+="-f ${FILENAME} "
    PROD_FILE_LIST+="-c ${FILENAME} "

    # TODO use regex
    _DOMAINNAME=${FILENAME/\.yml/}
    _DOMAINNAME=${_DOMAINNAME/docker-compose\//}
    DOMAINNAME_LIST[${#DOMAINNAME_LIST[@]}]=$_DOMAINNAME
    cat > "nginx/development/${_DOMAINNAME}.conf" <<EOF
server {
  listen ${PORT};

  root /var/www/html/wp-${_DOMAINNAME//\./-};
  index index.php;

  access_log /var/log/nginx/wp-${_DOMAINNAME//\./-}/access.log;
  error_log /var/log/nginx/wp-${_DOMAINNAME//\./-}/error.log;

  client_max_body_size 64M;

  location / {
      try_files \$uri \$uri/ /index.php?\$args;
  }

  location ~ \.php\$ {
    try_files \$uri =404;
    fastcgi_split_path_info ^(.+\.php)(/.+)\$;
    fastcgi_pass wp-${_DOMAINNAME//\./-}:9000;
    fastcgi_index index.php;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param PATH_INFO \$fastcgi_path_info;
  }
}
EOF
    EXPOSE_PORTS[${#EXPOSE_PORTS[@]}]="${PORT}:${PORT}"
    ((PORT++))
  fi
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
echo "      - ../nginx/development/${DOMAIN}.conf:/etc/nginx/conf.d/${DOMAIN}.conf"
echo "      - ../volumes/logs-${DOMAIN//\./-}:/var/log/nginx/wp-${DOMAIN//\./-}"
echo "      - ../volumes/wp-${DOMAIN//\./-}:/var/www/html/wp-${DOMAIN//\./-}"
done
)
    ports:
$(
for EXPOSED_PORT in ${EXPOSE_PORTS[@]}
do
  echo "      - ${EXPOSED_PORT}"
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
echo "      - ../nginx/production/${DOMAIN}.conf:/etc/nginx/conf.d/${DOMAIN}.conf"
echo "      - ../volumes/logs-${DOMAIN//\./-}:/var/log/nginx/wp-${DOMAIN//\./-}"
echo "      - ../volumes/wp-${DOMAIN//\./-}:/var/www/html/wp-${DOMAIN//\./-}"
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
for DOMAIN in ${DOMAINNAME_LIST[@]}
do
  echo "mkdir -p /wordpress-docker-terraform/docker-compose"
  echo "mkdir -p /wordpress-docker-terraform/nginx/production"
  echo "mkdir -p /wordpress-docker-terraform/volumes/"
echo "mkdir -p /wordpress-docker-terraform/volumes/db-${DOMAIN//\./-}"
echo "mkdir -p /wordpress-docker-terraform/volumes/wp-${DOMAIN//\./-}"
echo "mkdir -p /wordpress-docker-terraform/volumes/logs-${DOMAIN//\./-}"
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

echo NOTE: This operation will NOT destroy the "aws_ebs_volume" and the "aws_eip" resource.

docker run \\
  --rm \\
  -it \\
  -v $(PWD)/terraform.tfstate:/workspace/terraform.tfstate \\
  --env AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \\
  --env AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \\
  wordpress-docker-terraform \\
  destroy \\
  -target aws_key_pair.this \\
  -target aws_security_group.this \\
  -target aws_volume_attachment.this \\
  -target aws_eip_association.this \\
  -target aws_instance.this
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
  # wait for stack to be fully removed https://github.com/moby/moby/issues/32367#issuecomment-301908838
  docker stack --detach=false rm wordpress-docker-terraform
  # TODO wait for it here
  docker stack deploy ${PROD_FILE_LIST} -c docker-compose/production.yml wordpress-docker-terraform
fi
EOF
