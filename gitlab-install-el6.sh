#!/bin/bash
# Installer for GitLab on RHEL 6 (Red Hat Enterprise Linux and CentOS)
# mattias.ohlsson@inprose.com
#
# Only run this on a clean machine. I take no responsibility for anything.
#
# Submit issues here: github.com/mattias-ohlsson/gitlab-installer

# Define the public hostname
GL_HOSTNAME=$HOSTNAME

# Install from this GitLab branch
GL_GIT_BRANCH="5-2-stable"

# Define the version of ruby the environment that we are installing for
RUBY_VERSION="1.9.3-p429"

# Define MySQL user name
MYSQL_USER=gitlab

# Define MySQL user password
MYSQL_USER_PW=$(cat /dev/urandom | tr -cd [:alnum:] | head -c ${1:-16})

# Define SMTP server for sendmail
SMTP_SERVER=smtp.example.com

# Exit on error

die()
{
  # $1 - the exit code
  # $2 $... - the message string

  retcode=$1
  shift
  printf >&2 "%s\n" "$@"
  exit $retcode
}

echo "### Check OS (we check if the kernel release contains el6)"
uname -r | grep "el6" || die 1 "Not RHEL or CentOS 6 (el6)"

# Install base packages
## Install epel-release
yum -y install http://dl.fedoraproject.org/pub/epel/6/i386/epel-release-6-8.noarch.rpm

## Install build dependencies
yum -y install patch gcc-c++ readline-devel libffi-devel make autoconf automake libtool bison libxml2-devel libxslt-devel libyaml-devel gettext expat-devel curl-devel zlib-devel openssl-devel cpan

## Install git from source
echo "yes" | cpan -i ExtUtils::MakeMaker
cd /usr/local/src
curl https://www.kernel.org/pub/software/scm/git/git-1.8.3.tar.bz2 | tar xj
cd git-1.8.3
./configure --prefix=/usr/local --without-tcltk
make install

# Ruby
## Install rvm (instructions from https://rvm.io)
curl -L get.rvm.io | bash -s stable

## Load RVM
source /etc/profile.d/rvm.sh

## Install Ruby (use command to force non-interactive mode)
rvm install $RUBY_VERSION
rvm --default use $RUBY_VERSION

## Install core gems
gem install --no-ri --no-rdoc bundler

## Install charlock_holmes
gem install charlock_holmes --version '0.6.9.4'

# Users

## Create a git user for Gitlab
adduser --system --create-home --comment 'GitLab' git

## Configure git for the git user
su - git -c "git config --global user.name GitLab"
su - git -c "git config --global user.email gitlab@$GL_HOSTNAME"

# GitLab Shell

## Clone gitlab-shell
su - git -c "git clone https://github.com/gitlabhq/gitlab-shell.git"

## Edit configuration
su - git -c "cp gitlab-shell/config.yml.example gitlab-shell/config.yml"

## Run setup
su - git -c "gitlab-shell/bin/install"

### Fix wrong mode bits
chmod 600 /home/git/.ssh/authorized_keys
chmod 700 /home/git/.ssh

# Database

## Install redis
yum -y install redis

## Start redis
service redis start

## Automatically start redis
chkconfig redis on

## Install mysql-server
yum -y install mysql-server

## Turn on autostart
chkconfig mysqld on

## Start mysqld
service mysqld start

### Create a user for Gitlab
echo "CREATE USER '$MYSQL_USER'@'localhost' IDENTIFIED BY '$MYSQL_USER_PW';" | mysql -u root

### Create the database
echo "CREATE DATABASE IF NOT EXISTS gitlabhq_production DEFAULT CHARACTER SET 'utf8' COLLATE 'utf8_unicode_ci';" | mysql -u root

### Grant permissions to Gitlab user
echo "GRANT SELECT, LOCK TABLES, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER ON gitlabhq_production.* TO '$MYSQL_USER'@'localhost';" | mysql -u root

# Email

## Install sendmail-cf
yum -y install sendmail-cf

## Configure sendmail
cd /etc/mail
sed -i "/SMART_HOST/a\
define(\`SMART_HOST', \`$SMTP_SERVER')" sendmail.mc
sed -i "s/^\(EXPOSED_USER(\`root')dnl\)$/dnl \1/" sendmail.mc
make
chkconfig sendmail on

# GitLab

## Clone GitLab
su - git -c "git clone https://github.com/gitlabhq/gitlabhq.git gitlab"

## Checkout
su - git -c "cd gitlab;git checkout $GL_GIT_BRANCH"

## Configure GitLab

cd /home/git/gitlab

### Copy the example GitLab config
su git -c "cp config/gitlab.yml.example config/gitlab.yml"

### Change gitlabhq hostname to GL_HOSTNAME
sed -i "s/  host: localhost/  host: $GL_HOSTNAME/g" config/gitlab.yml

### Change the from email address
sed -i "s/from: gitlab@localhost/from: gitlab@$GL_HOSTNAME/g" config/gitlab.yml

### Change Git path
sed -i "s|/usr/bin/git|/usr/local/bin/git|g" config/gitlab.yml

### Copy the example Puma config
su git -c "cp config/puma.rb.example config/puma.rb"

### Listen on localhost:3000
sed -i "s/^bind /# bind /g" /home/git/gitlab/config/puma.rb
sed -i "s|# bind 'tcp://0.0.0.0:9292'|bind 'tcp://127.0.0.1:3000'|g" /home/git/gitlab/config/puma.rb

### Copy database congiguration
su git -c "cp config/database.yml.mysql config/database.yml"

### Set MySQL username and password in configuration file
sed -i "s/root/$MYSQL_USER/g" config/database.yml
sed -i "s/secure password/$MYSQL_USER_PW/g" config/database.yml

### Create pidfile directory
su git -c "mkdir tmp/pids"

### Create uploads directory
su git -c "mkdir public/uploads"

### Create satellites directory
su git -c "mkdir /home/git/gitlab-satellites"

# Install Gems

## For Charlock holmes
yum -y install libicu-devel

## For MySQL
yum -y install mysql-devel
su git -c "bundle install --deployment --without development test postgres"

# Initialise Database and Activate Advanced Features
# Force it to be silent (issue 31)
export force=yes
su git -c "bundle exec rake gitlab:setup RAILS_ENV=production"

## Install init script
curl --output /etc/init.d/gitlab https://raw.github.com/gitlabhq/gitlab-recipes/master/init.d/gitlab-centos
chmod +x /etc/init.d/gitlab

## Fix for issue 30
# bundle not in path (edit init-script).
# Add after ". /etc/rc.d/init.d/functions" (row 17).
sed -i "17 a source /etc/profile.d/rvm.sh\nrvm use $RUBY_VERSION" /etc/init.d/gitlab

### Enable and start
chkconfig gitlab on
service gitlab start

# Apache

## Install
yum -y install httpd
chkconfig httpd on

## Configure
curl -o /etc/httpd/conf.d/gitlab.conf https://raw.github.com/gitlabhq/gitlab-recipes/master/apache/gitlab
sed -i -e "s/gitlab\.example\.com/$GL_HOSTNAME/g" \
       -e "s/example\.com/$GL_HOSTNAME/g" \
       -e "/<VirtualHost \*:443>/,/<\/VirtualHost>/ s/^/#/" \
       -e "s/apache2/httpd/g" /etc/httpd/conf.d/gitlab.conf
mkdir /var/log/httpd/gitlab

### Configure SElinux
setsebool -P httpd_can_network_connect 1

## Start
service httpd start

#  Configure iptables

## Open port 80
iptables -I INPUT -p tcp -m tcp --dport 80 -j ACCEPT

## Save iptables
service iptables save

# Final configuration check
su - git -c "cd gitlab && bundle exec rake gitlab:check RAILS_ENV=production"

echo "### Done ###############################################"
echo "# If the above configuration check is all green, you're set!"
echo "# The only thing that should be red is the 'init script up-to-date' check."
echo "#"
echo "# The password for the $MYSQL_USER MySQL user is in:"
echo "# /home/git/gitlab/config/database.yml"
echo "#"
echo "# If this is a production server, you should run (as root):"
echo "# /usr/bin/mysql_secure_installation"
echo "# and follow all of its security recommendations."
echo "#"
echo "# Point your browser to:" 
echo "# http://$GL_HOSTNAME (or: http://<host-ip>)"
echo "# Default admin username: admin@local.host"
echo "# Default admin password: 5iveL!fe"
echo "#"
echo "# Flattr me if you like this! https://flattr.com/profile/mattiasohlsson"
echo "###"
