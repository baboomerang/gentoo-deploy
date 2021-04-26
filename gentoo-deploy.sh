#!/bin/bash

################################
#
# Gentoo Deploy Script
# Usage: ./gentoo-deploy.sh
#
################################

SCRIPT=`realpath $0`
ROOT_DIR="/mnt/gentoo"
BOOT_DIR="${ROOT_DIR}/boot"
HOME_DIR="${ROOT_DIR}/home"
DISK="/dev/sdx"

TFTP=192.168.0.3
MIRROR="https://bouncer.gentoo.org/fetch/root/all/"
ARCH="amd64"
PLATFORM="amd64"
LOCATION="$MIRROR/releases/$ARCH/autobuilds/current-stage3-${ARCH}/"
FOLDER="20210321"
STAGE3="stage3-$ARCH-$FOLDER.tar.xz"

FSTAB="/etc/fstab"
MAKECONF="/etc/portage/make.conf"
PACKAGEKEYWORDS="/etc/portage/package.keywords"

MAKECFLAGS='-march=native -O3 -pipe'
MAKEOPTS="-j$(expr `nproc` + 1)"
MAKEUSE='-bindist -consolekit -webkit -vulkan -vaapi -vdpau -opencl -bluetooth -kde udev threads alsa pulseaudio mpeg mp3 flac aac lame midi ogg vorbis x264 xvid win32codecs real png jpeg jpeg2k raw gif svg tiff opengl bash bash-completion i3 vim vim-syntax git dbus qt4 cairo gtk unicode fontconfig truetype wifi laptop acpi lm_sensors dvd dvdr cdr cdrom policykit X dhcpcd logrotate python3_7'
MAKEPYTHON='python2_7 python3_7'
MAKEINPUTDEVICES='evdev'
MAKEVIDEOCARDS='intel i965'
MAKELINGUAS='en_US en'

unmount_disk() {
    # Get all mounted partitions other than swap
    mounts=$(lsblk -i -o kname,fstype,mountpoint --noheadings $1 |
             awk 'NF==3 && ($2 != "swap") {print $1,$2,$3}' |
             sort -r -k 3
    )

    # Get swap partitions
    swap_mounts=$(lsblk -i -o kname,fstype --noheadings $1 |
                  awk '$2 == "swap" {print $1}'
    )

    # Unmount partitions
    IFS=$'\n'
    for mounted_part in $mounts; do
        umount -l /dev/$(awk '{print $1}' <<< "$mounted_part")
    done

    # Disable any swap partitions
    for swap_mount in $swap_mounts; do
        swapoff /dev/$(awk '{print $1}' <<< "$swap_mount")
    done
}

install() {
    #######################################################
    #  Prepare the disks for the MBR Gentoo Install
    #      partition target disk
    #      create filesystems in each partition

    # Show all disks for the user
    lsblk

    DISK="/dev/sdX"

    # Prompt user for input and save the input
    read -rp "Which disk should be erased? (i.e. /dev/sdj): " DISK
    echo "WARNING! BLOCK DEVICE: $DISK WILL BE ERASED IN 60 SECONDS..."
    echo "PLEASE MAKE SURE THIS IS THE CORRECT DISK"

    # Print countdown and wait 60 seconds before erasing disk
    for seconds in {5..1}; do
        printf "PRESS CTRL+C TO CANCEL (%2d seconds)\r" ${seconds}
        sleep 1
    done

    unmount_disk "$DISK"

    # Create new partitions and setup for an MBR install
    parted --script $DISK \
        mklabel msdos \
        mkpart primary ext2 0% 1GiB \
        set 1 boot on \
        mkpart primary linux-swap 1GiB 9GiB \
        mkpart primary ext4 9GiB 30GiB \
        mkpart primary ext4 30GiB 100% >&2

    if [ $? -ne 0 ]; then
        echo "Error! Something went wrong while writing partion" >&2
        echo "Disk is in an unknown state. You are on your own" >&2
        exit 1
    fi

    # Make local names for disk partitions
    local boot_dev=${DISK}1
    local swap_dev=${DISK}2
    local root_dev=${DISK}3
    local home_dev=${DISK}4

    # Create the filesystems
    mkfs.ext4 -F "$boot_dev"
    mkswap -f "$swap_dev"
    mkfs.ext4 -F "$root_dev"
    mkfs.ext4 -F "$home_dev"

    #######################################################
    #  Mount the partitions in the proper order
    #      root must be mounted first
    #      then either /boot or /home

    if [[ $(mount "$root_dev" "$ROOT_DIR" >&2) && $(findmnt -M "$ROOT_DIR" >&2) ]]; then
        echo "Error! Cannot mount $root_dev to $ROOT_DIR..." >&2
        exit 1
    fi

    mkdir "$BOOT_DIR"
    mkdir "$HOME_DIR"

    if [[ $(mount "$boot_dev" "$BOOT_DIR" >&2) && $(findmnt -M "$BOOT_DIR" >&2) ]]; then
        echo "Error! Cannot mount $boot_dev to $BOOT_DIR..." >&2
        exit 1
    fi

    if [[ $(mount "$home_dev" "$HOME_DIR" >&2) && $(findmnt -M "$HOME_DIR" >&2) ]]; then
        echo "Error! Cannot mount $home_dev to $HOME_DIR..." >&2
        exit 1
    fi

    if [ $(swapon "$swap_dev" >&2) ]; then
        echo "Error! Failed to activate SWAP partition." >&2
        exit 1
    fi

    #######################################################
    #  Fetch stage3 tarball from local or remote sources
    #      either from TFTP or remote mirror
    #      then extract archive to $ROOT_DIR

    cd "$ROOT_DIR" || exit

    # If STAGE3 does not exist, get from tftp server
    if [ ! -f "$STAGE3" ]; then
        echo "Warning! $STAGE3 not in directory, downloading from local tftp..."
        curl --connect-timeout 30 --speed-time 15 --speed-limit 500 -o "$STAGE3" tftp://"$TFTP"/gentoo-deploy/"$FOLDER"/"$STAGE3" >&2
    fi

    # If STAGE3 does not exist, get from the internet
    if [ ! -f "$STAGE3" ]; then
        echo "Warning! $STAGE3 not in directory, downloading from mirror..."
        wget -l1 -np "${LOCATION}" -P ./ -A index.html -O index.tmp >&2
        STAGE3=$(grep -m1 -Eo ">stage3-${ARCH}-[0-9]*.*.tar.xz" index.tmp | cut -c 2-)
        wget -N "${LOCATION}/${STAGE3}"
    fi

    # Extract STAGE3 to $ROOT_DIR directory
    if [ $(tar xpvf "$STAGE3" --xattrs-include='*.*' --numeric-owner >&2) ]; then
        echo "File does not exist, maybe it failed to download?"
        exit 1
    fi

    #######################################################
    #  Modify make.conf and add make vars and use flags
    #      update cflags
    #      and update global use flags

    # Define CFLAGS and CXXFLAGS
    if [ -n "$MAKECFLAGS" ]; then
        sed -i "s/COMMON_FLAGS=.*/COMMON_FLAGS=\"$MAKECFLAGS\"/" "$MAKECONF"
    fi

    # Append MAKEOPTS to the make.conf file
    echo "MAKEOPTS=\"$MAKEOPTS\"" >> "$MAKECONF"

    # Configure the MAKEUSE Variable
    local match
    match=$(cat /proc/cpuinfo | grep -m 1 -o mmx)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE mmx"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o mmxext)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE mmxext"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o sse)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE sse"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o sse2)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE sse2"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o sse3)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE sse3"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o pni)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE ssse3"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o sse4_1)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE sse4_1"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o sse4_2)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE sse4_2"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o avx)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE avx"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o avx2)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE avx2"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o aes)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE aes"
    fi
    match=$(cat /proc/cpuinfo | grep -m 1 -o fma3)
    if [ -n "$match" ]; then
        MAKEUSE="$MAKEUSE fma3"
    fi

    # Append the make.conf file with more make vars
    #sed -i "s/USE=.*/c\USE=\"$MAKEUSE\"/" "$MAKECONF"
    echo "USE=\"$MAKEUSE\"" >> ."$MAKECONF"
    echo "PYTHON_TARGETS=\"$MAKEPYTHON\"" >> ."$MAKECONF"
    echo "INPUT_DEVICES=\"$MAKEINPUTDEVICES\"" >> ."$MAKECONF"
    echo "VIDEO_CARDS=\"$MAKEVIDEOCARDS\"" >> ."$MAKECONF"
    echo "LINGUAS=\"$MAKELINGUAS\"" >> ."$MAKECONF"

    # Select Mirrors
    mirrorselect -s10 -o >> ."$MAKECONF"

    # Copy DNS info before chrooting
    cp -L /etc/resolv.conf ./etc/
    # Copy itself into the chroot directory before chrooting
    cp -L -u "$SCRIPT" ./root/gentoo-deploy.sh
    # Copy package list to chroot directory before chrooting
    cp -L ./packages.txt ./root/packages.txt

    # Mount important partitions before chrooting
    mount -t proc proc ./proc
    mount --rbind /sys ./sys
    mount --rbind /dev ./dev

    echo "Chrooting..." >&2
    source /etc/profile
    chroot ./ /bin/bash -c "/root/gentoo-deploy.sh chroot"
}

chroot_install() {
    # Show visual (chroot) on shell prompt
    export PS1="(chroot) ${PS1}"

    #######################################################
    #  Setup the Portage Build system
    #      define a system profile
    #      emerge all packages required by global use flags

    # Update the Gentoo ebuild repository to the latest
    mkdir -p "$PACKAGEKEYWORDS"
    emerge-webrsync
    emerge --sync

    # Choose the portage profile
    eselect profile list
    local profile_num=1
    read -rp "Which profile?: " profile_num
    eselect profile set "$profile_num"

    # Update the @world set
    emerge --ask=n --verbose --update --deep --newuse @world

    # Set timezone
    echo "America/Chicago" > /etc/timezone

    # Set locales
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen

    env-update && source /etc/profile

    # Create fstab

    # Install Kernel Sources
    emerge --ask=n sys-kernel/gentoo-sources
    emerge --ask=n sys-kernel/genkernel
    genkernel all

    # Install firmware for special hardware
    emerge --ask=n sys-kernel/linux-firmware

    # Set the hostname for the machine
    local hostname
    read -rp "Enter desired hostname for this machine: " hostname
    echo "hostname=$hostname" >> /etc/conf.d/hostname

    # Install a few helpful packages
    local packages
    packages=$(sed -e 's/#.*$//' -e '/^$/d' packages.txt | tr '\n' ' ')
    emerge --ask=n --autounmask-continue -q $packages

    # Enable some services to the default runlevel
    rc-update add NetworkManager default
    rc-update add sysklogd default

    # Install the bootloader
    emerge --ask=n --quiet-build=y sys-boot/grub:2
    grub-install "$DISK"

    # Change root password
    echo "Set the password for the root account: "
    while [ passwd ];
    do true; done

    # Create new user account
    local username
    read -rp "New account username: " username
    while [ useradd -m -G users, wheel, audio, disk "$username" ];
    do true; done

    # Set password for user account
    echo "Set the password for ${username} account: "
    while [ passwd "$username" ];
    do true; done

    rm stage3-*.tar*
}

main() {
    # Script must be ran as root user
    if [ "$(id -u)" -ne 0 ]; then
        echo "Please run as root"
        exit 1
    fi

    # Open stderr and forward errors to a log file
    exec 3>&2
    exec 2> >(tee "$SCRIPT.log" >&2)

    # Check for commandline parameter
    if [ "$1" = "install" ]; then
        install || exit
    elif [ "$1" = "chroot" ]; then
        chroot_install || exit
    else
        echo "Could not understand $1"
        echo "To start installation, please run $SCRIPT install"
        exit 1
    fi

    echo "Deployment Complete."

    # Print countdown and wait 15 seconds before rebooting
    for seconds in {15..1}; do
        printf "Machine will reboot in %2d seconds...\r" ${seconds}
        sleep 1
    done

    reboot
}

main "$@"
