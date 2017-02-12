#!/bin/bash
PATH=/usr/bin:/sbin:/bin

# usage: update-ipset.sh <configuration file>
# eg: /root/scripts/update-ipset.sh /root/ipset/blacklist.conf



# PREFLIGHT ERROR CHECKS
#=======================================================================================
# Error if no config file passed to update-ipset.sh
if [[ -z "$1" ]]; then
    echo "Error: please specify a configuration file, e.g. $0 /root/ipset/blacklist.conf"
    exit 1
fi

# Error if bad config file.
# Also sets source to config file. This line is required for script to work.
if ! source "$1"; then
    echo "Error: can't load configuration file $1"
    exit 1
fi

# Check for required executables.
for i in curl ipset iprange;
do
    if ! which "$i" &> /dev/null; then
        echo >&2 "Error: searching PATH fails to find "$i" executable"
        quit="yes"
    fi
done
if [ "$quit" = "yes" ]; then
    exit 1
fi

SET_PATH="${SET_DIR}/${SET_NAME}"

# Make the ipset directory if it doesn't exist.
mkdir -p -m 0700 ${SET_DIR}



# EXTRACT_ARRAY FUNCTION
#==========================================================================================
# Downloads array of ip addresses into $CURL_TMP
# Cleans them of comments and incorrect leading octets
# Extracts ip's and saves in specified TMP file

extract_array() {
    local x="$1[@]"
    for i in "${!x}"
    do
    CURL_TMP=$(mktemp) #Temporary file for downloaded ip addresses
    let HTTP_RC=`curl -L -A "Mozilla/4.0" --connect-timeout 10 --max-time 10 -o $CURL_TMP -s -w "%{http_code}" "$i"`
    if (( $HTTP_RC == 200 || $HTTP_RC == 302 || $HTTP_RC == 0 )); then  # Successful http status codes. "0" because file:/// returns 000
        sed 's/#.*//; s/;.*//' "$CURL_TMP" |  # Remove comments "# ;" to minimize importing incorrect addresses.
        grep -Po '\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b' |  # Extract ip addresses.
        awk -F '.' '$1 < 256' |  # Remove any address with first octet higher than 255. Quotes must be '$1 < 256' because $1 is first awk field.
        sed '/^0/d' >> "$2"  # Remove any address starting with a zero.
     else
        echo >&2 -e "\nWarning: curl returned HTTP response code $HTTP_RC for URL $i"
    fi
    rm -f "$CURL_TMP"
done
}



# BASE LIST
#=====================================================================================
BASE_TMP=$(mktemp) #Temporary file for ipset
extract_array BASE_ARRAY "${BASE_TMP}"

cat $BASE_TMP > "${SET_DIR}/.${SET_NAME}-raw" # Save hidden .iplist-raw file



# EXCLUDE LIST
#======================================================================================
EXCLUDE_TMP=$(mktemp) #Temporary file for ipset
extract_array EXCLUDE_ARRAY "${EXCLUDE_TMP}"


# Append protected list to EXCLUDE LIST if AUTO_PROTECT=yes
if [[ ${AUTO_PROTECT:-yes} == yes ]]; then

    PUBLIC_IP=`wget -qO - http://ipinfo.io/ip`

    cat >> "$EXCLUDE_TMP" <<EOF
    #Protect LAN Connections
    10.0.0.0/8
    172.16.0.0/12
    192.168.0.0/16
    127.0.0.0/8

    #Public IP address
    ${PUBLIC_IP}
EOF
fi

## Old Method
# Append protected list to whitelist
#PUBLIC_IP=`wget -qO - http://ipinfo.io/ip`

#cat >> "$WHITELIST_TMP" <<EOF
#Protect LAN Connections
#10.0.0.0/8
#172.16.0.0/12
#192.168.0.0/16
#127.0.0.0/8

#Public IP address
#${PUBLIC_IP}
#EOF



# MATCH LIST
#======================================================================================
MATCH_TMP=$(mktemp) #Temporary file for ipset
extract_array MATCH_ARRAY "${MATCH_TMP}"



# IPRANGE OPTIMIZTION
#======================================================================================
IPLIST_TMP1=$(mktemp)
IPLIST_TMP2=$(mktemp)
HINGE_TMP=$(mktemp)

iprange ${BASE_TMP} --except $EXCLUDE_TMP | tee ${IPLIST_TMP1} ${IPLIST_TMP2} >/dev/null

if [ -s $MATCH_TMP ]  # If file is not zero size.
    then
    iprange ${IPLIST_TMP1} --common $MATCH_TMP > $IPLIST_TMP2
    # iprange ${IPLIST_TMP1} --except $MATCH_TMP > $HINGE_TMP
    # iprange ${IPLIST_TMP1} --except $HINGE_TMP > $IPLIST_TMP2
fi

iprange --ipset-reduce 0 --ipset-reduce-entries 100000 "$IPLIST_TMP2" > "${SET_PATH}.list"

rm "$IPLIST_TMP1" "$IPLIST_TMP2" "$BASE_TMP" "$EXCLUDE_TMP" "$MATCH_TMP"



# CREATE IPSET
#======================================================================================
# Exit without modifying existing ipsets if new list is zero size.
if [ ! -s "${SET_PATH}.list" ]; then  # If file is zero size.
    echo "Error: "${SET_PATH}.list" is empty. Check config file for URLs. Downloads may have failed. ${SET_NAME} ipset will not be created or modified"
    exit 1
fi

# Use wc to get the number of addresses in the list and set to maxelem.
MAXELEM=`wc -l < "${SET_PATH}.list"`
#MAXELEM=$((`wc -l < "${SET_PATH}.list"` + 50)) #Added 50 to this for buffer.

# Create the ipset if it doesn't exist.
if ! ipset list -n | grep -xq "${SET_NAME}"; then
    ipset create "${SET_NAME}" hash:net family inet maxelem "$MAXELEM"
fi

# Delete ipset-tmp if it exists from being orphaned during a failed restore.   
if ipset list -n | grep -xq "${SET_NAME}-tmp"; then
    ipset destroy "${SET_NAME}-tmp"
fi



# UPDATE IPSET WHILE IT IS LIVE
#=============================================================================================
IPSET_TMP=$(mktemp)
cat > "$IPSET_TMP" <<EOF
create "${SET_NAME}-tmp" hash:net family inet maxelem "$MAXELEM"
EOF

# Add every address from .list file to $IPSET_TMP
sed 's|^|add '${SET_NAME}-tmp' |' ${SET_PATH}.list >> "$IPSET_TMP"

# Add restore & destroy instructions to .restore file
# Swaps the names of the -tmp ipset and the actual ipset.
cat >> "$IPSET_TMP" <<EOF
swap "${SET_NAME}" "${SET_NAME}-tmp"
destroy "${SET_NAME}-tmp"
EOF

ipset -file "$IPSET_TMP" restore

rm "$IPSET_TMP"



# CREATE .restore FILE FOR USE AFTER REBOOT BY /etc/network/interfaces
#===============================================================================================
cat > "${SET_PATH}.restore" <<EOF
create ${SET_NAME} hash:net family inet maxelem "$MAXELEM"
EOF

# Add every address from .list file to .restore file appending "add <ipset_name>"
sed 's|^|add '${SET_NAME}' |' ${SET_PATH}.list >> ${SET_PATH}.restore

# Fix to only change files and not directories.
find ${SET_DIR} -type f -exec chmod 0600 {} +

