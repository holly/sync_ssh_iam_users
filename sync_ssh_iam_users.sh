#!/usr/bin/env bash

set -o pipefail
set -C

export PROC=10
export UID_MIN=1001
export UID_MAX=1100
export OTHER_GID_MIN=1201

if [[ -f "$HOME/.sync_ssh_iam_users.env" ]]; then
    source "$HOME/.sync_ssh_iam_users.env"
fi

if [[ -z "$SYNC_SSH_IAM_ENVIRONMENT" ]]; then

    if [[ -f "$HOME/.sync_ssh_iam_users.env.${SYNC_SSH_IAM_ENVIRONMENT}" ]]; then
        source "$HOME/.sync_ssh_iam_users.env.${SYNC_SSH_IAM_ENVIRONMENT}"
    fi
fi

if [[ -z "$ADMINISTRATOR_GROUP" ]]; then
    export ADMINISTRATOR_GROUP="aws-administrator-group"
fi
if [[ -z "$NONE_SSH_GROUPS" ]]; then
    export NONE_SSH_GROUPS="app-group,hoge"
fi
if [[ -z "$NONE_SSH_TAG" ]]; then
    export NONE_SSH_TAG="NoneSSH"
fi

__user() {

    local user_name=$1
    if id $user_name >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

__iam_user() {

    local user_name=$1
    if aws iam get-user --user-name $user_name >/dev/null ; then
        return 0
    fi
    return 1
}

__has_none_ssh_tag() {

    local user_name=$1
    local res=$(aws iam get-user --user $user_name | jq -r ".User.Tags[]|select(.Key == \"$NONE_SSH_TAG\").Value")
    if [[ -n "$res" ]]; then
        return 0
    fi
    return 1
}

__mkuser() {

    local user_name=$1
    local uid=$2

    while true; do

        if [[ $uid -eq $UID_MAX ]]; then
            echo "WARN!! uid $UID_MAX can not make user."
            return 1
        fi

        if cat /etc/passwd | cut -d: -f3 | grep -x $uid ; then
            uid=$(($uid+1))
            continue
        fi
        groupadd -g $uid $user_name
        useradd -u $uid -g $uid -s /bin/bash -m -d "/home/$user_name" $user_name
        chmod 700 "/home/$user_name"
        break
    done
}


__add_pubkey() {

    local user_name=$1
    local key="$2"

    local ssh_dir="/home/$user_name/.ssh"
    if [[ ! -d $ssh_dir ]]; then
        install -v -o $user_name -g $user_name -m 0700 -d $ssh_dir
    fi
    if [[ ! -f "$ssh_dir/authorized_keys" ]]; then
        install -v -o $user_name -g $user_name -m 0600 /dev/null "$ssh_dir/authorized_keys"
    fi
    echo "$key" >>"$ssh_dir/authorized_keys"
}

__mkgroup() {

    local group_name=$1
    local gid=$2

    if cat /etc/group | cut -d: -f1 | grep -x $group_name; then
        # already registered group
        return
    fi

    while true; do

        if cat /etc/group | cut -d: -f3 | grep -x $gid; then
            gid=$(($gid+1))
            continue
        fi

        groupadd -g $gid $group_name

        if [[ $group_name == $ADMINISTRATOR_GROUP ]]; then

            cat <<EOL | tee "/etc/sudoers.d/${gid}-${group_name}" >/dev/null
Defaults:%$group_name !requiretty
Defaults env_reset
%$group_name ALL=(ALL:ALL) NOPASSWD:ALL
EOL
            chmod 400 "/etc/sudoers.d/${gid}-${group_name}"
        fi
        break
    done

}

mkuser_from_iam() {

    local user_name=$1

    # check exists user
    if __user $user_name; then
        echo "$user_name is exists. skip."
        return 1
    fi

    # check having $NONE_SSH_TAG
    if  __has_none_ssh_tag $user_name; then
        echo "$user_name has $NONE_SSH_TAG tag. skip."
        return 1
    fi

    # check beloging to non_ssh_group 
    local group_names=$(aws iam list-groups-for-user --user-name $user_name | jq -r ".Groups[].GroupName")
    local none_ssh_groups=(${NONE_SSH_GROUPS//,/ })
    for group_name in ${none_ssh_groups[@]}; do

        if echo $group_names | grep -q $group_name; then
            echo "$user_name begongs to $group_name. skip."
            return 1
        fi
    done

    # check register public key
    local res=$(aws iam list-ssh-public-keys --user-name $user_name | jq -r ".SSHPublicKeys[].SSHPublicKeyId")
    if [[ -z "$res" ]]; then
        echo "$user_name has not SSH Public keys. skip."
        return 1
    fi

    declare -a pubkeys
    for key_id in $res; do

        local pubkey=$(aws iam get-ssh-public-key --encoding SSH --user-name $user_name --ssh-public-key-id $key_id | jq -r '.SSHPublicKey | if .Status == "Active" then .SSHPublicKeyBody else empty end')
        # like array_push
        if [[ -n "$pubkey" ]]; then
            pubkeys=(${pubkeys[@]} "$pubkey")
        fi
    done
    # check array length
    local len=${#pubkeys[@]} 
    if [[ $len -eq 0 ]]; then
        echo "$user_name has not active SSH Public keys. skip."
        return 1
    fi

    # execute add linux user

    # make other groups and registration
    for group_name in $group_names; do
        __mkgroup $group_name $OTHER_GID_MIN
    done
 
    __mkuser $user_name $UID_MIN
    if [[ $? -ne 0 ]]; then
        echo "$user: useradd failed."
        return 1
    fi

    # for ssh setting
    for key in "${pubkeys[@]}"; do
       __add_pubkey $user_name "$key"
    done

    usermod -G $(echo $group_names | perl -nlpe 's/\s+/,/g') $user_name
    echo "$user_name is added."
}

deluser_from_srv() {

    local user_name=$1

    # check exists user
    if ! __user $user_name; then
        echo "$user_name is not exists. skip."
        return 1
    fi

    # exists iam user check
    if  __iam_user $user_name; then
        echo "$user_name is exists on aws iam. skip."
        return 1
    fi

    userdel -r $user_name
    echo "$user_name is deleted."
}

aws_iam_users() {

    aws iam list-users | jq -r ".Users[].UserName"
}

srv_users() {

    for user_name in $(cat /etc/passwd | cut -d: -f1); do

        local uid=$(id -u $user_name)
        if [[ $uid -ge $UID_MIN ]] && [[ $uid -le $UID_MAX ]]; then
            echo $user_name
        fi
    done

}

export -f __user
export -f __iam_user
export -f __has_none_ssh_tag
export -f __mkuser
export -f __add_pubkey
export -f __mkgroup
export -f mkuser_from_iam
export -f deluser_from_srv
export -f aws_iam_users
export -f srv_users

for cmd in $(echo "aws jq") ; do
    if ! which $cmd >/dev/null; then
        echo "ERROR: $cmd is not installed."
        exit 1
    fi
done

echo "> start mkuser"
aws_iam_users | xargs -I% -t -P$PROC  bash -c "mkuser_from_iam %"
echo ""
echo "> start deluser"
srv_users | xargs -I% -t -P$PROC  bash -c "deluser_from_srv %"

echo ""
echo ">> done."
