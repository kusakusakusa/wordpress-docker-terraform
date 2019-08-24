#!/usr/bin/env bash

if ! [ -f terraform.tfstate ]
then
  touch terraform.tfstate
  echo terraform.tfstate file created.
fi

# echo Enter your AWS named profile:
# read AWS_PROFILE
# AWS_ACCESS_KEY_ID=$(aws --profile $AWS_PROFILE configure get aws_access_key_id)
# if [ "$?" -ne 0 ]; then exit 1; fi
# AWS_SECRET_ACCESS_KEY=$(aws --profile $AWS_PROFILE configure get aws_secret_access_key)
# if [ "$?" -ne 0 ]; then exit 1; fi
# echo AWS_ACCESS_KEY_ID is $AWS_ACCESS_KEY_ID
# echo AWS_SECRET_ACCESS_KEY is $AWS_SECRET_ACCESS_KEY

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

if test -f "docker-compose/${DOMAIN_NAME}.yml"
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

cat << EOF
Your mysql root password is ${MYSQL_ROOT_PASSWORD}.
Your mysql user password is ${MYSQL_PASSWORD}.
These passwords are stored in the generated docker-compose/${DOMAIN_NAME}.yml file.
Please store them securely elsewhere as a backup.
EOF

cat > "docker-compose/${DOMAIN_NAME}.yml" <<EOF
version: '3.7'

services:
  db-${DOMAIN_NAME}:
    image: mysql:5.7
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: "${DOMAIN_NAME}-db"
      MYSQL_USER: "${DOMAIN_NAME}-dbuser"
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ../volumes/db-${DOMAIN_NAME}:/var/lib/mysql

  wp-${DOMAIN_NAME}:
    image: wordpress:5-fpm
    restart: always
    volumes:
      - ./php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini
    depends_on:
      - db-${DOMAIN_NAME}
    environment:
      WORDPRESS_DB_HOST: db-${DOMAIN_NAME}:3306
      WORDPRESS_DB_USER: "${DOMAIN_NAME}-dbuser"
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: "${DOMAIN_NAME}-db"
    working_dir: /var/www/html/wp-${DOMAIN_NAME}
    volumes:
      - ../volumes/wp-${DOMAIN_NAME}:/var/www/html/wp-${DOMAIN_NAME}
EOF

DOMAINNAME_LIST=()
EXPOSE_PORTS=()

FILE_LIST="-f docker-compose/base.yml "
PORT=8000 # starts port from 8000 onwards for each subsequent site
for FILENAME in docker-compose/*.yml
do
  if [[ $FILENAME != "docker-compose/base.yml" ]] && [[ $FILENAME != "docker-compose/development.yml" ]] && [[ $FILENAME != "docker-compose/production.yml" ]]
  then
    FILE_LIST+="-f ${FILENAME} "

    # TODO use regex
    _DOMAINNAME=${FILENAME/\.yml/}
    _DOMAINNAME=${_DOMAINNAME/docker-compose\//}
    DOMAINNAME_LIST[${#DOMAINNAME_LIST[@]}]=$_DOMAINNAME
    cat > "nginx/dev/${_DOMAINNAME}.conf" <<EOF
server {
  listen ${PORT};

  root /var/www/html/wp-${_DOMAINNAME};
  index index.php;

  access_log /var/log/nginx/wp-${_DOMAINNAME}/access.log;
  error_log /var/log/nginx/wp-${_DOMAINNAME}/error.log;

  client_max_body_size 64M;

  location / {
      try_files \$uri \$uri/ /index.php?\$args;
  }

  location ~ \.php\$ {
    try_files \$uri =404;
    fastcgi_split_path_info ^(.+\.php)(/.+)\$;
    fastcgi_pass wp-${_DOMAINNAME}:9000;
    fastcgi_index index.php;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param PATH_INFO \$fastcgi_path_info;
  }
}
EOF
    EXPOSE_PORTS[${#EXPOSE_PORTS[@]}]="${PORT}:${PORT}"
    ((PORT++))

    cat > "nginx/${_DOMAINNAME}.conf" <<EOF
server {
  listen 80;
  server_name: ${_DOMAINNAME};

  root /var/www/html/wp-${_DOMAINNAME};
  index index.php;

  access_log /var/log/nginx/wp-${_DOMAINNAME}/access.log;
  error_log /var/log/nginx/wp-${_DOMAINNAME}/error.log;

  client_max_body_size 64M;

  location / {
      try_files \$uri \$uri/ /index.php?\$args;
  }

  location ~ \.php\$ {
    try_files \$uri =404;
    fastcgi_split_path_info ^(.+\.php)(/.+)\$;
    fastcgi_pass wp-${DOMAIN_NAME}:9000;
    fastcgi_index index.php;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param PATH_INFO \$fastcgi_path_info;
  }
}
EOF
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
echo "      - wp-${DOMAIN}"
done
)
    volumes:
$(
for DOMAIN in ${DOMAINNAME_LIST[@]}
do
echo "      - ../nginx/dev/${DOMAIN}.conf:/etc/nginx/conf.d/${DOMAIN}.conf"
echo "      - ../volumes/logs-${DOMAIN}:/var/log/nginx/wp-${DOMAIN}"
echo "      - ../volumes/wp-${DOMAIN}:/var/www/html/wp-${DOMAIN}"
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
# overide start.sh and stop.sh with updated list of docker-compose file for all the sites
cat > "start.sh" <<EOF
#!/usr/bin/env bash

docker-compose ${FILE_LIST} -f docker-compose/development.yml up -d
EOF
chmod +x start.sh
cat > "stop.sh" <<EOF
#!/usr/bin/env bash

docker-compose ${FILE_LIST} -f docker-compose/development.yml down
EOF
chmod +x stop.sh
