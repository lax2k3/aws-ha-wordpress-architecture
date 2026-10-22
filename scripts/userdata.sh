#!/bin/bash
set -e

# Update operating system and install dependencies
yum update -y
yum install -y httpd php php-mysqlnd php-gd php-xml php-mbstring amazon-efs-utils

# Enable and start Apache web server
systemctl start httpd
systemctl enable httpd

# Mount shared Amazon EFS volume
mkdir -p /var/www/html
mount -t efs -o tls ${WPElasticFileSystemID}:/ /var/www/html
echo "${WPElasticFileSystemID}:/ /var/www/html efs _netdev,tls 0 0" >> /etc/fstab

# Retrieve and configure WordPress on shared storage
if [ ! -f /var/www/html/wp-config.php ]; then
  cd /var/www/html
  wget https://wordpress.org/latest.tar.gz
  tar -xzf latest.tar.gz --strip-components=1
  rm -f latest.tar.gz

  cp wp-config-sample.php wp-config.php
  sed -i "s/database_name_here/${DBName}/" wp-config.php
  sed -i "s/username_here/${DBUser}/" wp-config.php
  sed -i "s/password_here/${DBPassword}/" wp-config.php
  sed -i "s/localhost/${DBEndpoint}/" wp-config.php

  chown -R apache:apache /var/www/html
fi

systemctl restart httpd
