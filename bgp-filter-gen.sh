#!/bin/sh

set -e

DIR=$( dirname "$0" )

AS_CONFIG_FILE=$DIR/config/as-config.env
SPEC_FILE=$DIR/config/bgp-filters.txt
[ -f "$AS_CONFIG_FILE" ] && . "$AS_CONFIG_FILE"

command -v bgpq4 || {
	echo "bgpq4 command not found" >&2
	exit 1
}

TMP=$( mktemp /tmp/bgp-filter.XXXXXX )
trap 'rm -f $TMP' EXIT

GEN_V4="bgpq4 -4 -m 24 -s -A"
GEN_V6="bgpq4 -6 -m 48 -s -A"

gen_dualstack_as() {
	local prefix_list_name
	local obj
	
	[ -n "$1" ] || return 1
	[ -n "$2" ] || return 1

	prefix_list_name=$1
	obj=$2

	$GEN_V4 -l "$prefix_list_name" "${obj}"
	$GEN_V6 -l "$prefix_list_name" "${obj}"
}

gen_filters() {
	local filter_name
	local obj

	echo 'conf t' > $TMP

	egrep -v '^\s*(#|$)' $SPEC_FILE | while read -r filter_name obj ; do
		gen_dualstack_as "$filter_name" "$obj" >> $TMP
	done

	# Filter rules for output to peers
	bgpq4 -4 -s -A -l "$PEER_OUT_LIST_NAME" -m 24 "${SELF_OBJ}" >> $TMP
	bgpq4 -6 -s -A -l "$PEER_OUT_LIST_NAME" -m 48 "${SELF_OBJ}" >> $TMP

	# Filter rules for output to full-route customers
	echo "no ip prefix-list ${CUSTOMERS_OUT_FULLROUTE_LIST_NAME}" >> $TMP
	echo "ip prefix-list ${CUSTOMERS_OUT_FULLROUTE_LIST_NAME} seq 10 permit 0.0.0.0/0 ge 8 le 24" >> $TMP
	echo "no ipv6 prefix-list ${CUSTOMERS_OUT_FULLROUTE_LIST_NAME}" >> $TMP
	echo "ipv6 prefix-list ${CUSTOMERS_OUT_FULLROUTE_LIST_NAME} seq 10 permit ::/0 ge 8 le 48" >> $TMP
	
	# Filter rules for output to default-route customers
	bgpq4 -4 -s -A -l "$CUSTOMERS_OUT_DEFAULT_LIST_NAME" -R 32 "${SELF_OBJ}" >> $TMP
	echo "ip prefix-list ${CUSTOMERS_OUT_DEFAULT_LIST_NAME} seq 2000 permit 0.0.0.0/0" >> $TMP
	bgpq4 -6 -s -A -l "$CUSTOMERS_OUT_DEFAULT_LIST_NAME" -R 128 "${SELF_OBJ}" >> $TMP
	echo "ipv6 prefix-list ${CUSTOMERS_OUT_DEFAULT_LIST_NAME} seq 2000 permit ::/0" >> $TMP
	
	# Filter rules for input from sub-ASes
	bgpq4 -4 -s -A -l "$SUBAS_IN_LIST_NAME" -r "$SUBAS_MIN_PREFIX_LEN_V4" -R 32 "${SELF_OBJ}" >> $TMP
	bgpq4 -6 -s -A -l "$SUBAS_IN_LIST_NAME" -r "$SUBAS_MIN_PREFIX_LEN_V6" -R 128 "${SELF_OBJ}" >> $TMP

	# Filter rules for input from transits
	bgpq4 -4 -s -A -l "$TRANSIT_IN_LIST_NAME" -R 32 "${SELF_OBJ}" | sed 's/permit/deny/' >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2010 deny 0.0.0.0/0 le 7" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2020 deny 10.0.0.0/8 ge 8" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2030 deny 172.16.0.0/12 ge 12" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2040 deny 192.168.0.0/16 ge 16" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2050 deny 127.0.0.0/8 ge 8" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2060 deny 100.64.0.0/10 ge 10" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2070 deny 192.0.0.0/24 ge 24" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2080 deny 192.0.2.0/24 ge 24" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2090 deny 198.18.0.0/15 ge 15" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2100 deny 198.51.100.0/24 ge 24" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 2110 deny 203.0.113.0/24 ge 24" >> $TMP
	echo "ip prefix-list ${TRANSIT_IN_LIST_NAME} seq 3000 permit 0.0.0.0/0 ge 8 le 24" >> $TMP

	bgpq4 -6 -s -A -l "$TRANSIT_IN_LIST_NAME" -R 128 "${SELF_OBJ}" | sed 's/permit/deny/' >> $TMP
	echo "ipv6 prefix-list ${TRANSIT_IN_LIST_NAME} seq 2010 deny ::/0 le 7" >> $TMP
	echo "ipv6 prefix-list ${TRANSIT_IN_LIST_NAME} seq 2020 deny fc00::/7 ge 7" >> $TMP
	echo "ipv6 prefix-list ${TRANSIT_IN_LIST_NAME} seq 2030 deny fe80::/10 ge 10" >> $TMP
	echo "ipv6 prefix-list ${TRANSIT_IN_LIST_NAME} seq 2040 deny ::/128" >> $TMP
	echo "ipv6 prefix-list ${TRANSIT_IN_LIST_NAME} seq 2050 deny ::1/128" >> $TMP
	echo "ipv6 prefix-list ${TRANSIT_IN_LIST_NAME} seq 2060 deny 100::/64 ge 64" >> $TMP
	echo "ipv6 prefix-list ${TRANSIT_IN_LIST_NAME} seq 2070 deny ff00::/8 ge 8" >> $TMP
	echo "ipv6 prefix-list ${TRANSIT_IN_LIST_NAME} seq 2080 deny 2001:db8::/32 ge 32" >> $TMP
	echo "ipv6 prefix-list ${TRANSIT_IN_LIST_NAME} seq 3000 permit ::/0 ge 8 le 48" >> $TMP

	echo >> $TMP
	echo 'end' >> $TMP
	echo 'write memory' >> $TMP
	cat $TMP
}


if [ "$1" = "frr-update" ] ; then
	gen_filters | vtysh
else
	gen_filters
fi

