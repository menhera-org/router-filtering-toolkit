#!/bin/sh

set -e

DIR=$( dirname "$0" )

AS_CONFIG_FILE=$DIR/config/as-config.env
SPEC_FILE=$DIR/config/bgp-filters.txt
IFS_PEER=$DIR/config/interfaces-peer
IFS_CUSTOMER=$DIR/config/interfaces-customer
SPECIAL_ADDR_V4=$DIR/config/special-addr.v4
SPECIAL_ADDR_V6=$DIR/config/special-addr.v6
FILTERS_V4=$DIR/config/filters.v4
FILTERS_V6=$DIR/config/filters.v6

[ -f "$AS_CONFIG_FILE" ] && . "$AS_CONFIG_FILE"

command -v bgpq4 >/dev/null || {
	echo "bgpq4 command not found" >&2
	exit 1
}

TMP=$( mktemp /tmp/iptables-v6.XXXXXX )
trap 'rm -f $TMP' EXIT

strip_comments() {
	egrep -v '^\s*(#|$)'
}

echo "*filter" > $TMP

cat <<EOF >> $TMP
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:PEER-IN - [0:0]
:PEER-OUT - [0:0]
:CUSTOMER-IN - [0:0]
:CUSTOMER-OUT - [0:0]
:DROP-INVALID - [0:0]
EOF

cat < "$FILTERS_V6" >> $TMP

echo "-A INPUT -d fe80::/64 -j ACCEPT" >> $TMP
echo "-A OUTPUT -s fe80::/64 -j ACCEPT" >> $TMP
echo "-A INPUT -d ff00::/8 -j ACCEPT" >> $TMP
echo "-A OUTPUT -d ff00::/8 -j ACCEPT" >> $TMP

strip_comments < "$SPECIAL_ADDR_V6" | while read -r addr ; do
	echo "-A DROP-INVALID -s ${addr} -j DROP" >> $TMP
	echo "-A DROP-INVALID -d ${addr} -j DROP" >> $TMP
done

echo "-A DROP-INVALID -j RETURN" >> $TMP

echo "-A CUSTOMER-IN -j DROP-INVALID" >> $TMP
echo "-A CUSTOMER-IN -j RETURN" >> $TMP

echo "-A CUSTOMER-OUT -j DROP-INVALID" >> $TMP
echo "-A CUSTOMER-OUT -j RETURN" >> $TMP

echo "-A PEER-IN -j DROP-INVALID" >> $TMP
bgpq4 -6 -F "-A PEER-IN -d %n/%l -j RETURN\n" "$SELF_OBJ" >> $TMP
echo "-A PEER-IN -j DROP" >> $TMP

echo "-A PEER-OUT -j DROP-INVALID" >> $TMP
bgpq4 -6 -F "-A PEER-OUT -s %n/%l -j RETURN\n" "$SELF_OBJ" >> $TMP
echo "-A PEER-OUT -j DROP" >> $TMP

strip_comments < "$IFS_CUSTOMER" | while read -r iface ; do
	echo "-A INPUT -i ${iface} -j CUSTOMER-IN" >> $TMP
	echo "-A FORWARD -i ${iface} -j CUSTOMER-IN" >> $TMP
	echo "-A FORWARD -o ${iface} -j CUSTOMER-OUT" >> $TMP
	echo "-A OUTPUT -o ${iface} -j CUSTOMER-OUT" >> $TMP
done

strip_comments < "$IFS_PEER" | while read -r iface ; do
	echo "-A INPUT -i ${iface} -j PEER-IN" >> $TMP
	echo "-A FORWARD -i ${iface} -j PEER-IN" >> $TMP
	echo "-A FORWARD -o ${iface} -j PEER-OUT" >> $TMP
	echo "-A OUTPUT -o ${iface} -j PEER-OUT" >> $TMP
done

echo >> $TMP
echo "COMMIT" >> $TMP

if [ "$1" = "ip6tables-update" ] ; then
	cat $TMP | tee /etc/iptables/rules.v6 | ip6tables-restore
else
	cat $TMP
fi

