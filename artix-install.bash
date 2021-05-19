#!/bin/bash

set -u

shopt -s extglob globstar nullglob

function escape {
	for a in "$@"; do
		printf '%s\n' "${a@Q}"
	done
}

function unescape {
	for a in "$@"; do
		eval "cat <<< $a"
	done
}

efivar -l >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
	bios='uefi'
else
	bios='legacy'
fi

pacman -Sy --noconfirm fzy jq gptfdisk parted

clear

fdisk -l

block_devices=()

for f in /dev/**/*; do
	if [[ -b "$f" ]]; then
		block_devices+=("$f")
	fi
done

block_device=$(
	unescape "$(
		for dev in "${block_devices[@]}"; do
			printf '%s\n' "$(escape "$dev")"
		done | fzy -p 'enter block device (e.g. /dev/sda)> '
	)"
)

clear

if [[ $bios == 'uefi' ]]; then
	read -r -e -p 'enter bootloader id> ' bootloader_id
fi

clear

read -r -e -p 'enter hostname> ' hostname
read -r -e -p 'enter username> ' username
while true; do
	read -r -s -p 'enter password> ' password
	printf '\n'
	read -r -s -p 're-enter password> ' repassword
	printf '\n'
	if [[ $password == "$repassword" ]]; then
		hashed_password=$(openssl passwd -1 -stdin <<< "$password")
		break
	fi
	clear
done

sgdisk --zap-all "$block_device"

case "$bios" in
	'uefi')
		# efi part
		sgdisk --new=1:0:+512M "$block_device"
		# root
		sgdisk --new=2:0:0 "$block_device"
		;;
	'legacy')
		# root
		parted "$block_device" mklabel msdos mkpart primary 0% 100%
		;;
esac

partitions=()
query=$(sfdisk -J "$block_device")
for k in $(jq '.partitiontable.partitions | keys | .[]' <<< "$query"); do
	partitions+=("$(jq --argjson k "$k" -r '.partitiontable.partitions | .[$k] | .node' <<< "$query")")
done

case "$bios" in
	'uefi')
		efi_fs="${partitions[0]}"
		root_fs="${partitions[1]}"
		yes | mkfs.fat -F32 "$efi_fs"
		yes | mkfs.ext4 "$root_fs"
		;;
	'legacy')
		root_fs="${partitions[0]}"
		yes | mkfs.ext4 "$root_fs"
		;;
esac

mount "$root_fs" /mnt

if [[ $bios == 'uefi' ]]; then
	mkdir -p /mnt/boot/efi
	mount "$efi_fs" /mnt/boot/efi
fi

packages=(
	base
	base-devel
	linux
	linux-firmware
	linux-headers
	runit
	git
	elogind-runit
	mkinitcpio
	libeudev
	eudev
	networkmanager
	networkmanager-runit
	neovim
	grub
	sudo
	efibootmgr
	xdg-utils
	xdg-user-dirs
)

basestrap /mnt "${packages[@]}"

fstabgen -U /mnt >> /mnt/etc/fstab

for d in etc/locale.gen etc/locale.conf etc/vconsole.conf; do
	cat "/$d" > "/mnt/$d"
done

zone=$(readlink -f /etc/localtime)

export hostname username hashed_password zone bios block_device

if [[ $bios == 'uefi' ]]; then
	export bootloader_id
fi

artix-chroot /mnt /bin/bash <<'EOF'
ln -sf "$zone" /etc/localtime

hwclock --systohc

locale-gen

printf '%s\n' "$hostname" > /etc/hostname

case "$bios" in
	'uefi')
		grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="$bootloader_id"
		;;
	'legacy')
		grub-install --target=i386-pc "$block_device"
		;;
esac

grub-mkconfig -o /boot/grub/grub.cfg

if [[ $bios == 'uefi' ]]; then
	# magic
	mkdir -p /boot/efi/EFI/boot
	cp "/boot/efi/EFI/$bootloader_id/grubx64.efi" /boot/efi/EFI/boot/bootx64.efi
fi

useradd -m -G wheel -p "$hashed_password" "$username"

printf '%s\n' '%wheel ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

home=$(getent passwd "$username" | awk -v RS='' -F ':' '{ print $6 }')
pushd "$home"
git clone https://aur.archlinux.org/yay.git
pushd yay
chown -R "$username:$username" .
runuser -u "$username" -- makepkg -si --noconfirm
popd
popd

sed -i -e '$s/.*/%wheel ALL=(ALL) ALL/' /etc/sudoers
EOF

umount -R /mnt
