#!/bin/bash
# Arch Linux Custom Install Script with LUKS/LVM Encryption
# For UEFI systems with systemd-boot

# Configuration - Customize these variables
HOSTNAME="chernobyl"
USERNAME="plutonium"
TIMEZONE="Asia/Kolkata"
LOCALE="en_US.UTF-8"
KEYMAP="us"
EFI_SIZE="1G"
CRYPT_DEVICE_NAME="reich"
VG_NAME="land"
INSTALL_PKGS="base base-devel linux linux-firmware lvm2 iwd"


# Disk selection
select_disk() {
    echo "Available disks:"
    lsblk -d -p -n -l -o NAME,SIZE
    read -p "Enter disk to install to (e.g., /dev/sda or /dev/nvme0n1): " DISK
    if [ ! -b "$DISK" ]; then
        echo "Error: $DISK is not a valid block device"
        exit 1
    fi
    BOOT_PARTITION="${DISK}1"
    LVM_PARTITION="${DISK}2"
}

# Partitioning with fdisk
partition_disk() {
    echo "Partitioning $DISK..."
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary fat32 1MiB "$EFI_SIZE"
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" mkpart primary ext4 "$EFI_SIZE" 100%
    parted -s "$DISK" set 2 lvm on

    # Verify partitions
    echo "New partition table:"
    parted -s "$DISK" print
}

# Encryption setup
setup_encryption() {
    echo "Setting up LUKS encryption on $LVM_PARTITION..."
    cryptsetup luksFormat "$LVM_PARTITION"
    cryptsetup open "$LVM_PARTITION" "$CRYPT_DEVICE_NAME"
}

# LVM configuration
setup_lvm() {
    echo "Configuring LVM..."
    pvcreate "/dev/mapper/$CRYPT_DEVICE_NAME"
    vgcreate "$VG_NAME" "/dev/mapper/$CRYPT_DEVICE_NAME"

    # Create logical volumes
    lvcreate -l 100%FREE -n root "$VG_NAME"

    # Verify LVs
    echo "Logical volumes created:"
    lvs
}

# Format filesystems
format_filesystems() {
    echo "Formatting filesystems..."

    # EFI partition
    mkfs.fat -F32 "$BOOT_PARTITION"

    # Format root LV
    mkfs.ext4 "/dev/$VG_NAME/root"

    # Reduce root logical volume by 256M to reserve space for e2scrub snapshots
    echo "Reserving space for e2scrub snapshots..."
    lvreduce -L -256M --resizefs "/dev/$VG_NAME/root" -y
}


# Mount filesystems
mount_filesystems() {
    echo "Mounting filesystems..."
    mount "/dev/$VG_NAME/root" /mnt
    mkdir -p /mnt/boot
    mount "$BOOT_PARTITION" /mnt/boot

    echo "Mounted filesystems:"
    lsblk
}

# Install system
install_system() {
    echo "Installing base system..."
    pacstrap /mnt $INSTALL_PKGS

    # ========================================================================
    # CHANGED: More robust microcode detection and installation
    # ========================================================================
    MICROCODE=""
    if lscpu | grep -qi "GenuineIntel"; then
        MICROCODE="intel-ucode"
    elif lscpu | grep -qi "AuthenticAMD"; then
        MICROCODE="amd-ucode"
    fi

    if [ -n "$MICROCODE" ]; then
        echo "Installing $MICROCODE..."
        arch-chroot /mnt pacman -S --noconfirm $MICROCODE
        # Record LUKS UUID for later use in bootloader config
        LUKS_UUID=$(blkid -s UUID -o value $LVM_PARTITION)
        echo $LUKS_UUID > /mnt/root/luks_uuid
    fi

    echo "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
}

# Chroot configuration
configure_system() {
    echo "Configuring system in chroot..."
    arch-chroot /mnt /bin/bash <<EOF
    # Time configuration
    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    hwclock --systohc

    # ========================================================================
    # CHANGED: Precise locale configuration targeting exact line format
    # ========================================================================
    # Uncomment the exact locale line (en_US.UTF-8 UTF-8)
    echo "Uncommenting $LOCALE UTF-8 in locale.gen..."
    sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen

    # Generate locales
    echo "Generating locales..."
    locale-gen

    # Set system locale
    echo "Setting system locale to $LOCALE..."
    echo "LANG=$LOCALE" > /etc/locale.conf

    # Keyboard configuration
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

    # ========================================================================
    # CHANGED: Font verification and installation
    # ========================================================================
    echo "Verifying console font..."
    if [ -f "/usr/share/kbd/consolefonts/latarcyrheb-sun32.psfu.gz" ]; then
        echo "FONT=latarcyrheb-sun32" >> /etc/vconsole.conf
    else
        echo "WARNING: Console font not found, installing terminus-font..."
        pacman -S --noconfirm terminus-font
        echo "FONT=ter-132n" >> /etc/vconsole.conf
    fi

    # Network configuration
    echo "$HOSTNAME" > /etc/hostname
    echo "127.0.0.1 localhost" >> /etc/hosts
    echo "::1       localhost" >> /etc/hosts
    echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

    # Initramfs configuration
    sed -i 's/^HOOKS=(.*)/HOOKS=(base systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
    mkinitcpio -P

    # Bootloader (systemd-boot)
    bootctl install
    cat <<LOADER > /boot/loader/loader.conf
default arch
timeout 3
console-mode keep
editor no
LOADER

    # Get root UUID
    if [ -f "/root/luks_uuid" ]; then
        ROOT_UUID=\$(cat /root/luks_uuid)
        rm /root/luks_uuid
    else
        ROOT_UUID=\$(blkid -s UUID -o value $LVM_PARTITION)
    fi

    # ========================================================================
    # CHANGED: Dynamic microcode initrd handling
    # ========================================================================
    # Create boot entry
    {
        echo "title Arch Linux"
        echo "linux /vmlinuz-linux"

        # Add microcode initrd if installed
        if [ -f "/boot/intel-ucode.img" ]; then
            echo "initrd /intel-ucode.img"
        elif [ -f "/boot/amd-ucode.img" ]; then
            echo "initrd /amd-ucode.img"
        fi

        echo "initrd /initramfs-linux.img"
        echo "options rd.luks.name=\$ROOT_UUID=$CRYPT_DEVICE_NAME root=/dev/$VG_NAME/root rw"
    } > /boot/loader/entries/arch.conf

    # Enable system services
    systemctl enable systemd-networkd.service
    systemctl enable systemd-resolved.service
    systemctl enable iwd.service

    # Create user
    useradd -m -G wheel "$USERNAME"
    echo "Set password for $USERNAME:"
    passwd "$USERNAME"

    # Configure sudo
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

    # Set root password
    echo "Set root password:"
    passwd
EOF
}

# Final steps
finalize() {
    echo "Installation complete!"
    echo "You can now reboot with:"
    echo "   umount -R /mnt"
    echo "   reboot"
    echo "Remember to remove installation media."
}

# Main installation process
main() {
    set -e  # Exit on error
    select_disk
    partition_disk
    setup_encryption
    setup_lvm
    format_filesystems
    mount_filesystems
    install_system
    configure_system
    finalize
}

# Run main function
main