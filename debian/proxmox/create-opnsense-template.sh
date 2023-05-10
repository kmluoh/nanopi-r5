#!/bin/bash
set -xe
STORAGE='r5s-nvme'
IMAGE_FILE='OPNsense-202304192114-vm-aarch64.qcow2'
TEMPLATE_ID='9200'
TEMPLATE_NAME='opnsense-template'
VM_ID='920'
VM_NAME='opnsense-vm'

qm create $TEMPLATE_ID --name $TEMPLATE_NAME --cpu host --core 2 --memory 2048 --net0 virtio,bridge=vmbr0,firewall=1 --net1 virtio,bridge=vmbr1,firewall=1 --bios ovmf --sockets 1 --numa 0
qm set $TEMPLATE_ID -efidisk0 $STORAGE:0,format=raw,efitype=4m,pre-enrolled-keys=1
qm importdisk $TEMPLATE_ID $IMAGE_FILE $STORAGE
qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$TEMPLATE_ID-disk-1
qm set $TEMPLATE_ID --boot order=scsi0
qm set $TEMPLATE_ID --serial0 socket --vga serial0
qm template $TEMPLATE_ID
qm clone $TEMPLATE_ID $VM_ID --name $VM_NAME --full true
