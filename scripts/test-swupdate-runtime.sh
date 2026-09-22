#!/bin/sh
# Real upstream SWUpdate test, but ONLY with synthetic files in a private /tmp dir.
# No kernel, boot menu, bootloader, block device or service is changed.
set -eu
bin=${1:-swupdate}
for tool in "$bin" openssl cpio tar sha256sum cmp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing tool: $tool" >&2; exit 1; }
done
umask 077
root=$(mktemp -d /tmp/arm-packer-swu-test.XXXXXX)
trap 'echo "SWUpdate test logs: $root"' EXIT
mkdir -p "$root/input" "$root/target" "$root/payload" "$root/tmp" "$root/run"
export TMPDIR="$root/tmp" RUNTIME_DIRECTORY="$root/run"
printf 'globals = { bootloader = "none"; };\n' > "$root/swupdate.cfg"
printf 'known-good\n' > "$root/target/old-kernel"
cp "$root/target/old-kernel" "$root/sentinel"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$root/key.pem" 2>/dev/null
openssl pkey -in "$root/key.pem" -pubout -out "$root/public.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$root/wrong.pem" 2>/dev/null
openssl pkey -in "$root/wrong.pem" -pubout -out "$root/wrong-public.pem"
printf 'synthetic candidate, NOT a bootable kernel\n' > "$root/payload/Image"
tar -C "$root/payload" -cf "$root/input/kernel.tar" Image
cat > "$root/input/install.sh" <<EOF
#!/bin/sh
set -eu
case "\$1" in
  preinst)
    test ! -f '$root/reject-install'
    test -f '$root/target/old-kernel'
    printf 'preinst\n' >> '$root/hooks'
    ;;
  postinst)
    test -f '$root/target/new/Image'
    printf 'postinst\n' >> '$root/hooks'
    ;;
esac
EOF
chmod 755 "$root/input/install.sh"
payload_hash=$(sha256sum "$root/input/kernel.tar" | cut -d ' ' -f 1)
script_hash=$(sha256sum "$root/input/install.sh" | cut -d ' ' -f 1)
cat > "$root/input/sw-description" <<EOF
software = {
  version = "1.0.0";
  hardware-compatibility = [ "rock5c-alpine-v1" ];
  images: ({ filename = "kernel.tar"; type = "archive";
    path = "$root/target/new";
    properties = { create-destination = "true"; };
    sha256 = "$payload_hash"; });
  scripts: ({ filename = "install.sh"; type = "shellscript";
    sha256 = "$script_hash"; });
};
EOF
openssl dgst -sha256 -sign "$root/key.pem" -sigopt rsa_padding_mode:pss \
    -sigopt rsa_pss_saltlen:-2 -out "$root/input/sw-description.sig" "$root/input/sw-description"
pack() {
    (cd "$root/input"; printf '%s\n' sw-description sw-description.sig install.sh kernel.tar |
        cpio -o -H crc 2>/dev/null) > "$1"
}
invoke() {
    "$bin" -f "$root/swupdate.cfg" -k "$root/public.pem" \
        -H rock5c:rock5c-alpine-v1 -i "$root/valid.swu" "$@"
}
unchanged() {
    cmp "$root/sentinel" "$root/target/old-kernel"
    test ! -e "$root/target/new/Image"
    test ! -e "$root/hooks"
}
reject() {
    name=$1; shift
    if invoke "$@" > "$root/$name.log" 2>&1; then
        echo "FAIL: accepted $name" >&2; exit 1
    fi
    unchanged
    echo "PASS rejected $name without touching target"
}
pack "$root/valid.swu"
invoke -c > "$root/check.log" 2>&1
unchanged
echo 'PASS signed bundle verification is read-only'
reject wrong-key -k "$root/wrong-public.pem"
reject wrong-hardware -H rock5c:wrong-revision
cp "$root/input/kernel.tar" "$root/pristine.tar"
printf 'corruption\n' >> "$root/input/kernel.tar"
pack "$root/tampered.swu"
cp "$root/pristine.tar" "$root/input/kernel.tar"
reject tampered-payload -i "$root/tampered.swu"
(cd "$root/input"; printf '%s\n' sw-description install.sh kernel.tar |
    cpio -o -H crc 2>/dev/null) > "$root/unsigned.swu"
reject unsigned -i "$root/unsigned.swu"
touch "$root/reject-install"
reject preinstall-failure
rm "$root/reject-install"
invoke > "$root/install.log" 2>&1
cmp "$root/payload/Image" "$root/target/new/Image"
cmp "$root/sentinel" "$root/target/old-kernel"
printf 'preinst\npostinst\n' > "$root/expected-hooks"
cmp "$root/expected-hooks" "$root/hooks"
echo 'PASS upstream archive installation and pre/post hooks; old files retained'
echo 'PASS real SWUpdate tests (synthetic payload, NOT a hardware/kernel test)'
