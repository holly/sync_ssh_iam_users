#!/usr/bin/env bash

set -o pipefail
set -C

export PROC=1
export UID_MIN=1101
export UID_MAX=1200
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
    export NONE_SSH_GROUPS=( "app-group" )
fi
if [[ -z "$NONE_SSH_TAG" ]]; then
    export NONE_SSH_TAG="NoneSSH"
fi

REQUIRE_COMMANDS=("jq" "aws")

__exists_user() {

    local user_name=$1
    if id $user_name >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

__exists_iam_user() {

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

__make_user() {

    local user_name=$1
    local uid=$2

    while true; do

        if [[ $uid -eq $UID_MAX ]]; then
            echo "ERROR!! uid $UID_MAX can not make user."
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

    # set passwd
    local pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16)
    echo "${user_name}:${pass}" | chpasswd
}

__add_pubkey() {

    local user_name=$1
    local key="$2"

    if ! __exists_user $user_name; then
        echo "$user_name is not exists. skip."
        return 1
    fi

    local ssh_dir="/home/$user_name/.ssh"
    if [[ ! -d $ssh_dir ]]; then
        install -v -o $user_name -g $user_name -m 0700 -d $ssh_dir
    fi
    if [[ ! -f "$ssh_dir/authorized_keys" ]]; then
        install -v -o $user_name -g $user_name -m 0600 /dev/null "$ssh_dir/authorized_keys"
    fi
    echo "$key" >>"$ssh_dir/authorized_keys"
}

__del_pubkey() {

    local user_name=$1

    if ! __exists_user $user_name; then
        echo "$user_name is not exists. skip."
        return 1
    fi

    local ssh_dir="/home/$user_name/.ssh"
    if [[ ! -d $ssh_dir ]]; then
        echo "$ssh_dir is not exists. skip."
        return 1
    fi
    rm -v "$key" >>"$ssh_dir/authorized_keys"
}


__activate_user() {

    local user_name=$1

    if ! __exists_user $user_name; then
        echo "$user_name is not exists. skip."
        return 1
    fi

    local home_dir="/home/$user_name"
    usermod -U $user_name
    chmod 700 $home_dir
}

__deactivate_user() {

    local user_name=$1

    if ! __exists_user $user_name; then
        echo "$user_name is not exists. skip."
        return 1
    fi

    local home_dir="/home/$user_name"
    pkill -U $(id -u $user_name)
    usermod -L $user_name
    chmod 0 $home_dir
}


__make_group() {

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

moduser_from_iam() {

    local user_name=$1
    local deactivate=0

    # check exists user
    if ! __exists_user $user_name; then
        echo "$user_name is not exists. skip."
        return 1
    fi

    # exists iam user check
    if !  __exists_iam_user $user_name; then
        echo "$user_name is not exists on aws iam. skip."
        return 1
    fi

    # check having $NONE_SSH_TAG
    if  __has_none_ssh_tag $user_name; then
        echo "$user_name has $NONE_SSH_TAG tag."
        deactivate=1
    fi

    # check beloging to non_ssh_group 
    local group_names=$(aws iam list-groups-for-user --user-name $user_name | jq -r ".Groups[].GroupName")
    for group_name in ${NONE_SSH_GROUPS[@]}; do

        if echo $group_names | grep -q $group_name; then
            echo "$user_name belongs to $group_name."
            deactivate=1
        fi
    done

    if [[ $deactivate -eq 1 ]]; then
        __deactivate_user $user_name
        echo "$user_name is deactived."
        return 0
    fi

    __activate_user

    # make other groups and registration
    for group_name in $group_names; do
        __make_group $group_name $OTHER_GID_MIN
    done

    usermod -G $(echo $group_names | perl -nlpe 's/\s+/,/g') $user_name
    echo "$user_name is modified."
}


adduser_from_iam() {

    local user_name=$1

    # check exists user
    if __exists_user $user_name; then
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
    for group_name in ${NONE_SSH_GROUPS[@]}; do

        if echo $group_names | grep -q $group_name; then
            echo "$user_name belongs to $group_name. skip."
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

    # make other groups and registration
    for group_name in $group_names; do
        __make_group $group_name $OTHER_GID_MIN
    done
 
    __make_user $user_name $UID_MIN
    if [[ $? -ne 0 ]]; then
        echo "$user_name: useradd failed."
        return 1
    fi

    # for ssh setting
    for key in "${pubkeys[@]}"; do
       __add_pubkey $user_name "$key"
    done

    usermod -G $(echo $group_names | perl -nlpe 's/\s+/,/g') $user_name
    echo "$user_name is added."
}

deluser_from_local() {

    local user_name=$1

    # check exists user
    if ! __exists_user $user_name; then
        echo "$user_name is not exists. skip."
        return 1
    fi

    # exists iam user check
    if  __exists_iam_user $user_name; then
        echo "$user_name is exists on aws iam. skip."
        return 1
    fi

    userdel -r $user_name
    echo "$user_name ($(id -u $user_name)) is deleted."
}

aws_iam_users() {

    aws iam list-users | jq -r ".Users[].UserName"
}

users() {

    for user_name in $(cat /etc/passwd | cut -d: -f1); do

        local uid=$(id -u $user_name)
        if [[ $uid -ge $UID_MIN ]] && [[ $uid -le $UID_MAX ]]; then
            echo $user_name
        fi
    done
}

export -f __exists_user
export -f __exists_iam_user
export -f __has_none_ssh_tag
export -f __make_user
export -f __add_pubkey
export -f __make_group
export -f __del_pubkey
export -f __activate_user
export -f __deactivate_user
export -f adduser_from_iam
export -f moduser_from_iam
export -f deluser_from_local

# check require commands
for cmd in "${REQUIRE_COMMANDS[@]}" ; do
    if ! which $cmd >/dev/null; then
        echo "ERROR: $cmd is not installed."
        exit 1
    fi
done

echo "> start add users"
iam_users=$(aws_iam_users)
echo $iam_users | xargs -I% -t -P$PROC  bash -c "adduser_from_iam %"
echo ""
echo "> start delete users"
users | xargs -I% -t -P$PROC  bash -c "deluser_from_local %"

echo ""
echo ">> done."
