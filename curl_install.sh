#!/bin/bash
#Steam Deck Mount External Drive by scawp
#License: DBAD: https://github.com/scawp/Steam-Deck.Mount-External-Drive/blob/main/LICENSE.md
#Source: https://github.com/scawp/Steam-Deck.Mount-External-Drive
# Use at own Risk!

#curl -sSL https://raw.githubusercontent.com/scawp/Steam-Deck.Mount-External-Drive/main/curl_install.sh | bash

#stop running script if anything returns an error (non-zero exit )
set -e

repo_url="https://raw.githubusercontent.com/scawp/Steam-Deck.Mount-External-Drive/main"
repo_lib_dir="$repo_url/lib"

tmp_dir="/tmp/scawp.SDMED.install"

rules_install_dir="/etc/udev/rules.d"
service_install_dir="/etc/systemd/system"
script_install_dir="/home/deck/.local/share/scawp/SDMED"

device_name="$(uname --nodename)"
user="$(id -u deck)"

if [ "$device_name" != "steamdeck" ] || [ "$user" != "1000" ]; then
  zenity --question --width=400 \
  --text="This code has been written specifically for the Steam Deck with user Deck \
  \nIt appears you are running on a different system/non-standard configuration. \
  \nAre you sure you want to continue?"
  if [ "$?" != 0 ]; then
    #NOTE: This code will never be reached due to "set -e", the system will already exit for us but just incase keep this
    echo "bye then! xxx"
    exit 1;
  fi
fi

function select_internal_partitions () {
  local nvme_disk="/dev/nvme0n1"
  local rules_file="$1"

  if [ ! -b "$nvme_disk" ]; then
    return 0
  fi

  # List nvme0n1 partitions that have a filesystem and aren't currently one of
  # SteamOS's active system mountpoints. No assumption is made about *which*
  # partition numbers are "internal extra" partitions vs SteamOS's own
  # rootfs-A/B, var-A/B, home (that varies by disk layout, eg. dual-boot)
  # -- the user picks explicitly below.
  local rows
  rows=$(lsblk -o NAME,FSTYPE,MOUNTPOINT,LABEL,PARTLABEL,SIZE --json "$nvme_disk" \
    | jq -r '.blockdevices[0].children // []
        | .[]
        | select(.fstype != null)
        | select((.mountpoint // "") as $m | (["/","/home","/var","/esp","/efi"] | index($m)) | not)
        | [.name, (.label // ""), (.partlabel // ""), .fstype, .size] | @tsv')

  if [ -z "$rows" ]; then
    echo "No selectable internal nvme0n1 partitions found, skipping internal partition selection"
    return 0
  fi

  local zenity_items=()
  while IFS=$'\t' read -r p_name p_label p_partlabel p_fstype p_size; do
    zenity_items+=(FALSE "$p_name" "$p_label" "$p_partlabel" "$p_fstype" "$p_size")
  done <<< "$rows"

  local selected
  selected=$(zenity --list --checklist --width=700 --height=400 \
    --title="Select Internal Partitions to Auto-Mount" \
    --text="Choose which internal nvme0n1 partitions should be Auto-Mounted (eg. extra dual-boot/data partitions). \
\nSteamOS's currently active system partitions (/, /home, /var, /esp, /efi) are already hidden from this list. \
\nDo NOT select SteamOS's own inactive update slots (PartLabel rootfs-A/B or var-A/B) unless you know what you are doing -- these are not meant to be mounted. \
\nLeave everything unchecked if you don't want any internal partitions Auto-Mounted." \
    --column="Mount" --column="Partition" --column="Label" --column="PartLabel" --column="FSType" --column="Size" \
    --print-column=2 --separator="|" \
    "${zenity_items[@]}") || selected=""

  if [ -n "$selected" ]; then
    echo "Adding rules for selected internal partitions: $selected"
    {
      echo "KERNEL==\"${selected}\", ACTION==\"add\", RUN+=\"/bin/systemctl start --no-block external-drive-mount@%k.service\""
      echo "KERNEL==\"${selected}\", ACTION==\"remove\", RUN+=\"/bin/systemctl stop --no-block external-drive-mount@%k.service\""
    } >> "$rules_file"
  else
    echo "No internal partitions selected, none will be Auto-Mounted"
  fi
}

function install_automount () {
  zenity --question --width=400 \
    --text="Read $repo_url/README.md before proceeding. \
  \nDo you want to install the Auto-Mount Service?"
  if [ "$?" != 0 ]; then
    #NOTE: This code will never be reached due to "set -e", the system will already exit for us but just incase keep this
    echo "bye then! xxx"
    exit 0;
  fi

  echo "Making tmp folder $tmp_dir"
  mkdir -p "$tmp_dir"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

  if [ -n "$script_dir" ] && [ -f "$script_dir/automount.sh" ] && \
     [ -f "$script_dir/lib/external-drive-mount@.service" ] && \
     [ -f "$script_dir/lib/99-steamos-automount.rules" ]; then
    echo "Running from a local checkout ($script_dir), installing local files instead of downloading"
    cp "$script_dir/automount.sh" "$tmp_dir/automount.sh"
    cp "$script_dir/lib/external-drive-mount@.service" "$tmp_dir/external-drive-mount@.service"
    cp "$script_dir/lib/99-steamos-automount.rules" "$tmp_dir/99-steamos-automount.rules"
  else
    echo "Downloading Required Files"
    curl -o "$tmp_dir/automount.sh" "$repo_url/automount.sh"
    curl -o "$tmp_dir/external-drive-mount@.service" "$repo_lib_dir/external-drive-mount@.service"
    curl -o "$tmp_dir/99-steamos-automount.rules" "$repo_lib_dir/99-steamos-automount.rules"
  fi

  select_internal_partitions "$tmp_dir/99-steamos-automount.rules"

  echo "Making script folder $script_install_dir"
  mkdir -p "$script_install_dir"

  echo "Copying $tmp_dir/automount.sh to $script_install_dir/automount.sh"
  sudo cp "$tmp_dir/automount.sh" "$script_install_dir/automount.sh"

  echo "Adding Execute and Removing Write Permissions"
  sudo chmod 555 $script_install_dir/automount.sh

  echo "Copying $tmp_dir/99-steamos-automount.rules to $rules_install_dir/99-steamos-automount.rules"
  sudo cp "$tmp_dir/99-steamos-automount.rules" "$rules_install_dir/99-steamos-automount.rules"
  
  #remove old rules if installed
  if [ -f "$rules_install_dir/99-external-drive-mount.rules" ]; then
    sudo rm "$rules_install_dir/99-external-drive-mount.rules"
  fi
  
  if [ -f "$rules_install_dir/98-external-drive-mount.rules" ]; then
    sudo rm "$rules_install_dir/98-external-drive-mount.rules"
  fi

  echo "Copying $tmp_dir/external-drive-mount@.service to $service_install_dir/external-drive-mount@.service"
  sudo cp "$tmp_dir/external-drive-mount@.service" "$service_install_dir/external-drive-mount@.service"

  echo "Preserving our files across SteamOS atomic updates"
  sudo mkdir -p /etc/atomic-update.conf.d
  sudo tee /etc/atomic-update.conf.d/external-drive-mount.conf > /dev/null <<EOF
$rules_install_dir/99-steamos-automount.rules
$service_install_dir/external-drive-mount@.service
EOF

  echo "Reloading Services"
  sudo udevadm control --reload
  sudo systemctl daemon-reload
}

install_automount

zenity --question --width=400 \
  --text="Restart Required to take effect, \
\nDo you want to Restart Now?"
if [ "$?" != 0 ]; then
  #NOTE: This code will never be reached due to "set -e", the system will already exit for us but just incase keep this
  echo "bye then! xxx"
  exit 0;
fi

reboot

echo "Done."
