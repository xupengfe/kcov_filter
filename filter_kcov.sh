#!/bin/bash

source "kcov_common.sh"

KERNEL_SRC="/home/code/os.linux.intelnext.kernel"
# v6.4: 6995e2de6891c724bfeb2db33d7b87775f913ad1
END_COMMIT="6995e2de6891c724bfeb2db33d7b87775f913ad1"
DATE=$(date +%y_%m%d_%H%M%S)
DEST="${BASE_PATH}/filter_kcov_${DATE}"
KCOV_LOG="${DEST}/kcov_filter.log"
KCOV_RESULT="${DEST}/kcov_result"
KCOV_DETAIL="${DEST}/kcov_detail"
PORT="10026"
BOOT_TIME="40"
IMAGE="/root/image/centos8_2.img"

usage() {
  cat <<__EOF
  usage: ./${0##*/}  [-k KERNEL][-m COMMIT][-c KCONFIG][-d DEST][-b bad][-f bz][-o][-h]
  -k  KERNEL source folder
  -m  COMMIT ID which will be used
  -c  Kconfig(optional) which will be used
  -d  Destination where bzImage will be copied
  -b  Bad commit
  -f  bzImage file name(optional)
  -o  Make kernel path
  -h  show this
__EOF
  echo "make_bz.sh parm invalid" >> "$KCOV_LOG"
  exit 1
}

prepare_bzimage() {
  local bzimage=$1
  local line=$2

  # Could not use existed bzImage, because it needs to get the lines change when make bzImage!
  #if [[ -e "${DEST}/${bzimage}" ]]; then
  #  print_log "bzImage:${DEST}/${bzimage} already exists, no need make!" "$KCOV_LOG"
  #else
  print_log "${BASE_PATH}/make_bz.sh -k $KERNEL_SRC -m $END_COMMIT -d $DEST -o $KERNEL_PATH -f $bzimage -l $line" "$KCOV_LOG"
  cd "$BASE_PATH" || {
    print_log "Access $BASE_PATH failed" "$KCOV_LOG"
    exit 1
  }
  ${BASE_PATH}/make_bz.sh -k "$KERNEL_SRC" -m "$END_COMMIT" -d "$DEST" -o "$KERNEL_PATH" -f "$bzimage" -l "$line"
  #fi
}

clean_old_vm() {
  local old_vm=""

  old_vm=$(ps -ef | grep qemu | grep $PORT  | awk -F " " '{print $2}')

  [[ -z "$old_vm" ]] || {
    print_log "Kill old $PORT qemu:$old_vm"
    kill -9 "$old_vm"
  }
}

test_bz() {
  local bz_file=$1
  local line=$2
  local check_bz=""
  local check_boot=""
  local check_umip=""
  # i: real boot time.
  local i=1
  # Boot up vm failed sometimes, so add the max boot try loop.
  local boot_try_max=10
  local try_num=1

  clean_old_vm
  check_bz=$(ls "$bz_file" 2>/dev/null)
  if [[ -z "$check_bz" ]]; then
    print_err "bzImage:$bz_file does not exist:$check_bz" "$KCOV_LOG"
    exit 1
  fi

  # Add max boot time loop check to reduce bisect failed times
  for ((try_num=1;try_num<=boot_try_max;try_num++)); do
    print_log "Run $bz_file with image:$IMAGE in local port:$PORT, $try_num time" "$KCOV_LOG"
    qemu-system-x86_64 \
      -m 2G \
      -smp 2 \
      -kernel $bz_file \
      -append "console=ttyS0 root=/dev/sda earlyprintk=serial net.ifnames=0 quiet plymouth.enable=0" \
      -drive file=${IMAGE},format=raw \
      -net user,host=10.0.2.10,hostfwd=tcp:127.0.0.1:${PORT}-:22 \
      -cpu host \
      -net nic,model=e1000 \
      -enable-kvm \
      -nographic \
      2>&1 | tee > ${DEST}/${line}_dmesg.log &

    # One time boot time check
    for ((i=1;i<=BOOT_TIME;i++)); do
      sleep 1
      check_boot=""
      check_boot=$(cat ${DEST}/${line}_dmesg.log | grep  " login\:")
      [[ -n "$check_boot" ]] && {
        print_log "It takes $i seconds to find login:$check_boot" "$KCOV_LOG"
        break
      }
    done

    # The real boot time should less than BOOT_TIME
    if [[ "$i" -ge "$BOOT_TIME" ]]; then
      check_umip=""
      check_umip=$(cat ${DEST}/${line}_dmesg.log | grep  "UMIP")
      if [[ -n "$check_umip" ]]; then
        print_log "Boot $try_num time: takes $i seconds >= $BOOT_TIME and has UMIP dmesg, retry" "$KCOV_LOG"
        # If this time boot VM timeout, need to clean old vm.
      else
        print_log "Boot $try_num time: takes $i seconds >= $BOOT_TIME and no UMIP dmesg, KCOV nok." "$KCOV_LOG"
        print_log "$KCOV_ORI:$(cat "$KCOV_ORI") in $KCOV_RESULT" "$KCOV_LOG"
        cat "$KCOV_ORI" >> "$KCOV_RESULT"
        echo "Line:$line" >> "$KCOV_DETAIL"
        cat "$KCOV_ORI" >> "$KCOV_DETAIL"
        echo "-NOK- Boot $try_num time: takes $i seconds >= $BOOT_TIME and no UMIP dmesg, KCOV nok." >> "$KCOV_DETAIL"
        clean_old_vm
        return 1
      fi
      clean_old_vm
    else
      print_log "Boot $bz_file $try_num time: takes $i seconds to boot up." "$KCOV_LOG"
      cat "$KCOV_TAR" >> "$KCOV_RESULT"
      echo "Line:$line" >> "$KCOV_DETAIL"
      cat "$KCOV_TAR" >> "$KCOV_DETAIL"
      echo "-OK- Boot $try_num time: takes $i seconds to boot up, KCOV ok." >> "$KCOV_DETAIL"
      # The VM is not useful anymore
      clean_old_vm
      break
    fi

    # If boot boot_try_max times failed, will exit
    if [[ "$try_num" -ge "$boot_try_max" ]]; then
      print_log "Boot $try_num >=$boot_try_max times failed, bzImage:$bz_file, exit!" "$KCOV_LOG"
      cat "$KCOV_ORI" >> "$KCOV_RESULT"
      echo "Line:$line" >> "$KCOV_DETAIL"
      cat "$KCOV_ORI" >> "$KCOV_DETAIL"
      echo "-NOK- Boot $try_num >=$boot_try_max try boot max times failed, bzImage:$bz_file, KCOV nok." >> "$KCOV_DETAIL"
      clean_old_vm
      return 1
    fi
  done
}

filter_kcov() {
  local line=42
  local bz=""
  local bz_file=""

  cat /dev/null > "$KCOV_RESULT"
  cat /dev/null > "$KCOV_DETAIL"

  [[ -d "$DEST" ]] || {
    rm -rf $DEST
    mkdir -p $DEST
  }

  for((line=42;line<=143;line++)); do
    bz=""
    bz_file=""
    bz="bzImage-${line}"
    bz_file="${DEST}/${bz}"
    print_log "prepare_bzimage $bz" "$KCOV_LOG"
    prepare_bzimage "$bz" "$line"

    if [[ -e "$bz_file" ]]; then
      print_log "Find $bz_file" "$KCOV_LOG"
    else
      print_log "No $bz_file, exit!" "$KCOV_LOG"
      exit 1
    fi

    print_log "$bz_file $line" "$KCOV_LOG"
    test_bz "$bz_file" "$line"
  done
  print_log "All kcov filter test is done!" "$KCOV_LOG"
}

filter_kcov
