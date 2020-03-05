#!/bin/bash

USAGE="
Usage:
    
vcpe_start <vcpe_name> <vnf_tunnel_ip> <home_tunnel_ip> <vcpe_private_ip> <vcpe_public_ip> <dhcpd_conf_file>
    being:
        <vcpe_name>: the name of the network service instance in OSM 
        <vnf_tunnel_ip>: the ip address for the vnf side of the tunnel
        <home_tunnel_ip>: the ip address for the home side of the tunnel
        <vcpe_private_ip>: the private ip address for the vcpe
        <vcpe_public_ip>: the public ip address for the vcpe (10.2.2.0/24)
        <dhcpd_conf_file>: the dhcp file for the vcpe to give private addresses to the home network
"

if [[ $# -ne 6 ]]; then
        echo ""       
    echo "ERROR: incorrect number of parameters"
    echo "$USAGE"
    exit 1
fi

VNF1="mn.dc1_$1-1-ubuntu-1"
VNF2="mn.dc1_$1-2-ubuntu-1"
VNF3="mn.dc1_$1-3-ubuntu-1"

VNFTUNIP="$2"
HOMETUNIP="$3"
VCPEPRIVIP="$4"
VCPEPUBIP="$5"
DHCPDCONF="$6"

ETH11=`sudo docker exec -it $VNF1 ifconfig | grep eth1 | awk '{print $1}'`
ETH21=`sudo docker exec -it $VNF2 ifconfig | grep eth1 | awk '{print $1}'`
ETH31=`sudo docker exec -it $VNF3 ifconfig | grep eth1 | awk '{print $1}'`
IP11=`sudo docker exec -it $VNF1 hostname -I | awk '{printf "%s\n", $1}{print $2}' | grep 192.168.100`
IP31=`sudo docker exec -it $VNF3 hostname -I | awk '{printf "%s\n", $1}{print $2}' | grep 192.168.100`
prov=`sudo docker exec -it mn.dc1_vcpe-1-2-ubuntu-1 ifconfig -a | awk '/192\.168\./ && /inet/{print $2}'`
IP21="${prov:5:14}"


echo $IP11
echo $IP21
echo $IP31
##################### VNFs Settings #####################
## 0. Iniciar el Servicio OpenVirtualSwitch en cada VNF:
echo "--"
echo "--OVS Starting..."
sudo docker exec -it $VNF1 /usr/share/openvswitch/scripts/ovs-ctl start
sudo docker exec -it $VNF2 /usr/share/openvswitch/scripts/ovs-ctl start
sudo docker exec -it $VNF3 /usr/share/openvswitch/scripts/ovs-ctl start

echo "--"
echo "--Connecting vCPE service with AccessNet and ExtNet..."

sudo ovs-docker add-port AccessNet veth0 $VNF1
sudo ovs-docker add-port ExtNet veth0 $VNF3

echo "--"
echo "--Setting VNF..."
echo "--"
echo "--Bridge Creating..."

## 1. En VNF:vclass agregar un bridge y asociar interfaces.
sudo docker exec -it $VNF1 ovs-vsctl add-br br0
sudo docker exec -it $VNF1 ifconfig veth0 $VNFTUNIP/24
sudo docker exec -it $VNF1 ovs-vsctl add-port br0 vxlan1 -- set interface vxlan1 type=vxlan options:remote_ip=$HOMETUNIP
sudo docker exec -it $VNF1 ovs-vsctl add-port br0 vxlan2 -- set interface vxlan2 type=vxlan options:remote_ip=$IP21
echo "OKEY"
echo ""
echo ""
## 2. En VNF:vcpe agregar un bridge y asociar interfaces.
sudo docker exec -it $VNF2 ovs-vsctl add-br br1
#sudo docker exec -it $VNF2 /sbin/ifconfig br1 $VCPEPRIVIP/24
sudo docker exec -it $VNF2 ovs-vsctl add-port br1 vxlan1 -- set interface vxlan1 type=vxlan options:remote_ip=$IP11
sudo docker exec -it $VNF2 ovs-vsctl add-port br1 vxlan2 -- set interface vxlan2 type=vxlan options:remote_ip=$IP31
sudo docker exec -it $VNF2 ifconfig br1 mtu 1400
echo "OKEY2"
## 2. En VNF:vcpe agregar un bridge y asociar interfaces.
sudo docker exec -it $VNF3 ovs-vsctl add-br br2
sudo docker exec -it $VNF3 /sbin/ifconfig br2 $VCPEPRIVIP/24
sudo docker exec -it $VNF3 ovs-vsctl add-port br2 vxlan1 -- set interface vxlan1 type=vxlan options:remote_ip=$IP21
sudo docker exec -it $VNF3 ifconfig br2 mtu 1400
echo "OKEY3"
## 3. En VNF:vcpe asignar dirección IP a interfaz de salida.
sudo docker exec -it $VNF3 /sbin/ifconfig veth0 $VCPEPUBIP/24
echo "1"
sudo docker exec -it $VNF3 ip route del 0.0.0.0/0 via 172.17.0.1
echo "2"
sudo docker exec -it $VNF3 ip route add 0.0.0.0/0 via 10.2.3.254
echo "OKEY ULTIMO"
## 4. Iniciar Servidor DHCP 
echo "--"
echo "--DHCP Server Starting..."
if [ -f "$DHCPDCONF" ]; then
    echo "--Using $DHCPDCONF for DHCP"
    docker cp $DHCPDCONF $VNF3:/etc/dhcp/dhcpd.conf
else
    echo "--$DHCPCONF not found for DHCP, the container will use the default"
fi
sudo docker exec -it $VNF3 service isc-dhcp-server restart
sleep 30

## 5. En VNF:vcpe activar NAT para dar salida a Internet 
docker cp /usr/bin/vnx_config_nat  $VNF3:/usr/bin
sudo docker exec -it $VNF3 /usr/bin/vnx_config_nat br2 veth0

sudo docker exec -it $VNF3 iptables -A FORWARD -p tcp -d $IP21 --dport 8123 -j ACCEPT
sudo docker exec -it $VNF3 iptables -A FORWARD -p tcp -s $IP21 --sport 8123 -j ACCEPT

sudo docker exec -it $VNF3 iptables -A PREROUTING -t nat -p tcp -d 10.2.3.1 --dport 8123 -j DNAT --to-destination $IP21:8123
sudo docker exec -it $VNF3 iptables -A POSTROUTING -t nat -p tcp -d $IP21 --dport 8123 -j SNAT --to-source 10.2.3.254

