#!/usr/bin/env bash

set -x
set -u
set -o pipefail
set -C

REPOSITORY_URL=https://github.com/holly/sync_ssh_iam_users.git
DEPENDENCY_COMMANDS=(aws jq)
INSTALL_DIR="/root/sync_ssh_iam_users"

is_root() {

    if [[ $(id -u) -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

error() {
    echo -ne "\e[31;1m"
    echo "[ERROR] $@"
    echo -ne "\e[m"
    exit 1
}


echo ">> Start installation...."
echo ""

if ! is_root; then
    error "You are not root. change root user and revenge exec install.sh"
fi

for c in ${DEPENDENCY_COMMANDS[@]}; do

    which $c >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "$c is installed."
    else
        error "$c is not installed."
    fi
done

if [[ -d $INSTALL_DIR ]]; then
    error "repository is already installed."
fi

git clone $REPOSITORY_URL $INSTALL_DIR
cd $INSTALL_DIR

find systemd -type f | xargs -I% cp -v % /etc/%
systemctl daemon-reload
for unit in $(echo service timer); do
    systemctl enable "sync_ssh_iam_users.$unit"
    systemctl start "sync_ssh_iam_users.$unit"
    systemctl enable "sync_ssh_iam_users_update.$unit"
    systemctl start "sync_ssh_iam_users_update.$unit"
done

echo ""
echo ">> done."
