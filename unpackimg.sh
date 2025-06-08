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

if [ -d split_img -o -d ramdisk -o -d vendor_ramdisk ]; then
  if [ -d ramdisk ] && [ "$(stat $statarg ramdisk | head -n 1)" = "root" -o ! "$(find ramdisk 2>&1 | cpio -o >/dev/null 2>&1; echo $?)" -eq "0" ]; then
    rmsumsg=" (as root)";
  fi;
  if [ -d vendor_ramdisk ] && [ "$(stat $statarg vendor_ramdisk | head -n 1)" = "root" -o ! "$(find vendor_ramdisk 2>&1 | cpio -o >/dev/null 2>&1; echo $?)" -eq "0" ]; then
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

# Detectar tipo de imagen usando magic numbers
boot_magic=$(dd if="$img" bs=8 count=1 2>/dev/null)
if [ "$boot_magic" = "VNDRBOOT" ]; then
  echo "AOSP_VNDR" > "$file-imgtype";
  imgtype="AOSP_VNDR";
  vendor=vendor_;
  
  # Extraer header version para vendor_boot
  header_version=$(dd if="$img" bs=1 skip=12 count=4 2>/dev/null | od -An -t u4 -N4 | tr -d ' ')
  echo "Detected vendor_boot.img with header version: $header_version"
  echo "$header_version" > "$file-header_version"
  
elif [ "$boot_magic" = "ANDROID!" ]; then
  echo "AOSP" > "$file-imgtype";
  imgtype="AOSP";
  
  # Extraer header version para boot normal
  header_version=$(dd if="$img" bs=1 skip=40 count=4 2>/dev/null | od -An -t u4 -N4 | tr -d ' ')
  echo "Detected boot.img with header version: $header_version"
  echo "$header_version" > "$file-header_version"
else
  # Fallback al método original
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
fi;

echo "Image type: $imgtype";
echo " ";

# Detectar y manejar vendor_boot v4 usando la lógica de AOSP
if [ "$imgtype" = "AOSP_VNDR" ] && [ "$header_version" = "4" ]; then
  echo "Processing vendor_boot v4 with multiple ramdisk fragments...";
  echo " ";
  
  # Crear directorio para vendor_ramdisk
  mkdir -p ../vendor_ramdisk;
  
  # Usar el extractor basado en la lógica de AOSP unpack_bootimg.py
  python3 -c "
import struct
import os
import sys

def cstr(s):
    return s.split(b'\0', 1)[0].decode()

def get_number_of_pages(image_size, page_size):
    return (image_size + page_size - 1) // page_size

def extract_image(img, offset, size, output_name):
    with open(img, 'rb') as f:
        f.seek(offset)
        data = f.read(size)
    with open(output_name, 'wb') as f:
        f.write(data)

# Leer vendor_boot v4
img_path = '$img'
with open(img_path, 'rb') as f:
    # Leer header básico
    magic = f.read(8)
    header_version = struct.unpack('<I', f.read(4))[0]
    page_size = struct.unpack('<I', f.read(4))[0]
    kernel_load_address = struct.unpack('<I', f.read(4))[0]
    ramdisk_load_address = struct.unpack('<I', f.read(4))[0]
    vendor_ramdisk_size = struct.unpack('<I', f.read(4))[0]
    
    # Saltar cmdline (2048 bytes)
    f.seek(8 + 4 + 4 + 4 + 4 + 4 + 2048)
    
    tags_load_address = struct.unpack('<I', f.read(4))[0]
    product_name = cstr(f.read(16))
    header_size = struct.unpack('<I', f.read(4))[0]
    dtb_size = struct.unpack('<I', f.read(4))[0]
    dtb_load_address = struct.unpack('<Q', f.read(8))[0]
    
    # Información específica de v4
    vendor_ramdisk_table_size = struct.unpack('<I', f.read(4))[0]
    vendor_ramdisk_table_entry_num = struct.unpack('<I', f.read(4))[0]
    vendor_ramdisk_table_entry_size = struct.unpack('<I', f.read(4))[0]
    vendor_bootconfig_size = struct.unpack('<I', f.read(4))[0]

# Guardar información extraída
with open('$file-page_size', 'w') as f:
    f.write(str(page_size))
with open('$file-vendor_ramdisk_size', 'w') as f:
    f.write(str(vendor_ramdisk_size))
with open('$file-vendor_ramdisk_table_size', 'w') as f:
    f.write(str(vendor_ramdisk_table_size))
with open('$file-vendor_ramdisk_table_entry_num', 'w') as f:
    f.write(str(vendor_ramdisk_table_entry_num))
with open('$file-vendor_bootconfig_size', 'w') as f:
    f.write(str(vendor_bootconfig_size))
with open('$file-board', 'w') as f:
    f.write(product_name)

# Calcular offsets según la lógica de AOSP
num_boot_header_pages = get_number_of_pages(header_size, page_size)
num_boot_ramdisk_pages = get_number_of_pages(vendor_ramdisk_size, page_size)
num_boot_dtb_pages = get_number_of_pages(dtb_size, page_size)
num_vendor_ramdisk_table_pages = get_number_of_pages(vendor_ramdisk_table_size, page_size)

ramdisk_offset_base = page_size * num_boot_header_pages
vendor_ramdisk_table_offset = page_size * (num_boot_header_pages + num_boot_ramdisk_pages + num_boot_dtb_pages)
dtb_offset = page_size * (num_boot_header_pages + num_boot_ramdisk_pages)
bootconfig_offset = page_size * (num_boot_header_pages + num_boot_ramdisk_pages + num_boot_dtb_pages + num_vendor_ramdisk_table_pages)

print(f'Vendor ramdisk size: {vendor_ramdisk_size}')
print(f'Vendor ramdisk table size: {vendor_ramdisk_table_size}')
print(f'Vendor ramdisk table entries: {vendor_ramdisk_table_entry_num}')
print(f'Vendor bootconfig size: {vendor_bootconfig_size}')

# Extraer vendor ramdisk fragments
for idx in range(vendor_ramdisk_table_entry_num):
    entry_offset = vendor_ramdisk_table_offset + (vendor_ramdisk_table_entry_size * idx)
    with open(img_path, 'rb') as f:
        f.seek(entry_offset)
        ramdisk_size = struct.unpack('<I', f.read(4))[0]
        ramdisk_offset = struct.unpack('<I', f.read(4))[0]
        ramdisk_type = struct.unpack('<I', f.read(4))[0]
        ramdisk_name = cstr(f.read(32))
        board_id = struct.unpack('<16I', f.read(16 * 4))
    
    output_name = f'$file-vendor_ramdisk{idx:02d}'
    extract_image(img_path, ramdisk_offset_base + ramdisk_offset, ramdisk_size, output_name)
    print(f'Extracted {output_name} (size: {ramdisk_size}, type: {ramdisk_type:#x}, name: {ramdisk_name})')

# Extraer DTB si existe
if dtb_size > 0:
    extract_image(img_path, dtb_offset, dtb_size, '$file-dtb')
    print(f'Extracted DTB (size: {dtb_size})')

# Extraer bootconfig si existe  
if vendor_bootconfig_size > 0:
    extract_image(img_path, bootconfig_offset, vendor_bootconfig_size, '$file-bootconfig')
    print(f'Extracted bootconfig (size: {vendor_bootconfig_size})')

# Determinar cuál vendor_ramdisk usar como principal
main_ramdisk = None
for idx in range(vendor_ramdisk_table_entry_num):
    ramdisk_file = f'$file-vendor_ramdisk{idx:02d}'
    if os.path.exists(ramdisk_file) and os.path.getsize(ramdisk_file) > 0:
        main_ramdisk = ramdisk_file
        break

if main_ramdisk:
    # Copiar el ramdisk principal
    import shutil
    shutil.copy(main_ramdisk, '$file-vendor_ramdisk')
    print(f'Using {main_ramdisk} as main vendor_ramdisk')
else:
    # Crear un ramdisk vacío si no hay ninguno válido
    with open('$file-vendor_ramdisk', 'wb') as f:
        pass
    print('No valid vendor_ramdisk found, created empty file')
"
  
  if [ $? -ne 0 ]; then
    echo "Failed to extract vendor_boot v4";
    cd ..;
    cleanup;
    abort;
    exit 1;
  fi;
  
  # Determinar qué ramdisk procesar
  main_ramdisk=""
  ramdisk_count=$(cat "$file-vendor_ramdisk_table_entry_num" 2>/dev/null || echo "0")
  
  for i in $(seq 0 $((ramdisk_count - 1))); do
    fragment_file=$(printf "$file-vendor_ramdisk%02d" $i)
    if [ -f "$fragment_file" ] && [ -s "$fragment_file" ]; then
      main_ramdisk="$fragment_file"
      echo "Selected $main_ramdisk as main ramdisk for unpacking"
      break
    fi
  done
  
  if [ -z "$main_ramdisk" ]; then
    echo "Warning: No valid vendor_ramdisk fragments found!"
    touch "$file-vendor_ramdisk"
  else
    cp "$main_ramdisk" "$file-vendor_ramdisk"
  fi
  
else
  # Usar unpackbootimg estándar para otros tipos
  case $imgtype in
    AOSP_VNDR) 
      vendor=vendor_;
      "$bin/$arch/unpackbootimg" -i "$img"
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
fi;

if [ -f *-kernel ] && [ "$(file -m "$bin/androidbootimg.magic" *-kernel 2>/dev/null | cut -d: -f2 | awk '{ print $1 }')" = "MTK" ]; then
  mtk=1;
  echo " ";
  echo "MTK header found in kernel, removing...";
  dd bs=512 skip=1 conv=notrunc if="$file-kernel" of=tempkern 2>/dev/null;
  mv -f tempkern "$file-kernel";
fi;

# Determinar qué archivo de ramdisk procesar
if [ "$imgtype" = "AOSP_VNDR" ] && [ "$header_version" = "4" ]; then
  ramdisk_file="$file-vendor_ramdisk"
  ramdisk_prefix="vendor_"
  ramdisk_dir="vendor_ramdisk"
  mkdir -p "../$ramdisk_dir"
elif [ "$vendor" = "vendor_" ]; then
  ramdisk_file="$(ls *-*vendor*ramdisk 2>/dev/null | head -1)"
  ramdisk_prefix="vendor_"
  ramdisk_dir="ramdisk"
else
  ramdisk_file="$(ls *-*ramdisk 2>/dev/null | head -1)"
  ramdisk_prefix=""
  ramdisk_dir="ramdisk"
fi;

if [ -z "$ramdisk_file" ] || [ ! -f "$ramdisk_file" ]; then
  echo "Warning: No ramdisk file found!";
  touch "$file-${ramdisk_prefix}ramdisk"
  ramdisk_file="$file-${ramdisk_prefix}ramdisk"
fi;

# Verificar MTK en ramdisk
mtktest="$(file -m "$bin/androidbootimg.magic" "$ramdisk_file" 2>/dev/null | cut -d: -f2-)";
mtktype=$(echo $mtktest | awk '{ print $3 }');
if [ "$(echo $mtktest | awk '{ print $1 }')" = "MTK" ]; then
  if [ ! "$mtk" ]; then
    echo " ";
    echo "Warning: No MTK header found in kernel!";
    mtk=1;
  fi;
  echo "MTK header found in \"$mtktype\" type ramdisk, removing...";
  dd bs=512 skip=1 conv=notrunc if="$ramdisk_file" of=temprd 2>/dev/null;
  mv -f temprd "$ramdisk_file";
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

# Detectar compresión del ramdisk
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
  echo "Unpacking ramdisk$sumsg to \"$ramdisk_dir/\"...";
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
