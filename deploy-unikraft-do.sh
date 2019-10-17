#!/usr/bin/env bash
# This script automates the process of deploying unikraft built images
# to DO's Compute service.
#

#################################################
################ Global Defines #################
#################################################
GREEN="\e[92m"
LIGHT_BLUE="\e[94m"
RED="\e[31m"
LIGHT_RED="\e[91m"
GRAY_BG="\e[100m"
UNDERLINE="\e[4m"
BOLD="\e[1m"
END="\e[0m"

# Cloud Specific global constants
# Default values, if not provided to the script.
PROJECT="unikraft"
BASE_NAME="unikraft"
REGION="fra1"
INST_TYPE_SIZE="s-1vcpu-1gb"
NAME=${BASE_NAME}-`date +%s`
DESCRIPTION="Cloud-optimized image with very small footprint"
DO_API_V2="https://api.digitalocean.com/v2/images"
DISTRIBUTION="unikraft"
CONFIG_FILE="config-do.sh"
CONFIG_DIR="$HOME/.unikraft"
CONFIG_PATH_DEF="$CONFIG_DIR/$CONFIG_FILE"

# System specific global vars
MOUNT_OPTS="rw"
SUDO="sudo"
MBR_SIZE=512
EXT_BUFF_SIZE=400
MIN_KERN_SIZE_KB=624
MBR_IMAGE="mbr.img"
FS_IMAGE="fs.img"
MBR="/usr/lib/syslinux/mbr/mbr.bin"
LIBCOM32="/usr/lib/syslinux/modules/bios/libcom32.c32"
MBOOT="/usr/lib/syslinux/modules/bios/mboot.c32"
ERROR="Error:"
HTTP_ACCEPTED=202
HTTP_OK=200
STATUS_CODE="StatusCode"
LOG="${NAME}-log.uk"


# List of required tools
req_tools=(
"sfdisk"
"doctl"
"s3cmd"
"jq"
"syslinux"
"mkdosfs"
)

#################################################
############### Helper Functions ################
#################################################

# Gives script usage information to the user
function usage() {
   echo "usage: $0 [-h] [-v] -k <unikernel> -b <bucket> -p <config-path> [-n <name>]"
   echo "       [-r <region>] [-i <instance-type>] [-t <tag>] [-s]"
   echo ""
   echo -e "${UNDERLINE}Mandatory Args:${END}"
   echo "<unikernel>: 	  Name/Path of the unikernel (Please use \"KVM\" target images) "
   echo "<bucket>: 	  Digitalocean bucket name"
   echo ""
   echo -e "${UNDERLINE}Optional Args:${END}"
   echo "<name>: 	  Image name to use on the cloud (default: ${BASE_NAME})"
   echo "<region>: 	  Digitalocean region (default: ${REGION})"
   echo "<instance-type>:  Specify the type of the machine on which you wish to deploy the unikernel (default: ${INST_TYPE_SIZE}) "
   echo "<-v>: 		  Turns on verbose mode"
   echo "<-s>: 		  Automatically starts an instance on the cloud"
   echo ""
   exit 1
}

# Directs the script output to data sink
log_pause() {
if [ -z "$V" ]
then
        exec 6>&1
        exec &>> $LOG
fi
}

# Restores/Resumes the script output to STGCPUT
log_resume() {
if [ -z "$V" ]
then
        exec >&6
fi
}


# If any command fails in script, this function will be invoked to handle the error.
function handle_error() {
	log_resume
	echo -e "${LIGHT_RED}[FAILED]${END}"
	echo -e "${LIGHT_RED}Error${END} on line:$1"
	if [ ! -z "$V" ]
	then
		echo -e "For more details, please see ${LIGHT_BLUE}$LOG${END} file, or run the script with verbose mode ${GRAY_BG}-v${END}"
	else
		# Print the error message
		echo $2
	fi
	clean
	exit 1
}

# Check if provided config file exists.
if [ ! -e "$CONFIG_PATH" ]; then
        if [ ! -e $CONFIG_PATH_DEF ]; then
                echo -e "${LIGHT_RED}No config file found!${END}"
                echo "Please copy the config file ${CONFIG_FILE} to \"${CONFIG_DIR}\" dir or "
                echo "specify config file path with [-p] flag."
                echo "Run '$0 -h' for full option list."
                exit 1
        else
                # Use Default file as config file.
                CONFIG_PATH="$CONFIG_PATH_DEF"
        fi
fi


. ${CONFIG_PATH}

function handle_output() {
local ln=$1
local cmd_out=$2
local status=$3
# Debug
echo handle_output: $1 : $2 : $3

if [ ${status} -ne ${HTTP_OK} ] && [ ${status} -ne ${HTTP_ACCEPTED} ];
then
	handle_error "$ln" "$cmd_out"
else
	log_resume
	echo -e "${GREEN}[OK]${END}"
fi
}

function create_image() {
echo -n "Creating image on the cloud.............."
log_pause
local output=$( eval curl --write-out " StatusCode:%{http_code}" --silent -X POST -H "\"Content-Type: application/json\"" -H "\"Authorization: Bearer $DO_AUTH_TOKEN\"" -d \'{"\"name\"": "\"$NAME\"", "\"url\"": "\"https://$BUCKET.$REGION.digitaloceanspaces.com/$DISK\"", "\"distribution\"": "\"$DISTRIBUTION\"", "\"region\"": "\"$REGION\"", "\"description\"": "\"$DESCRIPTION\""}\' "\"$DO_API_V2\"" );ln=$LINENO;
local status=$( echo $output | grep -Po '(?<='"$STATUS_CODE"':).*$')
IMG_ID=$( echo $output | jq -r '.image' | jq -r '.id' )
s3cmd setacl s3://$BUCKET/$DISK --acl-private
handle_output "$ln" "$output" "$status"
}

function delete_image() {
local img_id=$1
echo -n "Deleting existing image.................."
log_pause
local output=$( doctl compute image delete $img_id -f 2>&1 );ln=$LINENO;
local status=$( echo $output | awk 'NR==1 { print $1; }' )
[ ${status} = ${ERROR} ] && status=404;
handle_output "$ln" "$output" "$status"
}

 function create_bucket() {
 echo -n "Creating bucket on the cloud............."
 log_pause
 s3cmd mb s3://${BUCKET};sts_code=$?;ln=$LINENO
 echo ------$sts_code
 if [ "$sts_code" -ne 0 ];then
     handle_error $ln
 fi
 log_resume
 echo -e "${GREEN}[OK]${END}"
 }

function unmount() {
  # If the script is interrupted before getting to this step you'll end up with
  # lots of half-mounted loopback-devices after a while.
  # Unmount by consecutive calls to command below.

  echo -e "Unmounting and detaching $LOOP"
  sudo umount -vd $MOUNT_DIR || :

}

function clean() {
	echo -n "Cleaning temporary files................."
	log_pause
	unmount
	${SUDO} rm -rf ${TMP_DIR}
	${SUDO} rm -rf ${MOUNT_DIR}
	rm $DISK
	rm $TAR_FILE
	log_resume
	echo -e "${GREEN}[OK]${END}"
}

#################################################
################ Main Routine ###################
#################################################

# Process the arguments given to script by user
while getopts "vshk:n:b:r:i:t:" opt; do
 case $opt in
 h) usage;;
 n) NAME=$OPTARG ;;
 b) BUCKET=$OPTARG ;;
 r) REGION=$OPTARG ;;
 k) UNIKERNEL=$OPTARG ;;
 i) INSTYPE=$OPTARG ;;
 t) TAG=$OPTARG ;;
 v) V=true ;;
 s) S=true ;;
 esac
done

shift $((OPTIND-1))

# Take root priviledge for smooth execution
${SUDO} echo "" >/dev/null

# Check if provided image file exists.
if [ ! -e "$UNIKERNEL" ]; then
  echo "Please specify a unikraft image with required [-k] flag."
  echo "Run '$0 -h' for more help"
  exit 1
fi

if [ -z $BUCKET ];
then
    echo "Please specify bucket-name with mandatory [-b] flag."
    echo "Run '$0 -h' for more help"
    exit 1
else
    log_pause
    s3cmd ls s3://${BUCKET} || create_bkt=true
    log_resume
fi

# Check if required tools are installed
for i in "${req_tools[@]}"
do
   type $i >/dev/null 2>&1 || { echo -e "Tool Not Found: ${LIGHT_BLUE}$i${END}\nPlease install : $i\n${LIGHT_RED}Aborting.${END}"; exit 1;}
done

# Check if the required binaries are present
req_bins=("$MBR" "$LIBCOM32" "$MBOOT")
for i in "${req_bins[@]}"
do
   [ ! -f $i ] && { echo -e "File Not Found:${LIGHT_BLUE}${i}${END}\nPlease install syslinux: ${LIGHT_BLUE}sudo apt install syslinux${END}\n${LIGHT_RED}Aborting.${END} " ; exit 1; }
done

# Configure the environment and paths needed for script to run properly.
. ${CONFIG_PATH}

# set error callback
trap 'handle_error $LINENO' ERR

# Name the final Disk
DISK=${NAME}.raw

echo -e "Deploying ${LIGHT_BLUE}${DISK}${END} on Digitalocean..."
echo -e "${BOLD}Name  :${END} ${NAME}"
echo -e "${BOLD}Bucket:${END} ${BUCKET}"
echo -e "${BOLD}Region:${END} ${REGION}"
echo ""
# Create the image disk
echo -n "Creating disk partitions.................";
log_pause
echo ""
# Kernel size in KBs
KERNEL_SIZE=$(( ($(stat -c%s "$UNIKERNEL") / 1024) ))
# Digital ocean requires atlest 1024K of image size.
if [ ${KERNEL_SIZE} -lt ${MIN_KERN_SIZE_KB} ]
then
        EXT_BUFF_SIZE=$(( ${EXT_BUFF_SIZE} + (${MIN_KERN_SIZE_KB} - ${KERNEL_SIZE}) ))
fi
DISK_SIZE=$(( KERNEL_SIZE + EXT_BUFF_SIZE ))
SIZE=${DISK_SIZE}K
# Create temporary directories
TMP_DIR=`mktemp -d /tmp/unikraft.XXX`
MOUNT_DIR=`mktemp -d /tmp/ukmount.XXX`
# Copy the mbr as an image
cp ${MBR} ${TMP_DIR}/${MBR_IMAGE}
truncate -s ${SIZE} ${TMP_DIR}/${MBR_IMAGE}
# Create primary partition (FAT32)
echo ",,0xc,*" | sfdisk ${TMP_DIR}/${MBR_IMAGE}
# Take out the partition by skipping MBR.
dd if=${TMP_DIR}/${MBR_IMAGE} of=${TMP_DIR}/${FS_IMAGE} bs=512 skip=1
# Truncate the size of actual image to contain only mbr
truncate -s ${MBR_SIZE} ${TMP_DIR}/${MBR_IMAGE}
# Create filesystem - FAT32
mkdosfs ${TMP_DIR}/${FS_IMAGE}
log_resume
echo -e "${GREEN}[OK]${END}"
echo -n "Installing boot loader..................."
log_pause
# Install syslinux
syslinux --install ${TMP_DIR}/${FS_IMAGE}
log_resume
echo -e "${GREEN}[OK]${END}"
echo -n "Creating bootable disk image............."
log_pause
# Find first available loopback device
LOOP=$(${SUDO} losetup -f)
echo -e "Associating $LOOP with $DISK"
echo ""
# Associate loopback with disk file
${SUDO} losetup $LOOP ${TMP_DIR}/${FS_IMAGE}
echo -e "Mounting ($MOUNT_OPTS)  ${FS_IMAGE} on $MOUNT_DIR"
mkdir -p $MOUNT_DIR
${SUDO} mount -o $MOUNT_OPTS $LOOP $MOUNT_DIR
${SUDO} cp ${LIBCOM32} $MOUNT_DIR/libcom32.c32
${SUDO} cp ${MBOOT} $MOUNT_DIR/mboot.c32
${SUDO} cp $UNIKERNEL $MOUNT_DIR/unikernel.bin
cat <<EOM >${TMP_DIR}/syslinux.cfg
TIMEOUT 0
DEFAULT unikernel
LABEL unikernel
  KERNEL mboot.c32
  APPEND unikernel.bin
EOM
${SUDO} mv ${TMP_DIR}/syslinux.cfg $MOUNT_DIR/syslinux.cfg
sync
unmount
# Create Final Deployable Disk Image
echo "Creating RAW Disk"
cat ${TMP_DIR}/${MBR_IMAGE} ${TMP_DIR}/${FS_IMAGE} | dd of=${DISK} conv=sparse
log_resume
echo -e "${GREEN}[OK]${END}"
# Instance name to be used on the cloud
INSTANCE_NAME=$NAME
# Create the bucket if doesn't exists
if [ "$create_bkt" = "true" ];then
    create_bucket
fi
echo -n "Uploading disk to the cloud.............."
log_pause
echo ""
echo "File having same name will be overwritten."
s3cmd put $DISK s3://$BUCKET/$DISK --acl-public
log_resume
echo -e "${GREEN}[OK]${END}"
# Check if image already exists
IMG_ID=$( doctl compute image list | grep $NAME | awk 'NR==1 { print $1; }' || :)
if [ -z "$IMG_ID" ]
then
	create_image
else
	echo -e "${LIGHT_RED}An image already exists on cloud with the name: ${LIGHT_BLUE}${NAME}${END}${END}"
	echo -n "Would you like to delete the existing image and create new one (y/n)?"
	read choice
	case "$choice" in
		y|Y )	delete_image $IMG_ID
			create_image ;;
		n|N ) echo "Please change the image name and try again."
			clean
			exit 1 ;;
		* ) echo "Invalid choice. Please enter y|Y or n|N"
			clean
			exit 1 ;;
	esac
fi

if [ -z "$S" ]
then
    clean
    echo ""
    echo "To run the instance on DO, use following command-"
    echo -e "${GRAY_BG}doctl compute droplet create $NAME --image $IMG_ID --region $REGION --size $INST_TYPE_SIZE --ssh-keys $DO_AUTH_FINGER_PRINT --wait ${END}"
else
    echo -n "Starting instance on the cloud..........."
    log_pause
    # This echo maintains the formatting
    echo "doctl compute droplet create $NAME --image $IMG_ID --region $REGION --size $INST_TYPE_SIZE --ssh-keys $DO_AUTH_FINGER_PRINT --wait"
    # Wait for 5 seconds
    sleep 5
    # Start an instance on the cloud
    doctl compute droplet create $NAME --image $IMG_ID --region $REGION --size $INST_TYPE_SIZE --ssh-keys $DO_AUTH_FINGER_PRINT --wait > tmp_inst_info
    log_resume
    echo -e "${GREEN}[OK]${END}"
    cat tmp_inst_info
    rm tmp_inst_info
    clean
fi
log_resume
echo ""
echo -e "${UNDERLINE}NOTE:${END}"
echo " - Don't forget to customise DO with proper firewall settings"
echo "   as the default one won't let any inbound traffic in."
echo ""
