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

TFTP=192.168.0.3
MIRROR="http://distfiles.gentoo.org"
ARCH="amd64"
PLATFORM="amd64"
LOCATION="$MIRROR/releases/$ARCH/autobuilds"
FOLDER="20210321"
STAGE3="stage3-$ARCH-$FOLDER.tar.xz"

FSTAB="/etc/fstab"
MAKECONF="/etc/portage/make.conf"
PACKAGEKEYWORDS="/etc/portage/package.keywords"

MAKECFLAGS='-march=native -O3 -pipe'
MAKEOPTS="-j$(expr `nproc` + 1)"
MAKEUSE='-bindist -consolekit -webkit -vulkan -vaapi -vdpau -opencl -bluetooth -kde udev threads alsa pulseaudio mpeg mp3 flac aac lame midi ogg vorbis x264 xvid win32codecs real png jpeg jpeg2k raw gif svg tiff opengl bash bash-completion i3 vim vim-syntax git dbus qt4 cairo gtk unicode fontconfig truetype wifi laptop acpi lm_sensors dvd dvdr cdr cdrom pam policykit X dhcpcd logrotate python3_7 python3_9'
MAKEPYTHON='python2_7 python3_3'
MAKEINPUTDEVICES='evdev'
MAKEVIDEOCARDS='intel i965'
MAKELINGUAS='en_US en'

install() {
    #######################################################
    #  Prepare the disks for the MBR Gentoo Install
    #      partition target disk
    #      create filesystems in each partition

    # Show all disks for the user
    lsblk

    # Prompt user for input and save the input
    local disk

    read -rp "Which disk should be erased? (i.e. /dev/sdj): " disk
    echo "WARNING! BLOCK DEVICE: $disk WILL BE ERASED IN 60 SECONDS..."
    echo "PLEASE MAKE SURE THIS IS THE CORRECT DISK"

    # Print countdown and wait 60 seconds before erasing disk
    for seconds in {60..1}; do
        printf "PRESS CTRL+C TO CANCEL (%2d seconds)\r" ${seconds}
        sleep 1
    done

    # Create new partitions and setup for an MBR install
    parted --script "$disk" \
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
    local boot_dev=${disk}1
    local swap_dev=${disk}2
    local root_dev=${disk}3
    local home_dev=${disk}4

    # Create the filesystems
    mkfs.ext4 -F "$boot_dev"
    mkswap -f "$swap_dev"
    mkfs.ext4 -F "$root_dev"
    mkfs.ext4 -F "$home_dev"

    #######################################################
    #  Mount the partitions in the proper order
    #      root must be mounted first
    #      then either /boot or /home

    if [[ ! $(mount "$root_dev" "$ROOT_DIR" >&2) && ! $(findmnt -M "$ROOT_DIR" >&2) ]]; then
        echo "Error! Cannot mount $root_dev to $ROOT_DIR..." >&2
        exit 1
    fi

    mkdir "$BOOT_DIR"
    mkdir "$HOME_DIR"

    if [[ ! $(mount "$boot_dev" "$BOOT_DIR" >&2) && ! $(findmnt -M "$BOOT_DIR" >&2) ]]; then
        echo "Error! Cannot mount $boot_dev to $BOOT_DIR..." >&2
        exit 1
    fi

    if [[ ! $(mount "$home_dev" "$HOME_DIR" >&2) && ! $(findmnt -M "$HOME_DIR" >&2) ]]; then
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
        echo "$STAGE3 not in directory, downloading from local tftp..."
        curl -o "$STAGE3" tftp://"$TFTP"/gentoo-deploy/"$FOLDER"/"$STAGE3" >&2
    fi

    # If STAGE3 does not exist, get from the internet
    if [ ! -f "$STAGE3" ]; then
        echo "$STAGE3 not in directory, downloading from mirror..."
        wget -N "$LOCATION"/"$FOLDER"/"$STAGE3" >&2
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
        sed -i "s/COMMON_FLAGS=.*/c\COMMON_FLAGS=\"$MAKECFLAGS\"/" "$MAKECONF"
    fi

    # Append MAKEOPTS to the make.conf file
    echo "MAKEOPTS=\"$MAKEOPTS\"" >> "$MAKECONF"

    # Configure the MAKEUSE Variable
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o mmx)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE mmx"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o mmxext)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE mmxext"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o sse)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE sse"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o sse2)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE sse2"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o sse3)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE sse3"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o pni)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE ssse3"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o sse4_1)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE sse4_1"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o sse4_2)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE sse4_2"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o avx)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE avx"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o avx2)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE avx2"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o aes)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE aes"
    fi
    MATCH=$(cat /proc/cpuinfo | grep -m 1 -o fma3)
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE fma3"
    fi

    # Append the make.conf file with more make vars
    sed -i "s/USE=.*/c\USE=\"$MAKEUSE\"/" "$MAKECONF"
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

    mkdir -p "$PACKAGEKEYWORDS"
    emerge-webrsync
    emerge --sync
    emerge --oneshot portage

    # Choose the portage profile
    eselect profile list
    local profile_num=1
    read -rp "Which profile?:" profile_num
    eselect profile set "$profile_num"

    # Update the @world set
    emerge --ask=y --verbose --update --deep --newuse @world

    # Set timezone
    echo "America/Chicago" > /etc/timezone

    # Set locales
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen

    env-update && source /etc/profile

    # Create fstab


    # Install Kernel Sources
    emerge --ask=y sys-kernel/gentoo-sources
    emerge --ask=y sys-kernel/genkernel
    genkernel all

    # Install firmware for special hardware
    emerge --ask=y sys-kernel/linux-firmware

    # Set the hostname for the machine
    local hostname
    read -rp "Enter desired hostname for this machine" hostname
    echo "hostname=$hostname" >> /etc/conf.d/hostname

    # Install a few helpful packages
    emerge --ask=y net-misc/networkmanager
    rc-update add NetworkManager default

    emerge --ask=y app-admin/sysklogd
    rc-update add sysklogd default

    emerge --ask=y sys-apps/mlocate
    emerge --ask=y net-wireless/wpa_supplicant

    # Install the bootloader
    emerge --ask=y sys-boot/grub:2
    grub-install "$disk"

    # Change root password and create a user account
    echo "Set the password for the root account:"
    passwd

    local username
    read -rp "Set a user account" username
    useradd -m -G users, wheel, audio, disk "$username"
    echo "Set the password for ${username} account"
    passwd "${username}"

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
        install
    elif [ "$1" = "chroot" ]; then
        chroot_install
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
