#!/bin/bash
# Turn on two-factor sign-in: generates a secret for an authenticator app
# (Google Authenticator, Aegis, 1Password, ...).
#
#   ./totp-setup.sh                   print a new secret and how to use it
#   ./totp-setup.sh terminale.conf    also write it into that config file
set -e
CONF="${1:-}"
SECRET="$(head -c 20 /dev/urandom | base32 | tr -d '=\n')"
[ ${#SECRET} -ge 32 ] || { echo "totp-setup.sh: could not generate a secret (need 'base32' from coreutils)" >&2; exit 1; }
LABEL="Terminale:$(id -un)@$(hostname)"
URL="otpauth://totp/$(printf '%s' "$LABEL" | sed 's/ /%20/g; s/@/%40/g')?secret=$SECRET&issuer=Terminale&algorithm=SHA1&digits=6&period=30"
echo "Secret:  $SECRET"
echo "URL:     $URL"
echo
if command -v qrencode >/dev/null; then
    qrencode -t ANSIUTF8 "$URL"
else
    echo "(install 'qrencode' to get a QR code here; otherwise type the secret into your app,"
    echo " choosing time-based, SHA-1, 6 digits, 30 seconds)"
fi
echo
if [ -n "$CONF" ]; then
    touch "$CONF"; chmod 600 "$CONF"
    if grep -qE '^[[:space:]]*totp_secret[[:space:]]*=' "$CONF"; then
        sed -i -E "s|^[[:space:]]*totp_secret[[:space:]]*=.*|totp_secret = $SECRET|" "$CONF"
    else
        printf '\n# Two-factor sign-in (authenticator app)\ntotp_secret = %s\n' "$SECRET" >> "$CONF"
    fi
    echo "Written to $CONF. Restart Terminale; sign-in will then ask for the 6-digit code."
else
    echo "Add this to your Terminale config file, then restart:"
    echo "    totp_secret = $SECRET"
    echo "(or start with TERMINALE_TOTP_SECRET=$SECRET in the environment)"
fi
echo "Keep the secret private: with your password it is all that is needed to sign in."
