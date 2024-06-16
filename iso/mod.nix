{ nixpkgsPath, extraFiles }:
# Mostly copied from somewhere, with the following changes:
# * Removing unused stuff, boot menu, etc
# * Add ssh keys
# * RO root, no overlay on nixpkgs
({ config, lib, pkgs, ... }:
with lib;
let
  volumeID = "2snbb7usjflvboo6";
  grubPkgs = if config.boot.loader.grub.forcei686 then pkgs.pkgsi686Linux else pkgs;
  targetArch =
    if config.boot.loader.grub.forcei686 then
      "ia32"
    else
      pkgs.stdenv.hostPlatform.efiArch;

  # The EFI boot image.
  # Notes about grub:
  #  * Yes, the grubMenuCfg has to be repeated in all submenus. Otherwise you
  #    will get white-on-black console-like text on sub-menus. *sigh*
  efiDir = pkgs.runCommand "efi-directory"
    {
      nativeBuildInputs = [ pkgs.buildPackages.grub2_efi ];
      strictDeps = true;
    } ''
    mkdir -p $out/EFI/boot/

    touch $out/EFI/efi-marker

    # ALWAYS required modules.
    MODULES="fat iso9660 part_gpt part_msdos \
             normal boot linux configfile loopback chain halt \
             efifwsetup efi_gop \
             ls search search_label search_fs_uuid search_fs_file \
             test all_video loadenv \
             exfat ext2 ntfs btrfs hfsplus udf \
             videoinfo \
             echo serial \
            "

    echo "Building GRUB with modules:"
    for mod in $MODULES; do
      echo " - $mod"
    done

    # Modules that may or may not be available per-platform.
    echo "Adding additional modules:"
    for mod in efi_uga; do
      if [ -f ${grubPkgs.grub2_efi}/lib/grub/${grubPkgs.grub2_efi.grubTarget}/$mod.mod ]; then
        echo " - $mod"
        MODULES+=" $mod"
      fi
    done

    # Make our own efi program, we can't rely on "grub-install" since it seems to
    # probe for devices, even with --skip-fs-probe.
    grub-mkimage --directory=${grubPkgs.grub2_efi}/lib/grub/${grubPkgs.grub2_efi.grubTarget} -o $out/EFI/boot/boot${targetArch}.efi -p /EFI/boot -O ${grubPkgs.grub2_efi.grubTarget} \
      $MODULES
    cp ${grubPkgs.grub2_efi}/share/grub/unicode.pf2 $out/EFI/boot/

    cat <<EOF > $out/EFI/boot/grub.cfg
    serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
    terminal_output console serial
    terminal_input console serial
    set timeout=0

    search --set=root --file /EFI/efi-marker

    # If the parameter iso_path is set, append the findiso parameter to the kernel
    # line. We need this to allow the nixos iso to be booted from grub directly.
    if [ \''${iso_path} ] ; then
      set isoboot="findiso=\''${iso_path}"
    fi

    menuentry 'server' {
      linux /boot/${config.system.boot.loader.kernelFile} \''${isoboot} init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams} 
      initrd /boot/initrd
    }
    EOF
  '';

  efiImg = pkgs.runCommand "efi-image_eltorito"
    {
      nativeBuildInputs = [ pkgs.buildPackages.mtools pkgs.buildPackages.libfaketime pkgs.buildPackages.dosfstools ];
      strictDeps = true;
    }
    # Be careful about determinism: du --apparent-size,
    #   dates (cp -p, touch, mcopy -m, faketime for label), IDs (mkfs.vfat -i)
    ''
      mkdir ./contents && cd ./contents
      mkdir -p ./EFI/boot
      cp -rp "${efiDir}"/EFI/boot/{grub.cfg,*.efi} ./EFI/boot

      # Rewrite dates for everything in the FS
      find . -exec touch --date=2000-01-01 {} +

      # Round up to the nearest multiple of 1MB, for more deterministic du output
      usage_size=$(( $(du -s --block-size=1M --apparent-size . | tr -cd '[:digit:]') * 1024 * 1024 ))
      # Make the image 110% as big as the files need to make up for FAT overhead
      image_size=$(( ($usage_size * 110) / 100 ))
      # Make the image fit blocks of 1M
      block_size=$((1024*1024))
      image_size=$(( ($image_size / $block_size + 1) * $block_size ))
      echo "Usage size: $usage_size"
      echo "Image size: $image_size"
      truncate --size=$image_size "$out"
      mkfs.vfat --invariant -i 12345678 -n EFIBOOT "$out"

      # Force a fixed order in mcopy for better determinism, and avoid file globbing
      for d in $(find EFI -type d | sort); do
        faketime "2000-01-01 00:00:00" mmd -i "$out" "::/$d"
      done

      for f in $(find EFI -type f | sort); do
        mcopy -pvm -i "$out" "$f" "::/$f"
      done

      # Verify the FAT partition.
      fsck.vfat -vn "$out"
    '';
in
{
  config = {
    # Custom grub
    boot.loader.grub.enable = false;

    environment.systemPackages = [ grubPkgs.grub2 grubPkgs.grub2_efi pkgs.syslinux ];

    # In stage 1 of the boot, mount the CD as the root FS by label so
    # that we don't need to know its device.  We pass the label of the
    # root filesystem on the kernel command line, rather than in
    # `fileSystems' below.  This allows CD-to-USB converters such as
    # UNetbootin to rewrite the kernel command line to pass the label or
    # UUID of the USB stick.  It would be nicer to write
    # `root=/dev/disk/by-label/...' here, but UNetbootin doesn't
    # recognise that.
    boot.kernelParams =
      [
        "root=LABEL=${volumeID}"
        "boot.shell_on_fail"
        "console=tty0"
        "console=ttyS0,115200n8"
      ];

    fileSystems = {
      "/" = {
        fsType = "tmpfs";
        options = [ "mode=0755" "size=100m" ];
        neededForBoot = true;
      };
      "/iso" = {
        device = "/dev/root";
        neededForBoot = true;
        noCheck = true;
        options = [ "ro" "norock" "mode=0400" "dmode=0500" ];
      };
      "/nix/store" = {
        fsType = "squashfs";
        device = "/iso/nix-store.squashfs";
        options = [ "loop" ];
        neededForBoot = true;
      };
    };

    boot.initrd.availableKernelModules = [ "squashfs" "iso9660" "uas" "overlay" ];

    boot.initrd.kernelModules = [ "loop" "overlay" ];

    # Create the ISO image.
    system.build.myiso = pkgs.callPackage (nixpkgsPath + /nixos/lib/make-iso9660-image.nix) ({
      isoName = "disk.iso";
      volumeID = volumeID;
      contents = [
        {
          source = config.boot.kernelPackages.kernel + "/" + config.system.boot.loader.kernelFile;
          target = "/boot/" + config.system.boot.loader.kernelFile;
        }
        {
          source = config.system.build.initialRamdisk + "/" + config.system.boot.loader.initrdFile;
          target = "/boot/" + config.system.boot.loader.initrdFile;
        }
        {
          source =
            pkgs.callPackage (nixpkgsPath + /nixos/lib/make-squashfs.nix) {
              storeContents = [ config.system.build.toplevel ];
              comp = "xz -Xdict-size 100% -Xbcj x86";
            };
          target = "/nix-store.squashfs";
        }
        {
          source = pkgs.substituteAll {
            name = "isolinux.cfg";
            # Notes on syslinux configuration and UNetbootin compatibility:
            #   * Do not use '/syslinux/syslinux.cfg' as the path for this
            #     configuration. UNetbootin will not parse the file and use it as-is.
            #     This results in a broken configuration if the partition label does
            #     not match the specified volumeID. For this reason
            #     we're using '/isolinux/isolinux.cfg'.
            #   * Use APPEND instead of adding command-line arguments directly after
            #     the LINUX entries.
            #   * COM32 entries (chainload, reboot, poweroff) are not recognized. They
            #     result in incorrect boot entries.
            src = pkgs.writeText "isolinux.cfg-in" ''
              SERIAL 0 115200
              TIMEOUT 0

              DEFAULT boot

              LABEL boot
              MENU LABEL system
              LINUX /boot/${config.system.boot.loader.kernelFile}
              APPEND init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}
              INITRD /boot/${config.system.boot.loader.initrdFile}
            '';
            bootRoot = "/boot";
          };
          target = "/isolinux/isolinux.cfg";
        }
        {
          source = "${pkgs.syslinux}/share/syslinux";
          target = "/isolinux";
        }
        {
          source = efiImg;
          target = "/boot/efi.img";
        }
        {
          source = "${efiDir}/EFI";
          target = "/EFI";
        }
        {
          source = (pkgs.writeTextDir "grub/loopback.cfg" "source /EFI/boot/grub.cfg") + "/grub";
          target = "/boot/grub";
        }
      ] ++ extraFiles;
      bootable = true;
      bootImage = "/isolinux/isolinux.bin";
      syslinux = pkgs.syslinux;
      usbBootable = true;
      isohybridMbrImage = "${pkgs.syslinux}/share/syslinux/isohdpfx.bin";
      efiBootable = true;
      efiBootImage = "boot/efi.img";
    });
    boot.initrd.supportedFilesystems = [ "vfat" ];
  };
})
