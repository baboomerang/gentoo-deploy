#!/bin/bash

###########################
#
# Gentoo Deploy Script
# Usage: ./gentoo-deploy.sh
#
################################

SCRIPT=`realpath $0`
ROOT="/mnt/gentoo"
BOOT="$ROOT/boot"
HOME="$ROOT/home"

TFTP=192.168.0.3
MIRROR="http://distfiles.gentoo.org"
ARCH="amd64"
PLATFORM="amd64"
LOCATION="$MIRROR/releases/$ARCH/autobuilds"
FOLDER="20210321"
STAGE3="stage3-$ARCH-$FOLDER.tar.xz"

MAKECONF="/etc/portage/make.conf"
PACKAGEKEYWORDS="/etc/portage/package.keywords"

MAKECFLAGS='-march=native -O3 -pipe'
MAKEOPTS="-j$(expr `nproc` + 1)"
MAKEUSE='-bindist udev'
MAKEPYTHON='python2_7 python3_3'
MAKEINPUTDEVICES='evdev'
MAKEVIDEOCARDS='intel i965'
MAKELINGUAS='en_US en'

PROFILE="desktop/kde/systemd"
KERNEL_MODULES=''
CLEAN="tr -d '\040\011\012\015'"


install() {

    # Open stderr and forward errors to a log file
    exec 3>&2
    exec 2> >(tee "$SCRIPT.log" >&2)

    # Create initial folders, we will mount block devices to these folders
    mkdir -p $ROOT/boot
    mkdir -p $ROOT/home

    # Show all disks for the user
    lsblk

    # Prompt user and save user input
    local DISK
    read -p "Which disk should be erased?(i.e. /dev/sdj) BACKUP ALL DATA \
             BEFORE TYPING A DISK NAME YOU HAVE BEEN WARNED:" $DISK

    SECONDS=60
    while [ ${SECONDS} -ge 1 ]; do
        printf "\r!WARNING! BLOCK DEVICE:$DISK WILL BE ERASED IN %2d SECONDS....\n
                PLEASE MAKE SURE THIS IS THE CORRECT DISK. PRESS CTRL+C TO CANCEL" ${SECONDS}
        sleep 1
        SECONDS=$((SECONDS-1))
    done
    
    # Create new partitions and setup for an MBR install
    parted -a optimal --script ${DISK} \
        mklabel msdos \
        mkpart primary ext2 0GiB 1GiB \
        set 1 boot on \
        mkpart primary linux-swap 1GiB 9GiB \
        mkpart primary ext4 11GiB 30GiB \
        mkpart primary ext4 30GiB 100% >&2

    if [ $? -ne 0 ]; then
        echo "Error! Something went wrong when writing partion"
        echo "Disk is in an unknown state. You are on your own"
        exit 1
    fi

    #
    # Mount disk partitions to folders
    #
    local BOOT_DEV=${DISK}1
    local SWAP_DEV=${DISK}2
    local ROOT_DEV=${DISK}3
    local HOME_DEV=${DISK}4

    if [ ! $(mount $ROOT_DEV $ROOT) ] &&
       [ ! $(findmnt -Mn $ROOT) ]; then
        echo "Error! Cannot mount $ROOT_DEV to $ROOT..." >&2
        echo "Double check that $ROOT_DEV exists in your system" >&2
        exit 1
    fi

    if [ ! $(mount $BOOT_DEV $BOOT) ] &&
       [ ! $(findmnt -Mn $BOOT) ]; then
        echo "Error! Cannot mount $BOOT_DEV to $BOOT..." >&2
        echo "Double check that $BOOT_DEV exists in your system" >&2
        exit 1
    fi

    if [ ! $(mount $HOME_DEV $HOME) ] &&
       [ ! $(findmnt -Mn $HOME) ]; then
        echo "Error! Cannot mount $HOME_DEV to $HOME..." >&2
        echo "Double check that $HOME_DEV exists in your system" >&2
        exit 1
    fi

    if [ ! $(swapon $SWAP_DEV) ]; then
        echo "Error! Invalid SWAP Partition" >&2
        exit 1
    fi
    
    cd $ROOT
    
    # If STAGE3 does not exist, get from tftp server
    if [ ! -f $STAGE3 ]; then
        echo "STAGE3 not in directory, downloading from local tftp..."
        curl -o $STAGE3 tftp://$TFTP/gentoo-deploy/$FOLDER/$STAGE3 >&2
    fi

    # If STAGE3 does not exist, get from the internet
    if [ ! -f $STAGE3 ]; then
        echo "STAGE3 not in directory, downloading from mirror..."
        wget -N $LOCATION/$FOLDER/$STAGE3 >&2
    fi

    # Extract STAGE3 to $ROOT directory
    tar xzvf $STAGE3
    if [ $? -ne 0 ]; then
        echo "File does not exist"
        exit 1
    fi

    # Define CFLAGS and CXXFLAGS
    if [ ! -z "$MAKECFLAGS" ]; then
        sed -i "/CFLAGS=.*/c\CFLAGS=\"$MAKECFLAGS\"" .$MAKECONF
    fi

    # Append MAKEOPTS to the make.conf file
    echo "MAKEOPTS=\"$MAKEOPTS\"" >> .$MAKECONF

    # Configure the MAKEUSE Variable
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o mmx`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE mmx"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o mmxext`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE mmxext"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o sse`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE sse"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o sse2`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE sse2"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o sse3`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE sse3"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o pni`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE ssse3"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o sse4_1`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE sse4_1"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o sse4_2`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE sse4_2"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o avx`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE avx"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o avx2`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE avx2"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o aes`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE aes"
    fi
    MATCH=`cat /proc/cpuinfo | grep -m 1 -o fma3`
    if [ ! -z "$MATCH" ]; then
        MAKEUSE="$MAKEUSE fma3"
    fi

    # Append the Make.conf file with more make options 
    sed -i "/USE=.*/c\USE=\"$MAKEUSE\"" .$MAKECONF
    echo "PYTHON_TARGETS=\"$MAKEPYTHON\"" >> .$MAKECONF
    echo "INPUT_DEVICES=\"$MAKEINPUTDEVICES\"" >> .$MAKECONF
    echo "VIDEO_CARDS=\"$MAKEVIDEOCARDS\"" >> .$MAKECONF
    echo "LINGUAS=\"$MAKELINGUAS\"" >> .$MAKECONF

    # Select Mirrors
    mirrorselect -s10 -o >> .$MAKECONF 
    mirrorselect -i -r -o >> .$MAKECONF

    # Copy DNS info before chrooting
    cp -L /etc/resolv.conf ./etc/
    # Copy itself into the chroot directory before chrooting
    cp -L -u $SCRIPT ./root/gentoo-deploy.sh

    mount -t proc proc ./proc
    mount --rbind /sys ./sys
    mount --rbind /dev ./dev
    chroot ./ /bin/bash -c "/root/gentoo-deploy.sh chroot"
}

chroot_install() {
    exec 3>&2
    exec 2> >(tee "$SCRIPT.log" >&2)

    # Show visual (chroot) on shell prompt
    source /etc/profile
    export PS1="(chroot) ${PS1}"

    mkdir -p $PACKAGEKEYWORDS
    emerge-webrsync
    emerge --sync
    emerge --oneshot portage

    env-update && source /etc/profile
}

main() {

    # Script must be ran as root user
    if [ "$(id -u)" -ne 0]; then
        echo "Please run as root"
        exit 1
    fi

    # Check for commandline parameter
    if [ "$1" == "install" ]; then
        install()
    elif [ "$1" == "chroot" ]; then
        chroot_install()
    else
        echo "Could not understand $1"
        echo "To start installation, please run $SCRIPT install"
        echo "To continue installation from a previous chroot, please run $SCRIPT chroot"
        echo "No changes have been made"
        exit 1
    fi

    echo "Deployment Complete."

    # Print countdown and wait 15 seconds before rebooting
    SECONDS=15
    while [ ${SECONDS} -ge 1 ]; do
        printf "\rMachine will reboot in %2d seconds..." ${SECONDS}
        sleep 1
        SECONDS=$((SECONDS-1))
    done

    reboot
}

main "$@"
