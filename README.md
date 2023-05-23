# sync_ssh_iam_users
easy iam-user and ec2 linux user sync script. inspire https://github.com/widdix/aws-ec2-ssh

# Install

## Install oneline

```
curl -sfSL https://raw.githubusercontent.com/holly/sync_ssh_iam_users/main/install.sh | bash - 
```

## Install from git

```
git clone https://github.com/holly/sync_ssh_iam_users.git
cd sync_ssh_iam_users
./install.sh
```

# Installer Actions

[install.sh](https://raw.githubusercontent.com/holly/sync_ssh_iam_users/main/install.sh) runs the following.

* Create systemd sync_ssh_iam_users.service and sync_ssh_iam_users.timer(hourly)
* Create systemd sync_ssh_iam_users_update.service and sync_ssh_iam_users_update.timer(daily)


Instalation can execute only root user.

# Requirements

## Require commands

* [aws cli](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* [jq](https://stedolan.github.io/jq/)


## Policy attached ec iam role 

You must set up a role in ec2 where you want to install sync_ssh_iam_users that contains the following policy .

see https://github.com/holly/sync_ssh_iam_users/blob/main/example/policy.json .


## Setup iam user and group

* Make user-group
* Make iam user and attached user-group
* Associate ssh public key with user (AWS Console > IAM > User > Security Authentication > AWS CodeCommit SSH Key > Upload SSH Public key)


# Tips

# sudoers group

If iam-user belong to `aws-administrator-group`, sudo will be enabled.

The name of the sudo-enabled group can be changed by changing the value of the `ADMINISTRATOR_GROUP` variable.

Create /root/.sync_ssh_iam_users.env and write the following

```
export ADMINISTRATOR_GROUP="your-administrator-group-name"
```

# none-sync group

If iam-user belong to `app-group`, no local user is created. If already created, it will be disabled.

If you want to change the name, set `NONE_SSH_GROUPS` to an array of group names.

Create /root/.sync_ssh_iam_users.env and write the following

```
export NONE_SSH_GROUPS=("non-ssh-group" "designer-group")
```

# none-sync user

If the `NoneSSH` tag is assigned to the iam user, no local user is created. If already created, it will be disabled.


# License

License is MIT.
