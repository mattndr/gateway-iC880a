#!/bin/bash

# Stop on the first sign of trouble
set -e

if [ $UID != 0 ]; then
    echo "ERROR: Operation not permitted. Forgot sudo?"
    exit 1
fi

VERSION="spi"
if [[ $1 != "" ]]; then VERSION=$1; fi

echo "ResIOT installer - $VERSION Version"

# Request gateway configuration data
# There are two ways to do it, manually specify everything
# or rely on the gateway EUI and retrieve settings files from remote (recommended)
echo "Gateway configuration:"

# Try to get gateway ID from MAC address
# First try eth0, if that does not exist, try wlan0 (for RPi Zero)
GATEWAY_EUI_NIC="eth0"
if [[ `grep "$GATEWAY_EUI_NIC" /proc/net/dev` == "" ]]; then
    GATEWAY_EUI_NIC="wlan0"
fi

if [[ `grep "$GATEWAY_EUI_NIC" /proc/net/dev` == "" ]]; then
    echo "ERROR: No network interface found. Cannot set gateway ID."
    exit 1
fi

GATEWAY_EUI=$(ip link show $GATEWAY_EUI_NIC | awk '/ether/ {print $2}' | awk -F\: '{print $1$2$3"FFFE"$4$5$6}')
GATEWAY_EUI=${GATEWAY_EUI^^} # toupper

echo "Detected EUI $GATEWAY_EUI from $GATEWAY_EUI_NIC"

printf "Host name [lora-gateway-1]:"
read NEW_HOSTNAME
if [[ $NEW_HOSTNAME == "" ]]; then NEW_HOSTNAME="lora-gateway-1"; fi

printf "Descriptive name [resiot-ic880a]:"
read GATEWAY_NAME
if [[ $GATEWAY_NAME == "" ]]; then GATEWAY_NAME="resiot-ic880a"; fi

printf "Contact email: "
read GATEWAY_EMAIL

printf "Latitude [0]: "
read GATEWAY_LAT
if [[ $GATEWAY_LAT == "" ]]; then GATEWAY_LAT=0; fi

printf "Longitude [0]: "
read GATEWAY_LON
if [[ $GATEWAY_LON == "" ]]; then GATEWAY_LON=0; fi

printf "Altitude [0]: "
read GATEWAY_ALT
if [[ $GATEWAY_ALT == "" ]]; then GATEWAY_ALT=0; fi

# Change hostname if needed
CURRENT_HOSTNAME=$(hostname)

if [[ $NEW_HOSTNAME != $CURRENT_HOSTNAME ]]; then
    echo "Updating hostname to '$NEW_HOSTNAME'..."
    hostname $NEW_HOSTNAME
    echo $NEW_HOSTNAME > /etc/hostname
    sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/" /etc/hosts
fi

# Install LoRaWAN packet forwarder repositories
INSTALL_DIR="/opt/resiot-gateway"
if [ ! -d "$INSTALL_DIR" ]; then mkdir $INSTALL_DIR; fi
pushd $INSTALL_DIR

# Remove WiringPi built from source (older installer versions)
if [ -d wiringPi ]; then
    pushd wiringPi
    ./build uninstall
    popd
    rm -rf wiringPi
fi 

# Build LoRa gateway app
if [ ! -d lora_gateway ]; then
    #git clone https://github.com/resiot/lora_gateway
    git clone https://github.com/Lora-net/lora_gateway
    pushd lora_gateway
else
    pushd lora_gateway
    git pull
    git reset --hard
fi

sed -i -e 's/PLATFORM= kerlink/PLATFORM= imst_rpi/g' ./libloragw/library.cfg

make

popd

# Build packet forwarder
if [ ! -d packet_forwarder ]; then
    git clone https://github.com/Lora-net/packet_forwarder
    pushd packet_forwarder
else
    pushd packet_forwarder
    git pull
    git reset --hard
fi

make

popd

# Symlink poly packet forwarder
if [ ! -d bin ]; then mkdir bin; fi
if [ -f ./bin/lora_pkt_fwd ]; then rm ./bin/lora_pkt_fwd; fi
ln -s $INSTALL_DIR/packet_forwarder/lora_pkt_fwd/lora_pkt_fwd ./bin/resiot_pkt_fwd

LOCAL_CONFIG_FILE=$INSTALL_DIR/bin/local_conf.json

# Remove old config file
if [ -e $LOCAL_CONFIG_FILE ]; then rm $LOCAL_CONFIG_FILE; fi;

echo -e "{\n\t\"gateway_conf\": {\n\t\t\"gateway_ID\": \"$GATEWAY_EUI\",\n\t\t\"servers\": [ { \"server_address\": \"eu72udp.resiot.io\", \"serv_port_up\": 7677, \"serv_port_down\": 7677, \"serv_enabled\": true } ],\n\t\t\"ref_latitude\": $GATEWAY_LAT,\n\t\t\"ref_longitude\": $GATEWAY_LON,\n\t\t\"ref_altitude\": $GATEWAY_ALT,\n\t\t\"contact_email\": \"$GATEWAY_EMAIL\",\n\t\t\"description\": \"$GATEWAY_NAME\" \n\t}\n}" >$LOCAL_CONFIG_FILE

popd

echo "Gateway EUI is: $GATEWAY_EUI"
echo "The hostname is: $NEW_HOSTNAME"
echo
echo "Installation completed."

# Start packet forwarder as a service
cp ./start.sh $INSTALL_DIR/bin/
cp ./resiot-gateway.service /lib/systemd/system/
cp ./global_conf.json $INSTALL_DIR/bin/global_conf.json
systemctl enable resiot-gateway.service

echo "The system will reboot in 5 seconds..."
sleep 5
shutdown -r now
