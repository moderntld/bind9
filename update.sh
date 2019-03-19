#!/bin/bash
#Update script for our BIND9 conf on Ubuntu 18.04

cd /opt/tld/bind-conf/

git pull

cp /opt/tld/bind-conf/db* /etc/bind/
cp /opt/tld/bind-conf/named.conf* /etc/bind/
cp /opt/tld/bind-conf/zones.rfc1918 /etc/bind/
cp /opt/tld/bind-conf/bind.keys /etc/bind/

systemctl reload bind9
