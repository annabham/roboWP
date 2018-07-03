#!/bin/bash 
#title          :roboWP.sh
#description    :Script to install WordPress on cPanel servers
#author         :Miss Anna ft Sean Hicks
#date           :20180617
#version        :0.1    
#usage          :./roboWP.sh
#notes          :Probably shouldn't use if the server is old and/or weird
#============================================================================
# Copyright (c) 2018 Anna Schoolfield, Sean Hicks
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#============================================================================
echo "!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!"
echo " This script does not have enough logic to be idiot proof."
echo " Pay attention to what you're doing and don't be careless."
echo "        USE ABSOLUTE PATH IF SPECIFYING LOCATION!"
echo "!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!"
echo " "

# Prompt for the cPanel username
read -p 'What is the cPanel username to install under? ' CPANEL
PRT=$(whmapi1 accountsummary user=$CPANEL | grep 'partition: ' | awk -F': ' '{print $2}')

# Prompt for the ticket number
read -p 'What is the ticket number? (Or some unique value to generate db name & username) ' TICKET


# Confirm installation directory
echo -n "Hit y to install the WP site in the default public_html; Otherwise hit n to enter a custom dir: "
# While loop and switch case use to structure an options selection loop.
while (( !DIROPTDONE )); do
	read DIROPT
	case "$DIROPT" in
		y)
			DESTDIR="/$PRT/$CPANEL/public_html"
			DIROPTDONE=1
			;;
		n)
			read -p "Please specify the directory path to install to: " DESTDIR
			# This little bit strips the ending forward slash if present, and nothing if not
			DESTDIR=$(echo $DESTDIR | sed '$s%/$%%g')
			DIROPTDONE=1
			;;
		*)
			echo "Please choose a valid option (y or n)!"
			echo -n "Hit y to install the WP site in the default public_html; Otherwise hit n to enter a custom dir: "
			;;
	esac
done

############################################
# Gathering variables
PREFIX=$(uapi --user=$CPANEL Mysql get_restrictions | grep prefix | awk '{ print $2 }')
MYSQL=$PREFIX'wp'
MYSQL+=$TICKET
############################################
# Messy solution to find domain
############################################
DOMAIN=""
DOMLIST=$(ls -1 /var/cpanel/userdata/$CPANEL/* | grep -v '_SSL$\|.yaml$\|.json$\|cache$\|main$')
CNT=4
SUBDIR=$(echo "$DESTDIR" | sed 's%^/'"$PRT"'/'"$CPANEL"'/%%')
BUFFER=/$PRT/$CPANEL/
while (( !domfind_done )); do
	BUFFER="${BUFFER}$(echo "$DESTDIR" | cut -d'/' -f$CNT)"
	SUBDIR=$(echo "$SUBDIR" | sed -E 's%^[^/]+/%%')
	DOMLIST=$(echo "$DOMLIST" | xargs grep -l "$BUFFER")
	BUFFER="${BUFFER}/"
	DOMCNT=$(echo "$DOMLIST" | wc -l)
	if [[ "$DOMCNT" -eq 1 ]]; then
		DOMAIN=$(echo "$DOMLIST" | rev | cut -d'/' -f1 | rev)
		domfind_done=1
	fi
	if [[ "$DOMCNT" -eq 0 ]]; then
		echo "Domain not found! Continuing without..."
		DOMAIN="!!!ERROR!!!"
		domfind_done=1
	fi
	((CNT++))
done
############################################
echo "****************************"
echo "****Confirm installation****"
echo "****************************"
echo "Target cPanel Account:" $CPANEL
echo "Target Domain: "$DOMAIN / $SUBDIR
echo "MySQL database and username:" $MYSQL
echo "Destination directory:" $DESTDIR
echo "Current contents of the destination directory (empty if nothing listed):"
ls -1 $DESTDIR
echo " "
read -p "Would you like to proceed with the WP installation? [y/n] " -n 1 -r
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    exit 1
fi

echo " "
# Generate a random pw for the MySQL db user
MYSQLUSERPASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)

# Create MySQL db & user
echo "Creating MySQL user......................"
uapi --user=$CPANEL Mysql create_user name=$MYSQL password=$MYSQLUSERPASS
if [ "$?" -ne 0 ]; then
	echo "Error creating MySQL user!"
	exit 1
fi

echo "Creating MySQL database......................"
uapi --user=$CPANEL Mysql create_database name=$MYSQL
if [ "$?" -ne 0 ]; then
	echo "Error creating MySQL database!"
	exit 1
fi

echo "Setting privileges on database......................"
uapi --user=$CPANEL Mysql set_privileges_on_database user=$MYSQL database=$MYSQL privileges=ALL
if [ "$?" -ne 0 ]; then
	echo "Error setting MySQL privileges!"
	exit 1
fi

# Download and extract the WP tarball, clean it up afterwards
wget -qO-  https://wordpress.org/latest.tar.gz | tar --strip-components=1 -xz -C $DESTDIR
rm -f $DESTDIR/latest.tar.gz

# Set up the initial wp-config file
mv $DESTDIR/wp-config-sample.php $DESTDIR/wp-config.php

# Set up the default WP .htaccess file

cat >> $DESTDIR/.htaccess << "EOF"
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
EOF

# Make sure everything is chowned to the cPanel user
chown -R $CPANEL:$CPANEL $DESTDIR/* $DESTDIR/.*

# Update Salts in the wp-config file
SALT=$(curl -L https://api.wordpress.org/secret-key/1.1/salt/)
STRING='put your unique phrase here'
printf '%s\n' "g/$STRING/d" a "$SALT" . w | ed -s $DESTDIR/wp-config.php

# Update wp-config file with MySQL info
echo "*************************************************************"
sed -i 's/database_name_here/'"$MYSQL"'/' $DESTDIR/wp-config.php
sed -i 's/username_here/'"$MYSQL"'/' $DESTDIR/wp-config.php
sed -i 's/password_here/'"$MYSQLUSERPASS"'/' $DESTDIR/wp-config.php
echo "Here's the MySQL info in the wp-config.php file"
grep -E 'DB_NAME|DB_USER|DB_PASSWORD' $DESTDIR/wp-config.php

echo "******************************************************************************************"
echo "WP installed, visit $DOMAIN / $SUBDIR to complete the installation"
echo "******************************************************************************************"
