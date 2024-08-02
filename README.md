# ykprovision

Quickly generate secure GPG keys, and optionally transfer them to one or more Yubikeys.

Keys are generated with the following schema:

- **Main (Certify) key (no expiry)**: ed25519
    - **Subkeys (3y expiry)**:
        - Sign: ed25519
        - Authenticate: ed25519
        - Encrypt: cv25519

> [!WARNING]
> This script will erase existing OpenPGP applet data on YubiKeys **without
> prompting**. Do NOT run when YubiKeys are inserted which contain OpenPGP data
> you wish to preserve.
> 
> **Disclaimer: This is an in-development script. I am not responsible for lost
> data, or any other consequences stemming from your use of it. If this script 
> nukes your pc into orbit, you're on your own (but please file an issue once
> your computer de-orbits). Perform due diligence and review the source before
> execution.**

## Usage

```Shell

ykprovision.sh <identity>

```

`<identity>` must be in the format `'Full Name (optional_comment) <email@address.tld>'`

The comment is sometimes used to reflect an email address, such as:

```Shell

ykprovision.sh 'Kristopher James Kent (kjkent) <kris@kjkent.dev>'

```

The script will prompt for further input.

## Acknowledgements

**Heavily based on the following fantastic resources:**

- https://github.com/drduh/YubiKey-Guide/blob/master/README.md
- https://musigma.blog/2021/05/09/gpg-ssh-ed25519.html


