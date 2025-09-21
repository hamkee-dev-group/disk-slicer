#!/usr/bin/env bash
# disk-slice.sh — Partition a new disk and make filesystems with fstab snippet.
# Safeties: confirmation, dry-run, new GPT label, refuses busy disks, alignment.
# Usage examples:
#   sudo ./disk-slice.sh --disk /dev/sdb --count 3 --fstype ext4 --create-mounts
#   sudo ./disk-slice.sh --disk /dev/sdb --layout 50%,30%,20% --fstypes ext4,xfs,btrfs --mount-base /mnt/data --mount-now
#
set -Eeuo pipefail
umask 022

VERSION="1.0.0"

# Defaults
DISK=""
COUNT=""
LAYOUT=""          # e.g. "50%,30%,20%"
FSTYPE_DEFAULT=""  # e.g. "ext4"
FSTYPES=""         # e.g. "ext4,xfs,btrfs"
LABEL_PREFIX="data"
MOUNT_BASE="/mnt/data"
CREATE_MOUNTS=0
MOUNT_NOW=0
ASSUME_YES=0
DRY_RUN=0
VERBOSE=0
TOOL="sgdisk"      # or "parted"
ALIGN_MIB=1        # partition alignment in MiB

log()  { echo "[$(date +%H:%M:%S)] $*"; }
vlog() { [[ $VERBOSE -eq 1 ]] && log "$@"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

run(){
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    vlog "+ $*"
    eval "$@"
  fi
}

confirm(){
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" == [yY] ]]
}

usage(){
  cat <<EOF
disk-slice.sh v$VERSION

Safely partition a disk into N partitions (equal sizes or explicit percentages),
create filesystems, and generate a commented /etc/fstab snippet.

Required:
  --disk /dev/SDX          Target whole disk device (e.g., /dev/sdb, /dev/nvme1n1)
  One of:
    --count N              Number of equal-size partitions
    --layout A%,B%,C%      Comma-separated percentages that sum to 100
  Filesystem choice:
    --fstype ext4          Single filesystem type for all partitions
    --fstypes a,b,c        Per-partition filesystems (comma-separated)

Options:
  --label-prefix NAME      Label prefix for filesystems (default: data)
  --mount-base PATH        Base dir for mountpoints (default: /mnt/data)
  --create-mounts          Create mountpoints (e.g., /mnt/data1, /mnt/data2, ...)
  --mount-now              Mount them immediately (implies --create-mounts)
  --use-parted             Use 'parted' instead of 'sgdisk' (default is sgdisk/GPT)
  --align-mib N            Partition alignment in MiB (default: 1)
  -y, --yes                Skip confirmation
  -n, --dry-run            Print plan/commands only (no changes)
  -v, --verbose            Verbose logging
  -h, --help               Show this help

Examples:
  sudo ./disk-slice.sh --disk /dev/sdb --count 3 --fstype ext4 --create-mounts
  sudo ./disk-slice.sh --disk /dev/sdb --layout 60%,30%,10% --fstypes xfs,ext4,btrfs --mount-base /srv/vol --mount-now

Notes:
  * This script creates a new GPT label on the target disk.
  * It refuses to run if the disk appears in use (mounted, has partitions with filesystems, LVM PVs, etc.).
EOF
}

# ---- arg parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk) DISK="$2"; shift 2;;
    --count) COUNT="$2"; shift 2;;
    --layout) LAYOUT="$2"; shift 2;;
    --fstype) FSTYPE_DEFAULT="$2"; shift 2;;
    --fstypes) FSTYPES="$2"; shift 2;;
    --label-prefix) LABEL_PREFIX="$2"; shift 2;;
    --mount-base) MOUNT_BASE="$2"; shift 2;;
    --create-mounts) CREATE_MOUNTS=1; shift;;
    --mount-now) MOUNT_NOW=1; CREATE_MOUNTS=1; shift;;
    --use-parted) TOOL="parted"; shift;;
    --align-mib) ALIGN_MIB="$2"; shift 2;;
    -y|--yes) ASSUME_YES=1; shift;;
    -n|--dry-run) DRY_RUN=1; shift;;
    -v|--verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

# ---- validate inputs ----
[[ -n "$DISK" ]] || { usage; die "--disk is required"; }
[[ -b "$DISK" ]] || die "$DISK is not a block device"
if [[ -n "$COUNT" && -n "$LAYOUT" ]]; then die "Use either --count OR --layout"; fi
if [[ -z "$COUNT" && -z "$LAYOUT" ]]; then die "Specify --count or --layout"; fi
if [[ -n "$COUNT" && ! "$COUNT" =~ ^[1-9][0-9]*$ ]]; then die "--count must be a positive integer"; fi

# FS selection rules
if [[ -n "$FSTYPES" && -n "$FSTYPE_DEFAULT" ]]; then
  die "Use either --fstype or --fstypes (not both)"
fi
[[ -n "$FSTYPES" || -n "$FSTYPE_DEFAULT" ]] || die "Provide --fstype (single) or --fstypes (list)"

# Root privileges unless dry-run
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then die "Run as root (or use --dry-run)"; fi

# Commands we need (conditionally)
need lsblk
need blkid
need partprobe
need sgdisk

if [[ "$TOOL" == "parted" ]]; then need parted; fi

# ---- safety checks on target disk ----
# 1) Must be a whole disk (TYPE=disk)
t=$(lsblk -no TYPE "$DISK" 2>/dev/null || true)
[[ "$t" == "disk" ]] || die "$DISK is not a whole disk (TYPE=$t)"

# 2) Must not be mounted anywhere
if findmnt -S "$DISK" >/dev/null 2>&1; then
  die "$DISK appears to be mounted or used by a mount"
fi

# 3) List existing children; if any have filesystems or PVs, refuse
CHILDREN=$(lsblk -nr -o NAME,TYPE "$DISK" | awk '$2!="disk"{print $1}')
if [[ -n "$CHILDREN" ]]; then
  # If there are partitions, ensure they have no FS signatures and are not PVs
  while read -r c; do
    [[ -z "$c" ]] && continue
    node="/dev/$c"
    # Any mount?
    if findmnt -S "$node" >/dev/null 2>&1; then die "Child $node is mounted. Refusing."; fi
    # Any FS/PV signature?
    if blkid "$node" >/dev/null 2>&1; then die "Child $node has existing signatures. Refusing."; fi
  done <<< "$CHILDREN"
fi

# ---- derive counts & filesystem list ----
declare -a sizes
declare -a fstypes

if [[ -n "$COUNT" ]]; then
  for ((i=0;i<COUNT;i++)); do sizes+=("EQUAL"); done
  if [[ -n "$FSTYPES" ]]; then
    IFS=',' read -r -a fstypes <<< "$FSTYPES"
    [[ ${#fstypes[@]} -eq $COUNT ]] || die "--fstypes count must match --count"
  else
    for ((i=0;i<COUNT;i++)); do fstypes+=("$FSTYPE_DEFAULT"); done
  fi
else
  # layout mode
  IFS=',' read -r -a layout_arr <<< "$LAYOUT"
  sum=0
  for p in "${layout_arr[@]}"; do
    [[ "$p" =~ ^([0-9]{1,3})%$ ]] || die "Invalid percent '$p' (use e.g. 50%)"
    val=${BASH_REMATCH[1]}
    (( val>=1 && val<=100 )) || die "Percent out of range: $p"
    sizes+=("$val")
    (( sum += val ))
  done
  [[ $sum -eq 100 ]] || die "Percentages must sum to 100 (got $sum)"
  if [[ -n "$FSTYPES" ]]; then
    IFS=',' read -r -a fstypes <<< "$FSTYPES"
    [[ ${#fstypes[@]} -eq ${#sizes[@]} ]] || die "--fstypes count must match --layout entries"
  else
    for ((i=0;i<${#sizes[@]};i++)); do fstypes+=("$FSTYPE_DEFAULT"); done
  fi
fi

# ---- size math (MiB) ----
SECTOR_SIZE=$(cat "/sys/class/block/$(basename "$DISK")/queue/logical_block_size")
[[ -n "$SECTOR_SIZE" ]] || die "Cannot read sector size"
SECTORS=$(cat "/sys/class/block/$(basename "$DISK")/size")
[[ -n "$SECTORS" ]] || die "Cannot read disk size (sectors)"
BYTES=$(( SECTORS * SECTOR_SIZE ))
MIB_TOTAL=$(( BYTES / 1024 / 1024 ))

ALIGN=$ALIGN_MIB
START=$ALIGN     # start the first partition at ALIGN MiB

declare -a PART_START_MIB
declare -a PART_END_MIB

if [[ "${sizes[0]}" == "EQUAL" ]]; then
  N=${#sizes[@]}
  # leave ALIGN MiB at start for alignment; end at MIB_TOTAL - ALIGN
  USABLE=$(( MIB_TOTAL - ALIGN ))
  EACH=$(( USABLE / N ))
  # Guarantee at least 10 MiB
  (( EACH >= 10 )) || die "Disk too small for $N partitions with alignment"
  for ((i=0;i<N;i++)); do
    local_start=$START
    local_end=$(( local_start + EACH - 1 ))
    # last partition takes remainder up to end
    if (( i == N-1 )); then local_end=$(( MIB_TOTAL - 1 )); fi
    PART_START_MIB+=("$local_start")
    PART_END_MIB+=("$local_end")
    START=$(( local_end + 1 ))
  done
else
  # percentage layout
  N=${#sizes[@]}
  ACC=0
  for ((i=0;i<N;i++)); do
    p=${sizes[$i]}
    span=$(( (MIB_TOTAL - ALIGN) * p / 100 ))
    local_start=$START
    local_end=$(( local_start + span - 1 ))
    # last takes remainder
    if (( i == N-1 )); then local_end=$(( MIB_TOTAL - 1 )); fi
    (( local_end > local_start )) || die "Calculated partition $i size too small"
    PART_START_MIB+=("$local_start")
    PART_END_MIB+=("$local_end")
    START=$(( local_end + 1 ))
    (( ACC += p ))
  done
fi

# ---- plan ----
echo
echo "=== PLAN ==="
echo "Disk: $DISK  size: $MIB_TOTAL MiB  sector: ${SECTOR_SIZE}B"
echo "Label: GPT (new)"
for ((i=0;i<${#PART_START_MIB[@]};i++)); do
  s=${PART_START_MIB[$i]}; e=${PART_END_MIB[$i]}; fs=${fstypes[$i]}
  echo "  p$((i+1)): ${s}MiB -> ${e}MiB   FS=$fs   label=${LABEL_PREFIX}$((i+1))  mount=${MOUNT_BASE}$((i+1))"
done
echo "Tool: $TOOL   Align: ${ALIGN}MiB   create-mounts=$CREATE_MOUNTS   mount-now=$MOUNT_NOW"
echo "FSTAB snippet will be written to /root/fstab.new.$(basename "$DISK").txt"
echo "============"
echo

confirm || { echo "Aborted."; exit 0; }

# ---- apply: wipe & create GPT ----
run "partprobe '$DISK' || true"
# Wipe existing partition table signatures (non-destructive to data areas, but cautious)
run "sgdisk -Z '$DISK'"      # zap
run "sgdisk -og '$DISK'"     # new protective MBR + GPT
run "partprobe '$DISK' || true"

# ---- create partitions ----
if [[ "$TOOL" == "sgdisk" ]]; then
  for ((i=0;i<${#PART_START_MIB[@]};i++)); do
    idx=$((i+1))
    s="${PART_START_MIB[$i]}MiB"
    e="${PART_END_MIB[$i]}MiB"
    lbl="${LABEL_PREFIX}${idx}"
    # Linux filesystem GUID type
    run "sgdisk -n ${idx}:${s}:${e} -t ${idx}:8300 -c ${idx}:'${lbl}' '$DISK'"
  done
else
  # parted (MiB units)
  run "parted -s '$DISK' mklabel gpt"
  for ((i=0;i<${#PART_START_MIB[@]};i++)); do
    s="${PART_START_MIB[$i]}MiB"
    e="${PART_END_MIB[$i]}MiB"
    lbl="${LABEL_PREFIX}$((i+1))"
    run "parted -s -a optimal '$DISK' mkpart '${lbl}' ${s} ${e}"
    run "parted -s '$DISK' set $((i+1)) lvm off" || true
  done
fi

run "partprobe '$DISK'"

# Resolve partition node names (handles nvme p-suffix)
mapfile -t PARTS < <(lsblk -nr -o NAME,TYPE "$DISK" | awk '$2=="part"{print $1}' | sed 's|^|/dev/|')

[[ ${#PARTS[@]} -eq ${#PART_START_MIB[@]} ]] || die "Partition count mismatch after creation"

# ---- mkfs & labels ----
declare -a UUIDS
for ((i=0;i<${#PARTS[@]};i++)); do
  p="${PARTS[$i]}"
  fs="${fstypes[$i]}"
  lbl="${LABEL_PREFIX}$((i+1))"
  case "$fs" in
    ext4|ext3)
      need mkfs.$fs
      run "mkfs.$fs -F -L '$lbl' '$p'"
      ;;
    xfs)
      need mkfs.xfs
      run "mkfs.xfs -f -L '$lbl' '$p'"
      ;;
    btrfs)
      need mkfs.btrfs
      run "mkfs.btrfs -f -L '$lbl' '$p'"
      ;;
    *)
      die "Unsupported filesystem: $fs"
      ;;
  esac
  # Fetch UUID
  if [[ $DRY_RUN -eq 1 ]]; then
    UUIDS+=("DRYRUN-UUID-${i}")
  else
    uuid=$(blkid -s UUID -o value "$p")
    [[ -n "$uuid" ]] || die "Could not read UUID for $p"
    UUIDS+=("$uuid")
  fi
done

# ---- mountpoints ----
if [[ $CREATE_MOUNTS -eq 1 ]]; then
  for ((i=0;i<${#PARTS[@]};i++)); do
    mp="${MOUNT_BASE}$((i+1))"
    run "mkdir -p '$mp'"
  done
fi

# ---- fstab snippet ----
SNIP="/root/fstab.new.$(basename "$DISK").txt"
echo "# fstab snippet generated by disk-slice.sh $(date -u +"%Y-%m-%dT%H:%M:%SZ")" | tee "$SNIP" >/dev/null
for ((i=0;i<${#PARTS[@]};i++)); do
  fs="${fstypes[$i]}"
  uuid="${UUIDS[$i]}"
  mp="${MOUNT_BASE}$((i+1))"
  # sensible defaults per FS
  opts="defaults,noatime"
  dump=0
  pass=2
  if [[ "$fs" == "xfs" ]]; then pass=0; fi
  echo "# ${mp} (${fs})" | tee -a "$SNIP" >/dev/null
  echo "# UUID=$uuid  $mp  $fs  $opts  $dump  $pass" | tee -a "$SNIP" >/dev/null
  echo | tee -a "$SNIP" >/dev/null
done

echo
log "Commented fstab snippet written to: $SNIP"
echo "Review and then append (uncomment) to /etc/fstab as needed."

# ---- optional mount now ----
if [[ $MOUNT_NOW -eq 1 && $DRY_RUN -eq 0 ]]; then
  for ((i=0;i<${#PARTS[@]};i++)); do
    mp="${MOUNT_BASE}$((i+1))"
    p="${PARTS[$i]}"
    run "mount '$p' '$mp'"
  done
  log "Mounted new filesystems under $MOUNT_BASE*"
fi

log "Done."
