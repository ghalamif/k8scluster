#!/bin/bash

VM_COUNT=2
VM_PREFIX="vm-"
NETWORK_NAME="custom-net"
NETWORK_XML="custom-network.xml"
CLOUD_INIT_ISO="cloud-init.iso"

# Predefined settings
PASSWORD="abcd"  # Set the desired password
HOSTNAME_PREFIX="vmhost"
IP_POOL=("192.168.100.100" "192.168.100.101" "192.168.100.102" "192.168.100.103" "192.168.100.104" "192.168.100.105")
NETMASK="255.255.255.0"
GATEWAY="192.168.100.1"
DNS_SERVERS="8.8.8.8,8.8.4.4"
PACKAGES=("vim" "git" "curl" "htop" "python3-pip")
USE_DHCP=true  # Default to using DHCP

function create_cloud_init_iso {
    local STATIC_IP=$1

    cat > user-data <<EOF
#cloud-config
growpart:
  mode: auto
  devices: ['/']
ssh_pwauth: false
users:
- name: ansible
  gecos: Ansible User
  groups: users,admin,wheel
  sudo: ALL=(ALL) NOPASSWD:ALL
  shell: /bin/bash
  lock_passwd: true
  ssh_authorized_keys:
    - "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCrZ/lXJ85Qx8PuYz+iO6r6lS3WkNfJN1m/9qmPcQnA/9FJ7d5XmrTaruNg595eLTKcHBsQMKehRYhOuAn7a/PD6BzetME20RM/s6XOhjJphzLK3uFzGWjscJSLHlndT8arDny2tRxVrIUfM/gJI+p88I7jaS//Q2FOleiHHQDwvKVlfQCBrOa+oW9GlA+ir6gRJxXy/Qnfh8Y1o1jd05lStWLdhT6rtqo597K1aoLhXUNY5BvbJ508aB+SMR1rIShyy1bPahv/yNUhHEvYSIEfOcV+uj8taUgJ6yRX47+Bls5G+fVWoZDDYBxSf9opN0ZoPWjj4vF6QWOqtkmBiLavJvO0yD6FrlRwmBgdWPQLvu96NfeIaoHidFP5pn9smui++UwXvqeypEm//y7eAgEvRDQR0gw/VT18bOx2CwhDHLFo6uymfqiyDNmCk37I7v5TCTybv2R0TRvdjsfsV3R8K6Yr1dd6BHYhknhww1T/BDmRZsvFJS92+Oc0zfJ4OxWrGRYdox/H5naJAX3T7YaCnkye3R7qVuG3OgWPijDWEZYds9b16kLBAGetMuSz7xAEWk47zqnBhf4bwWKDhxhJwlWnvqKFCoD5bx44ymbY2yJwzYJX0ja0odHY0q1+ehjaYxedNbGcyzEv8beDvJa9+chW4JsIjkSngwtsn03EvQ== faps@example.com"
packages:
  - ${PACKAGES[@]}
runcmd:
  - apt update
  - snap install kubectl --classic
  - snap install kubectx --classic
  - sudo apt install python3-pip -y

  - sudo apt update
  - sudo apt upgrade

EOF


    if [ "$USE_DHCP" = true ]; then
        cat > network-config <<EOF
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: true
EOF
    else
        cat > network-config <<EOF
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: false
      addresses:
        - $STATIC_IP/24
      gateway4: $GATEWAY
      nameservers:
        addresses: [$DNS_SERVERS]
EOF
    fi

    cat > meta-data <<EOF
instance-id: iid-local01
local-hostname: $HOSTNAME
EOF

    sudo genisoimage -input-charset utf-8 -output $CLOUD_INIT_ISO -volid cidata -joliet -rock user-data meta-data network-config
}


    cat > $NETWORK_XML <<EOF
<network>
  <name>custom-net</name>
  <forward mode="nat"/>
  <bridge name="virbr1" stp="on" delay="0"/>
  <ip address="192.168.100.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.100.2" end="192.168.100.254"/>
    </dhcp>
  </ip>
</network>
EOF

function create_network {
    # Define and start the network if not already active
    if ! sudo virsh net-info $NETWORK_NAME &>/dev/null; then
        sudo virsh net-define $NETWORK_XML
        sudo virsh net-start $NETWORK_NAME
        sudo virsh net-autostart $NETWORK_NAME
    fi
}

function destroy_network {
    # Destroy and undefine the network
    rm user-data meta-data cloud-init.iso network-config $NETWORK_XML
    sudo virsh net-destroy $NETWORK_NAME 2>/dev/null
    sudo virsh net-undefine $NETWORK_NAME 2>/dev/null
}

function destroy {
    for i in $(seq 1 $VM_COUNT); do
        VM_NAME="${VM_PREFIX}${i}"
        DISK_IMAGE="disk-${VM_NAME}.qcow2"
        
        echo "Cleaning up VM $VM_NAME..."
        
        # Destroy the VM if it's running
        sudo virsh destroy $VM_NAME 2>/dev/null
        
        # Undefine the VM to remove its configuration
        sudo virsh undefine $VM_NAME 2>/dev/null
        
        # Remove the disk image
        rm -f $DISK_IMAGE
    done
    
    # Destroy the network
    destroy_network
}

function create {
    create_network

    for i in $(seq 1 $VM_COUNT); do
        VM_NAME="${VM_PREFIX}${i}"
        STATIC_IP=${IP_POOL[$((i-1))]}
        echo "Creating VM $VM_NAME with IP $STATIC_IP..."

        create_cloud_init_iso $STATIC_IP 
        
        # Create a unique disk image for each VM
        DISK_IMAGE="disk-${VM_NAME}.qcow2"

        cp jammy-server-cloudimg-amd64.img $DISK_IMAGE
        sudo qemu-img resize disk-${VM_NAME}.qcow2 10G

        sudo virt-install \
            --name $VM_NAME \
            --ram 2048 \
            --vcpus 2 \
            --os-type linux \
            --os-variant ubuntu20.04 \
            --virt-type kvm \
            --disk path=$DISK_IMAGE,format=qcow2,bus=virtio \
            --disk path=$CLOUD_INIT_ISO,device=cdrom \
            --import \
            --network network=$NETWORK_NAME,model=virtio \
            --graphics none \
            --noautoconsole

        # Check VM status
        sudo virsh dominfo $VM_NAME
    done
}

function ips {
    VM_IPS=()
    for i in $(seq 1 $VM_COUNT); do
        VM_NAME="${VM_PREFIX}${i}"
        IP_ADDRESS=$(sudo virsh domifaddr $VM_NAME | grep -oP '(\d{1,3}\.){3}\d{1,3}')
        VM_IPS+=("$IP_ADDRESS")
    done
    echo "${VM_IPS[@]}"
}

function get_mac_addresses {
    VM_MACS=()
    for i in $(seq 1 $VM_COUNT); do
        VM_NAME="${VM_PREFIX}${i}"
        MAC_ADDRESS=$(sudo virsh domiflist $VM_NAME | grep -oP '(\w{2}:){5}\w{2}')
        VM_MACS+=("$MAC_ADDRESS")
    done
    echo "${VM_MACS[@]}"
}

function list_ips {
    for i in $(seq 1 $VM_COUNT); do
        VM_NAME="${VM_PREFIX}${i}"
        echo "IP addresses for $VM_NAME:"
        sudo virsh domifaddr $VM_NAME
    done
}

function list {
    # List the VMs
    sudo virsh list --all
}

if [ "$1" == "destroy" ]; then
    destroy
elif [ "$1" == "create" ]; then
    if [ "$2" == "--static" ]; then
        USE_DHCP=false
    fi
    create
elif [ "$1" == "ips" ]; then
    list_ips
elif [ "$1" == "list" ]; then
    list
elif [ "$1" == "ip" ]; then
    ips
elif [ "$1" == "mac" ]; then
    get_mac_addresses
else
    echo "Usage: $0 {create [--static]|destroy|list|list-ips}"
fi
