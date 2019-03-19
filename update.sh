#!/bin/bash
#Update script for our BIND9 conf on Ubuntu 18.04

cd /opt/tld/bind-conf/

git fetch origin master
git reset --hard origin/master

# BEGIN srvzone code

file_root='/var/cache/bind/db.root'
file_master='/etc/bind/opennic/master/$TLD'
file_slave='/var/cache/bind/db.$TLD'
destination='/tmp/named.conf.opennic-final'
tmp_dest='/tmp/named.conf.opennic'

AWK=/usr/bin/awk
CHECKCONF=/usr/sbin/named-checkconf
CUT=/usr/bin/cut
DIG=/usr/bin/dig
GREP=/bin/grep
PRINTF=/usr/bin/printf
RNDC=/usr/sbin/rndc
SED=/bin/sed

NS[0]=45.56.115.189
NS[1]=45.56.116.224
NS6[0]=2001:470:1f0e:8a0::2
NS6[1]=2600:3c02::f03c:91ff:fe33:e1ba

RES[0]="${NS[@]} ${NS6[@]}"
for ns in "${NS[@]}"; do
  soa=$(dig +short +tries=1 SOA . @$ns | grep -v '^;')
  if [ "$soa" ]; then NS0=$ns ; break ; fi
done
if [ ! "$NS0" ]; then
  echo "An NS0 server could not be reached -- aborting!"
  exit 1
fi


# Make sure only one copy runs at a time
LOCK="srvzone.lock"
r=$($PRINTF %05d $RANDOM)
sleep ${r:0:1}.${r:1:5}
if [ -f $LOCK ]; then
  if [ "$((`date +%s` - `date -r $LOCK +%s`))" -lt 600 ]; then exit 0; fi
fi
touch $LOCK

# Check if user entered a nameserver
for arg in "$@"; do
  case $arg in
    -d)	DEBUG=1
	;;
     *) myNS=$(echo $arg | $AWK '{print tolower($0)}')
	if [ ${#myNS} -lt 5 ]; then myNS="$myNS.opennic.glue"; fi
	;;
  esac
done

# Start printing the new file
ifs=$IFS
rm -f "$tmp_dest"
{ echo "#"
  echo "# OpenNIC zone config - file created by $HOSTNAME"
  echo "# Generated on `date '+%A, %d %b %Y at %T'`"
  echo "#"
} >> $tmp_dest


# Collect list of TLDs
TXT=(dns.opennic.glue $($DIG @$NS0 TXT tlds.opennic.glue +short | grep -v '^;' | $SED s/\"//g))
IFS=$'\n' TLDS=($(sort <<<"${TXT[*]}"))
IFS=$ifs
if [ "$TLDS" == "dns.opennic.glue" ]; then
  echo "Failed to obtain list of TLDs"
  rm -f $LOCK
  exit 1
fi
for TLD in "${TLDS[@]}" ; do

  # Check if this zone is mastered by this server
  zone="$TLD.opennic.glue"
  if [ "$TLD" == "." ]; then zone="" ; fi
  master=($($DIG TXT +short $zone. @$NS0 | sed 's/"//g' | $GREP ^ns) ns0.opennic.glue.)
  SLAVE=1;
  if [ "$myNS" ]; then
    mm=$(echo ${master[0]} | $SED 's/\.$//')
    if [ "$myNS" == "$mm" ]; then SLAVE=""; fi
  fi

  path=$(eval echo $file_slave)
  if [ ! "$SLAVE" ]; then path=$(eval echo $file_master) ; fi
  if [ "$TLD" == "." ]; then path=$(eval echo $file_root) ; fi

  # Begin printing the zone config
  echo
  echo "zone \"$TLD\" in {"
  if [ "$SLAVE" ]; then
    echo "	type slave;"
    echo "	file \"$path\";"
    echo "	notify no;"
    echo "	masters {"

    # Collect a list of master nameservers for the zone
    for mm in "${master[@]}" ; do
      mm=$(echo $mm | $SED 's/\.$//')
      ns=$(echo $mm | $CUT -d. -f1 | $SED 's/ns//')
      AT="@$myDNS"
      if [ "$ns" == "0" ]; then AT="@$NS0"; fi
      if [ "$AT" == "@" ]; then AT=""; fi

      # If this is an unknown NS, query its IPs
      if [ ! "${RES[$ns]}" ]; then
        A4=$($DIG A +short $mm $AT | $GREP -v '^;')
        A6=$($DIG AAAA +short $mm $AT | $GREP -v '^;')
        RES[$ns]="${A4[@]} ${A6[@]}"
      fi
      read -a IP <<< ${RES[$ns]}

      # Print all IPs for all nameservers
      for addr in "${IP[@]}" ; do
        $PRINTF "\t\t%-39s # %s\n" "$addr;" "$mm"
      done
    done
    echo "	};"

  else
    echo "	type master;"
    if [ "$signed" == "TRUE" ]; then
      echo "	file \"${path}.signed\";"
    else
      echo "	file \"$path\";"
    fi
    echo "	allow-transfer { any; };"
    echo "	notify yes;"
    if [ "$myNS" != "ns0" ]; then
      echo "	also-notify {"
      for i in "${NS[@]}"; do
        echo "		$i;"
      done
      for i in "${NS6[@]}"; do
        echo "		$i;"
      done
      echo "	};"
    fi
  fi

  echo "};"
done >> "$tmp_dest"

# Confirm the new file is valid
TEST=$($CHECKCONF "$tmp_dest")
if [ "$TEST" ]; then
  echo "Failed zone generation - please see $tmp_dest"
  rm -f $LOCK
  exit 1
fi

if [ "$DEBUG" ]; then
  echo "Root zone:	$file_root"
  echo "Master zones:	$file_master"
  echo "Slave zones:	$file_slave"
  echo "Config file:	$destination"
  echo "Test file:	$tmp_dest"
else
  mv "$tmp_dest" "$destination"
  $RNDC reload > /dev/null
fi

rm -f $LOCK

# END srvzone code

cp /tmp/named.conf.opennic-final /etc/bind/named.conf.opennic

cp /opt/tld/bind-conf/db* /etc/bind/
cp /opt/tld/bind-conf/named.conf* /etc/bind/
cp /opt/tld/bind-conf/zones.rfc1918 /etc/bind/
cp /opt/tld/bind-conf/bind.keys /etc/bind/

systemctl reload bind9
