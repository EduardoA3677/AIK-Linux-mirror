#!/bin/bash
# AIK-Linux/unpackimg: split image and unpack ramdisk
# osm0sis @ xda-developers
# Modificado para soporte de vendor_boot v4

cleanup() { "$aik/cleanup.sh" $local --quiet; }
abort() { echo "Error!"; }

case $1 in
  --help) echo "usage: unpackimg.sh [--local] [--nosudo] <file>"; exit 1;;
  --local) local="--local"; shift;;
esac;
case $1 in
  --nosudo) nosudo=1; shift;;
  --sudo) shift;;
esac;
if [ ! "$nosudo" ]; then
  sudo=sudo; sumsg=" (as root)";
fi;

case $(uname -s) in
  Darwin|Macintosh)
    plat="macos";
    readlink() { perl -MCwd -e 'print Cwd::abs_path shift' "$2"; }
  ;;
  *) plat="linux";;
esac;
arch=$plat/`uname -m`;

aik="${BASH_SOURCE:-$0}";
aik="$(dirname "$(readlink -f "$aik")")";
bin="$aik/bin";
cur="$(readlink -f "$PWD")";

case $plat in
  macos)
    cpio="env DYLD_LIBRARY_PATH="$bin/$arch" "$bin/$arch/cpio"";
    statarg="-f %Su";
    dd() { DYLD_LIBRARY_PATH="$bin/$arch" "$bin/$arch/dd" "$@"; }
    file() { DYLD_LIBRARY_PATH="$bin/$arch" "$bin/$arch/file" "$@"; }
    lzma() { DYLD_LIBRARY_PATH="$bin/$arch" "$bin/$arch/xz" "$@"; }
    lzop() { DYLD_LIBRARY_PATH="$bin/$arch" "$bin/$arch/lzop" "$@"; }
    tail() { DYLD_LIBRARY_PATH="$bin/$arch" "$bin/$arch/tail" "$@"; }
    truncate() { DYLD_LIBRARY_PATH="$bin/$arch" "$bin/$arch/truncate" "$@"; }
    xz() { DYLD_LIBRARY_PATH="$bin/$arch" "$bin/$arch/xz" "$@"; }
  ;;
  linux)
    cpio=cpio;
    [ "$(cpio --version | head -n1 | rev | cut -d\  -f1 | rev)" = "2.13" ] && cpiowarning=1;
    statarg="-c %U";
  ;;
esac;

if [ ! "$local" ]; then
  cd "$aik";
fi;
chmod -R 755 "$bin" "$aik"/*.sh;
chmod 644 "$bin/magic" "$bin/androidbootimg.magic" "$bin/androidsign.magic" "$bin/boot_signer.jar" "$bin/avb/"* "$bin/chromeos/"*;

img="$1";
[ -f "$cur/$1" ] && img="$cur/$1";
if [ ! "$img" ]; then
  while IFS= read -r line; do
    case $line in
      aboot.img|image-new.img|unlokied-new.img|unsigned-new.img) continue;;
    esac;
    img="$line";
    break;
  done < <(ls *.elf *.img *.sin 2>/dev/null);
fi;
img="$(readlink -f "$img")";
if [ ! -f "$img" ]; then
  echo "No image file supplied.";
  abort;
  exit 1;
fi;

clear;
echo " ";
echo "Android Image Kitchen - UnpackImg Script";
echo "by osm0sis @ xda-developers";
echo " ";

file=$(basename "$img");
echo "Supplied image: $file";
echo " ";

if [ -d split_img -o -d ramdisk ]; then
  if [ -d ramdisk ] && [ "$(stat $statarg ramdisk | head -n 1)" = "root" -o ! "$(find ramdisk 2>&1 | cpio -o >/dev/null 2>&1; echo $?)" -eq "0" ]; then
    rmsumsg=" (as root)";
  fi;
  echo "Removing old work folders and files$rmsumsg...";
  echo " ";
  cleanup;
fi;

echo "Setting up work folders...";
echo " ";
mkdir split_img ramdisk;

cd split_img;
filesize=$(wc -c < "$img");
echo "$filesize" > "$file-origsize";
imgtest="$(file -m "$bin/androidsign.magic" "$img" 2>/dev/null | cut -d: -f2-)";
if [ "$(echo $imgtest | awk '{ print $2 }' | cut -d, -f1)" = "signing" ]; then
  echo $imgtest | awk '{ print $1 }' > "$file-sigtype";
  sigtype=$(cat "$file-sigtype");
  echo "Signature with \"$sigtype\" type detected, removing...";
  echo " ";
  case $sigtype in
    BLOB)
      cp -f "$img" "$file";
      "$bin/$arch/blobunpack" "$file" | tail -n+5 | cut -d" " -f2 | dd bs=1 count=3 > "$file-blobtype" 2>/dev/null;
      mv -f "$file."* "$file";
    ;;
    CHROMEOS) "$bin/$arch/futility" vbutil_kernel --get-vmlinuz "$img" --vmlinuz-out "$file";;
    DHTB) dd bs=4096 skip=512 iflag=skip_bytes conv=notrunc if="$img" of="$file" 2>/dev/null;;
    NOOK)
      dd bs=1048576 count=1 conv=notrunc if="$img" of="$file-master_boot.key" 2>/dev/null;
      dd bs=1048576 skip=1 conv=notrunc if="$img" of="$file" 2>/dev/null;
    ;;
    NOOKTAB)
      dd bs=262144 count=1 conv=notrunc if="$img" of="$file-master_boot.key" 2>/dev/null;
      dd bs=262144 skip=1 conv=notrunc if="$img" of="$file" 2>/dev/null;
    ;;
    SIN*)
      "$bin/$arch/sony_dump" . "$img" >/dev/null;
      mv -f "$file."* "$file";
      rm -f "$file-sigtype";
    ;;
  esac;
  [ -f "$file" ] && img="$file";
fi;

imgtest="$(file -m "$bin/androidbootimg.magic" "$img" 2>/dev/null | cut -d: -f2-)";
if [ "$(echo $imgtest | awk '{ print $2 }' | cut -d, -f1)" = "bootimg" ]; then
  [ "$(echo $imgtest | awk '{ print $3 }')" = "PXA" ] && typesuffix=-PXA;
  echo "$(echo $imgtest | awk '{ print $1 }')$typesuffix" > "$file-imgtype";
  imgtype=$(cat "$file-imgtype");
else
  cd ..;
  cleanup;
  echo "Unrecognized format.";
  abort;
  exit 1;
fi;
echo "Image type: $imgtype";
echo " ";

case $imgtype in
  AOSP*|ELF|KRNL|OSIP|U-Boot) ;;
  *)
    cd ..;
    cleanup;
    echo "Unsupported format.";
    abort;
    exit 1;
  ;;
esac;

case $(echo $imgtest | awk '{ print $3 }') in
  LOKI)
    echo $imgtest | awk '{ print $5 }' | cut -d\( -f2 | cut -d\) -f1 > "$file-lokitype";
    lokitype=$(cat "$file-lokitype");
    echo "Loki patch with \"$lokitype\" type detected, reverting...";
    echo " ";
    echo "Warning: A dump of your device's aboot.img is required to re-Loki!";
    echo " ";
    "$bin/$arch/loki_tool" unlok "$img" "$file" >/dev/null;
    img="$file";
  ;;
  AMONET)
    echo "Amonet patch detected, reverting...";
    echo " ";
    dd bs=2048 count=1 conv=notrunc if="$img" of="$file-microloader.bin" 2>/dev/null;
    dd bs=1024 skip=1 conv=notrunc if="$file-microloader.bin" of="$file-head" 2>/dev/null;
    truncate -s 1024 "$file-microloader.bin";
    truncate -s 2048 "$file-head";
    dd bs=2048 skip=1 conv=notrunc if="$img" of="$file-tail" 2>/dev/null;
    cat "$file-head" "$file-tail" > "$file";
    rm -f "$file-head" "$file-tail";
    img="$file";
  ;;
esac;

tailtest="$(dd if="$img" iflag=skip_bytes skip=$(($(wc -c < "$img") - 8192)) bs=8192 count=1 2>/dev/null | file -m $bin/androidsign.magic - 2>/dev/null | cut -d: -f2-)";
case $tailtest in
  *data) tailtest="$(tail -n50 "$img" | file -m "$bin/androidsign.magic" - 2>/dev/null | cut -d: -f2-)";;
esac;
tailtype="$(echo $tailtest | awk '{ print $1 }')";
case $tailtype in
  AVB*)
    echo "Signature with \"$tailtype\" type detected.";
    echo " ";
    echo $tailtype > "$file-sigtype";
    case $tailtype in
      *v1)
        echo $tailtest | awk '{ print $4 }' > "$file-avbtype";
      ;;
    esac;
  ;;
  Bump|SEAndroid)
    echo "Footer with \"$tailtype\" type detected.";
    echo " ";
    echo $tailtype > "$file-tailtype";
  ;;
esac;

if [ "$imgtype" = "U-Boot" ]; then
  imgsize=$(($(printf '%d\n' 0x$(hexdump -n 4 -s 12 -e '16/1 "%02x""\n"' "$img")) + 64));
  if [ ! "$filesize" = "$imgsize" ]; then
    echo "Trimming...";
    echo " ";
    dd bs=$imgsize count=1 conv=notrunc if="$img" of="$file" 2>/dev/null;
    img="$file";
  fi;
fi;

echo 'Splitting image to "split_img/"...';
case $imgtype in
  AOSP_VNDR) 
    vendor=vendor_;
    # Extraer el header version
    header_version=$(hexdump -n 48 -s 44 -e '1/4 "%d"' "$img" 2>/dev/null)
    echo "Detected vendor_boot.img with header version: $header_version"
    echo "$header_version" > "$file-header_version"
    
    if [[ "$header_version" == "4" ]]; then
      echo "Processing vendor_boot v4 ramdisk table"
      echo "$header_version" > "$file-header_version"
      
      # Usar unpackbootimg para extraer componentes básicos
      "$bin/$arch/unpackbootimg" -i "$img"
      
      # Crear directorio para vendor_ramdisk si no existe
      mkdir -p ../vendor_ramdisk
      
      # Extraer y procesar vendor_ramdisk_table
      if [ -f "$file-vendor_ramdisk" ]; then
        # Guardar el tamaño del vendor_ramdisk
        wc -c < "$file-vendor_ramdisk" > "$file-vendor_ramdisk_size"
        echo "Extracted vendor_ramdisk size: $(cat "$file-vendor_ramdisk_size") bytes"
        
        # Extraer vendor_ramdisk_table (los primeros 108 bytes después del ramdisk)
        dd if="$file-vendor_ramdisk" of="$file-vendor_ramdisk_table" bs=108 count=1 2>/dev/null
        echo "Extracted vendor_ramdisk_table size: $(wc -c < "$file-vendor_ramdisk_table") bytes"
        
        # Mostrar contenido de la tabla para depuración
        echo "Processing $(($(wc -c < "$file-vendor_ramdisk_table") / 108)) ramdisk fragments"
        hexdump -C "$file-vendor_ramdisk_table" | head -16
        
        # Mover el vendor_ramdisk para su posterior descompresión
        mv "$file-vendor_ramdisk" "$file-vendor_ramdisk.packed"
      fi
      
      # Finalizando
      echo "Final ramdisk.packed size: $(wc -c < "$file-vendor_ramdisk.packed") bytes"
    else
      # Usar unpackbootimg estándar para versiones anteriores
      "$bin/$arch/unpackbootimg" -i "$img"
    fi
  ;;
  AOSP) "$bin/$arch/unpackbootimg" -i "$img";;
  AOSP-PXA) "$bin/$arch/pxa-unpackbootimg" -i "$img";;
  ELF)
    mkdir elftool_out;
    "$bin/$arch/elftool" unpack -i "$img" -o elftool_out >/dev/null;
    mv -f elftool_out/header "$file-header" 2>/dev/null;
    rm -rf elftool_out;
    "$bin/$arch/unpackelf" -i "$img";
  ;;
  KRNL) dd bs=4096 skip=8 iflag=skip_bytes conv=notrunc if="$img" of="$file-ramdisk" 2>&1 | tail -n+3 | cut -d" " -f1-2;;
  OSIP)
    "$bin/$arch/mboot" -u -f "$img";
    [ ! $? -eq "0" ] && error=1;
    for i in bootstub cmdline.txt hdr kernel parameter ramdisk.cpio.gz sig; do
      mv -f $i "$file-$(basename $i .txt | sed -e 's/hdr/header/' -e 's/ramdisk.cpio.gz/ramdisk/')" 2>/dev/null || true;
    done;
  ;;
  U-Boot)
    "$bin/$arch/dumpimage" -l "$img";
    "$bin/$arch/dumpimage" -l "$img" > "$file-header";
    grep "Name:" "$file-header" | cut -c15- > "$file-name";
    grep "Type:" "$file-header" | cut -c15- | cut -d" " -f1 > "$file-arch";
    grep "Type:" "$file-header" | cut -c15- | cut -d" " -f2 > "$file-os";
    grep "Type:" "$file-header" | cut -c15- | cut -d" " -f3 | cut -d- -f1 > "$file-type";
    grep "Type:" "$file-header" | cut -d\( -f2 | cut -d\) -f1 | cut -d" " -f1 | cut -d- -f1 > "$file-comp";
    grep "Address:" "$file-header" | cut -c15- > "$file-addr";
    grep "Point:" "$file-header" | cut -c15- > "$file-ep";
    rm -f "$file-header";
    "$bin/$arch/dumpimage" -p 0 -o "$file-kernel" "$img";
    [ ! $? -eq "0" ] && error=1;
    case $(cat "$file-type") in
      Multi) "$bin/$arch/dumpimage" -p 1 -o "$file-ramdisk" "$img";;
      RAMDisk) mv -f "$file-kernel" "$file-ramdisk";;
      *) touch "$file-ramdisk";;
    esac;
  ;;
esac;
if [ ! $? -eq "0" -o "$error" ]; then
  cd ..;
  cleanup;
  abort;
  exit 1;
fi;

if [ -f *-kernel ] && [ "$(file -m "$bin/androidbootimg.magic" *-kernel 2>/dev/null | cut -d: -f2 | awk '{ print $1 }')" = "MTK" ]; then
  mtk=1;
  echo " ";
  echo "MTK header found in kernel, removing...";
  dd bs=512 skip=1 conv=notrunc if="$file-kernel" of=tempkern 2>/dev/null;
  mv -f tempkern "$file-kernel";
fi;

# Manejar ramdisk normal o vendor_ramdisk
if [ "$header_version" == "4" ] && [ -f "$file-vendor_ramdisk.packed" ]; then
  mtktest="$(file -m "$bin/androidbootimg.magic" "$file-vendor_ramdisk.packed" 2>/dev/null | cut -d: -f2-)";
else
  mtktest="$(file -m "$bin/androidbootimg.magic" *-*ramdisk 2>/dev/null | cut -d: -f2-)";
fi;

mtktype=$(echo $mtktest | awk '{ print $3 }');
if [ "$(echo $mtktest | awk '{ print $1 }')" = "MTK" ]; then
  if [ ! "$mtk" ]; then
    echo " ";
    echo "Warning: No MTK header found in kernel!";
    mtk=1;
  fi;
  if [ "$header_version" == "4" ] && [ -f "$file-vendor_ramdisk.packed" ]; then
    echo "MTK header found in \"$mtktype\" type vendor_ramdisk, removing...";
    dd bs=512 skip=1 conv=notrunc if="$file-vendor_ramdisk.packed" of=temprd 2>/dev/null;
    mv -f temprd "$file-vendor_ramdisk.packed";
  else
    echo "MTK header found in \"$mtktype\" type ramdisk, removing...";
    dd bs=512 skip=1 conv=notrunc if="$(ls *-*ramdisk)" of=temprd 2>/dev/null;
    mv -f temprd "$(ls *-*ramdisk)";
  fi;
else
  if [ "$mtk" ]; then
    if [ ! "$mtktype" ]; then
      echo 'Warning: No MTK header found in ramdisk, assuming "rootfs" type!';
      mtktype="rootfs";
    fi;
  fi;
fi;
[ "$mtk" ] && echo $mtktype > "$file-mtktype";

if [ -f *-dt ]; then
  dttest="$(file -m "$bin/androidbootimg.magic" *-dt 2>/dev/null | cut -d: -f2 | awk '{ print $1 }')";
  echo $dttest > "$file-dttype";
  if [ "$imgtype" = "ELF" ]; then
    case $dttest in
      QCDT|ELF) ;;
      *) echo " ";
         echo "Non-QC DTB found, packing kernel and appending...";
         gzip --no-name -9 "$file-kernel";
         mv -f "$file-kernel.gz" "$file-kernel";
         cat "$file-dt" >> "$file-kernel";
         rm -f "$file-dt"*;;
    esac;
  fi;
fi;

# Determinar qué archivo de ramdisk procesar
if [ "$header_version" == "4" ] && [ -f "$file-vendor_ramdisk.packed" ]; then
  ramdisk_file="$file-vendor_ramdisk.packed"
  ramdisk_prefix="vendor_"
else
  ramdisk_file="$(ls *-*ramdisk)"
  ramdisk_prefix="${vendor}"
fi;

file -m "$bin/magic" "$ramdisk_file" 2>/dev/null | cut -d: -f2 | awk '{ print $1 }' > "$file-${ramdisk_prefix}ramdiskcomp";
ramdiskcomp=`cat "$file-${ramdisk_prefix}ramdiskcomp"`;
unpackcmd="$ramdiskcomp -dc";
compext=$ramdiskcomp;
case $ramdiskcomp in
  gzip) unpackcmd="gzip -dcq"; compext=gz;;
  lzop) compext=lzo;;
  xz) ;;
  lzma) ;;
  bzip2) compext=bz2;;
  lz4) unpackcmd="$bin/$arch/lz4 -dcq";;
  lz4-l) unpackcmd="$bin/$arch/lz4 -dcq"; compext=lz4;;
  cpio) unpackcmd="cat"; compext="";;
  empty) compext=empty;;
  *) compext="";;
esac;
if [ "$compext" ]; then
  compext=.$compext;
fi;

# Mover el archivo de ramdisk con la extensión correcta
mv -f "$ramdisk_file" "$file-${ramdisk_prefix}ramdisk.cpio$compext" 2>/dev/null;
cd ..;
if [ "$ramdiskcomp" = "data" ]; then
  echo "Unrecognized format.";
  abort;
  exit 1;
fi;

echo " ";
if [ "$ramdiskcomp" = "empty" ]; then
  echo "Warning: No ramdisk found to be unpacked!";
else
  # Determinar el directorio de destino
  if [ "$header_version" == "4" ] && [ "$ramdisk_prefix" == "vendor_" ]; then
    ramdisk_dir="vendor_ramdisk"
    echo "Unpacking vendor_ramdisk$sumsg to \"vendor_ramdisk/\"...";
  else
    ramdisk_dir="ramdisk"
    echo "Unpacking ramdisk$sumsg to \"ramdisk/\"...";
  fi;
  
  echo " ";
  if [ "$cpiowarning" ]; then
    echo "Warning: Using cpio 2.13 may result in an unusable repack; downgrade to 2.12 to be safe!";
    echo " ";
  fi;
  echo "Compression used: $ramdiskcomp";
  if [ ! "$compext" -a ! "$ramdiskcomp" = "cpio" ]; then
    echo "Unsupported format.";
    abort;
    exit 1;
  fi;
  $sudo chown 0:0 $ramdisk_dir 2>/dev/null;
  cd $ramdisk_dir;
  $unpackcmd "../split_img/$file-${ramdisk_prefix}ramdisk.cpio$compext" | $sudo $cpio -i -d --no-absolute-filenames;
  if [ ! $? -eq "0" ]; then
    [ "$nosudo" ] && echo "Unpacking failed, try without --nosudo.";
    cd ..;
    abort;
    exit 1;
  fi;
  cd ..;
fi;

echo " ";
echo "Done!";
exit 0;
