import subprocess
import json
import sys
import os.path
import typing
import shutil
import argparse

ap = argparse.ArgumentParser()
ap.add_argument("mountpoint")
ap.add_argument("ensure_subdirs", action="append")
ap.add_argument("--encrypted")
args = ap.parse_args()

uuid = "f457cacd-85a9-4449-bb30-2e5b09fa0bc8"

mapper_name = "persistent"
mapper_dev = "/dev/mapper/{}".format(mapper_name)


def mount_luks(phys_dev: str) -> str:
    subprocess.run(
        ["cryptsetup", "open", "--key-file=-", phys_dev, mapper_name],
        check=True,
        input=args.encrypted.encode("utf-8"),
    )
    return mapper_dev


def ensure_fs() -> str:
    lsblk_raw = subprocess.run(
        ["lsblk", "-O", "--json"], check=True, stdout=subprocess.PIPE
    ).stdout.decode("utf-8")
    lsblk = json.loads(lsblk_raw)

    # Find existing device
    def find_existing() -> typing.Optional[dict]:
        for cand in lsblk["blockdevices"]:
            name = cand["name"]
            cand_uuid = cand.get("uuid") or ""
            if cand_uuid == uuid:
                print("Found existing dev with uuid {}, opening".format(uuid))
                return cand
        return None

    blk = find_existing()

    if blk is not None:
        mountpoint = blk.get("mountpoint")
        if mountpoint:
            print("Already mounted, doing nothing")
            sys.exit()

        phys_dev = "/dev/{}".format(name)
        if args.encrypted is not None:
            return mount_luks(phys_dev)
        else:
            return phys_dev

    # Otherwise, find a new disk to setup and mount.
    def in_use(cand: dict) -> bool:
        # Check if in use directly
        cand_mountpoints = [p for p in (cand.get("mountpoints") or []) if p is not None]
        if len(cand_mountpoints) > 0:
            print(
                "Reject candice [{}]: already mounted at {}".format(
                    name, cand_mountpoints
                )
            )
            return True

        # If there are children, check if any children are in use
        cand_children = cand.get("children") or []
        if len(cand_children) > 0:
            for child in cand_children:
                res = in_use(child)
                if res is not None:
                    print("Reject device [{}], has in use child: {}".format(name, res))
                    return True

        return False

    for cand in lsblk["blockdevices"]:
        # Evaluate
        name = cand["name"]
        cand_type = cand.get("type") or ""
        want_type = "disk"
        if cand_type != want_type:
            print(
                "Reject device [{}]: type is [{}] not [{}]".format(
                    name, cand_type, want_type
                )
            )
            continue

        if in_use(cand):
            continue

        # Format
        phys_dev = "/dev/{}".format(name)
        print("Select device [{}]; formatting".format(name))
        if args.encrypted:
            subprocess.run(
                ["cryptsetup", "luksFormat", "--type=luks2", "--key-file=-", phys_dev],
                check=True,
                input=args.encrypted.encode("utf-8"),
            )
            subprocess.run(
                ["cryptsetup", "luksUUID", "--uuid", uuid, phys_dev], check=True
            )
            return mount_luks(phys_dev)
        else:
            subprocess.run(["mkfs.ext4", "-U", uuid, phys_dev], check=True)
            return phys_dev

    # Doesn't exist, candidate not found
    raise RuntimeError("No disk found")


fs_path = ensure_fs()

# Mount fs
e2fsck_res = subprocess.run(["e2fsck", "-f", "-y", fs_path]).returncode
if e2fsck_res >= 4:
    raise RuntimeError("e2fsck exited with failure exit code {}", e2fsck_res)
print("Mounting device [{}] at [{}]".format(fs_path, args.mountpoint))
subprocess.run(["mount", "--mkdir", fs_path, args.mountpoint], check=True)

# Ensure subdirs
for parts in map(lambda x: x.split(":"), args.mkdirs):
    parts.reverse()
    d = parts.pop()
    user = parts.pop()
    group = parts.pop() or user
    print("Ensuring persistent dir [{}]".format(d))
    os.makedirs(d, exist_ok=True)
    if user:
        shutil.chown(d, user=user, group=group)
