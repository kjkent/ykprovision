#!/usr/bin/env bash

### Heavily based on the following fantastic resources:
# - https://github.com/drduh/YubiKey-Guide/blob/master/README.md
# - https://musigma.blog/2021/05/09/gpg-ssh-ed25519.html

wipe_tmpfiles() {
	rm -rf "${TMPDIR:-/tmp}/ykprovision"*
}
wipe_tmpfiles

mktempdir() {
	while true; do
		local new_dir="$(mktemp --tmpdir --directory ykprovision.XXXXXXXXXXXXXXXXXXXX)"

		[ -d "$new_dir" ] || (echo "Error in creating $new_dir"; exit 1)
		if [ "$new_dir" != "$GNUPGHOME" ]; then break; fi
	done
	echo "$new_dir"
}

# set params
script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
identity="$@"
key_type='ed25519'
key_type_enc='cv25519'
key_exp='2y'
yk_pin_retries=3

# # Install necessary software
if [ -x /usr/bin/apt ]; then
	sudo apt update &&
	sudo apt -y upgrade && 
	sudo apt -y install \
		wget \
		gnupg2 \
		gnupg-agent \
		dirmngr \
		cryptsetup \
		scdaemon \
		pcscd \
		yubikey-personalization \
		yubikey-manager
fi

# Download hardened config if not already present on disk & copy to dir
if [ ! -f "$script_dir/gpg.conf" ]; then
	curl https://raw.githubusercontent.com/drduh/config/master/gpg.conf \
		-o "$script_dir"/gpg.conf
	cat "$script_dir/gpg.conf"

	read -rp "Are you happy with the downloaded gpg.conf? [yn] " -N 1 resp
	if [[ ! "$resp" =~ ^[Yy]$ ]]; then exit 1; fi
fi

cert_pass="$(LC_ALL=C \
	tr -dc '[:graph:]' </dev/urandom | \
	tr -d 'LlIi5S0Oo' | \
	head -c 64 \
)"

give_cert_pass() {
	echo "COPY DOWN YOUR CERTIFICATION KEY PASSWORD!!!"
	echo ""
	echo "------------vvvvvvv---------------"
	echo ""
	echo "$1"
	echo ""
	echo "------------^^^^^^^---------------"
	echo ""
	echo "COPY DOWN YOUR CERTIFICATION KEY PASSWORD!!!"
}

make_key() {
	local gnupghome="${1:-$GNUPGHOME}"

	cp "$script_dir"/gpg.conf "$gnupghome"/

	GNUPGHOME="$gnupghome" gpg \
		--quiet \
		--batch \
		--passphrase "$cert_pass" \
		--quick-generate-key "$identity" \
		"$key_type" \
		cert \
		never
}

while true; do
	# Generate certification key with no expiration (stored on YK permanently)
	export GNUPGHOME="$(mktempdir)"
	make_key
	
	# Export key ids for later user
	export key_id=$(gpg -k --with-colons "$identity" | awk -F: '/^pub:/ { print $5; exit }')
	export key_fp=$(gpg -k --with-colons "$identity" | awk -F: '/^fpr:/ { print $10; exit }')

	printf "\nKey ID: %40s\nKey FP: %40s\n\n" "$key_id" "$key_fp"

	read -rp 'Are you happy with these keys?  ' -N 1 yn
	case "$yn" in
		[Yy]) break 2;;
	esac
done

# Generate and attach subkeys
for subkey in sign encrypt auth; do
	subkey_type=''
	if [ "$subkey" = 'encrypt' ]; then 
		subkey_type="$key_type_enc"
	else
		subkey_type="$key_type"
	fi

	gpg --batch \
	    --quiet \
	    --pinentry-mode=loopback \
	    --passphrase "$cert_pass" \
	    --quick-add-key "$key_fp" \
	    "$subkey_type" \
	    "$subkey" \
	    "$key_exp"
done

# Export backup of all keys
export privkey_cert="$GNUPGHOME/$key_id-cert.key"
export privkey_subs="$GNUPGHOME/$key_id-subs.key"
export pubkey="$GNUPGHOME/$key_id-$(date +%F).asc"

gpg --output "$privkey_cert" \
    --batch --pinentry-mode=loopback --passphrase "$cert_pass" \
    --armor --export-secret-keys "$key_id"

gpg --output "$privkey_subs" \
    --batch --pinentry-mode=loopback --passphrase "$cert_pass" \
    --armor --export-secret-subkeys "$key_id"

gpg --output "$pubkey" \
    --armor --export "$key_id"

# encrypt privkeys and place keys in script dir
for privkey in "$privkey_cert" "$privkey_subs"; do
	gpg --output "$privkey.gpg" \
	    --pinentry-mode=loopback \
	    -r "$identity" \
	    --encrypt "$privkey"
	
	rm -f "$privkey"
	mv "$privkey.gpg" "$script_dir/"
done
mv "$pubkey" "$script_dir/"

echo -n 'Enter new User PIN for YubiKey (ASCII only, 6-127 chars): '; read -r yk_user_pin
echo
echo -n "Enter new Admin PIN for YubiKey (ASCII only, 6-127 chars): "; read -r yk_admin_pin
echo

gpg_reload () {
	gpgconf -R
	gpg-connect-agent killagent /bye
	gpg-connect-agent /bye
}
# Reload GPG-Agent when switching between ykman and gnupg 
# as they tend to conflict
gpg_reload

# It's Yubin' time (delete existing PGP data on ykey)
ykman openpgp reset --force
# Set PIN retry attempts
ykman openpgp access set-retries \
	"$yk_pin_retries" "$yk_pin_retries" "$yk_pin_retries" \
	-f -a 12345678

gpg_reload

# Enable KDF (prevents plaintext PIN transfers)
gpg --command-fd=0 --pinentry-mode=loopback --card-edit <<EOF
admin
kdf-setup
12345678
EOF

# Set PINs
gpg --command-fd=0 --pinentry-mode=loopback --change-pin <<EOF
3
12345678
$yk_admin_pin
$yk_admin_pin
q
EOF

gpg --command-fd=0 --pinentry-mode=loopback --change-pin <<EOF
1
123456
$yk_user_pin
$yk_user_pin
q
EOF

# Set smart card attributes
gpg --command-fd=0 --pinentry-mode=loopback --edit-card <<EOF
admin
login
$identity
$yk_admin_pin
quit
EOF

read -rp 'How many YubiKeys are you adding these keys to? ([0-9]*) ' num_keys
echo

for (( i = 0; i < "$num_keys"; i++ )); do
	tmp_gnupghome="$(mktempdir)"

	cp -rf "$GNUPGHOME"/* "tmp_gnupghome"/

	GNUPGHOME="$tmp_gnupghome" gpg \
		--command-fd=0 \
		--pinentry-mode=loopback \
		--edit-key "$key_id" <<-EOF
		key 1
		keytocard
		1
		$cert_pass
		$yk_admin_pin
		key 1
		key 2
		keytocard
		2
		$cert_pass
		$yk_admin_pin
		key 2
		key 3
		keytocard
		3
		$cert_pass
		$yk_admin_pin
		key 3
		save
		EOF

		if (( "$i" < "$num_keys" - 1 )); then
			echo "Added to YubiKey $(( i + 1 )) of $num_keys."
			read -rp 'Ready to continue? [YyNn]  ' -N 1 yn; echo
			case "$yn" in
				[Yy]) break;;
				[Nn])
					read -rp 'Exit? [YyNn]  ' yn2
					case "$yn2" in
						[Yy]) exit 0;;
						[Nn]) break;;
					esac
					;;
			esac
		fi
done

give_cert_pass "$cert_pass"

echo "Backups saved to $script_dir, save them somewhere!"
echo "BYE"
