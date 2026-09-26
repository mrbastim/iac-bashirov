ssh-keygen -t ed25519 -C "bashirov-04"
cat ~/.ssh/id_ed25519.pub

curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
exec -l $SHELL
yc version
yc init

sudo apt install -y jq
export PREFIX=bashirov-04
yc iam service-account create --name "$PREFIX-sa"
export FOLDER_ID=$(yc config get folder-id)
export SA_ID=$(yc iam service-account get --name "$PREFIX-sa" --format json | jq -r .id)
yc resource-manager folder add-access-binding "$FOLDER_ID" --role editor --subject "serviceAccount:$SA_ID"


mkdir -p ~/.yc-keys
yc iam key create --service-account-name "$PREFIX-sa" --output ~/.yc-keys/$PREFIX-key.json

export ZONE=ru-central1-d
export CIDR=10.14.1.0/24
export DISK_SIZE=15

yc vpc network create --name "$PREFIX-net"
yc vpc subnet create --name "$PREFIX-subnet" --network-name "$PREFIX-net" --zone "$ZONE" --range "$CIDR"

yc compute instance create \
  --name "$PREFIX-web-1" \
  --zone "$ZONE" \
  --platform standard-v3 \
  --cores=2 \
  --core-fraction=20 \
  --memory=2 \
  --preemptible \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2404-lts,type=network-hdd,size="$DISK_SIZE" \
  --network-interface subnet-name="$PREFIX-subnet",nat-ip-version=ipv4 \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --labels created-by=cli


export VM_IP=$(yc compute instance get "$PREFIX-web-1" --format json | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address')
ssh yc-user@"$VM_IP"

yc compute instance delete "$PREFIX-web-1"
yc compute instance delete "$PREFIX-web-manual"
yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"
