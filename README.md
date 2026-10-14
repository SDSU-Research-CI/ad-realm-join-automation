# AD Realm Join Automation

Automates joining Ubuntu 22.04+ machines (including Kubuntu) to an Active Directory domain (`realmd`/`sssd`), based on an internal "Realm Join Instructions" runbook.

> **Heads up:** this repo is public and references internal domain/OU naming conventions (e.g. `ID.SDSU.EDU`, delegated OU paths, sudo group naming). Nothing here is a credential or secret, but review the script before publishing if you'd rather keep that structure private.

## What it does

`join-ad.sh` runs the whole process in a **single pass**. No reboot is needed partway through, so run it once.

1. Time sync and hostname: configures NTP if it is not already set, and updates the hostname and `/etc/hosts` (including on cloud-init images where the hostname is mapped via a `127.0.0.1` line instead of `127.0.1.1`).
2. Package install and domain join: installs the required packages, discovers the domain, prompts for the admin account (just the short name, the domain is appended automatically) and the computer OU (with presets as a starting point), and joins the domain.
3. Post-join configuration: applies recommended `sssd.conf` settings, enables home directory creation on login, applies UMASK 007 hardening, and optionally sets a default primary group (`override_gid`).
4. Access and sudo: optionally permits an AD group (and/or individual users) to log in, and grants sudo to an AD group or to individual users. Names are auto-lowercased.
5. Ends with a prompt to reboot so you can log back in and verify everything.

Every config file it touches is backed up once as `<file>.bak-preadjoin` before editing.

## Requirements

- Ubuntu 22.04 or newer (including Kubuntu)
- Run as root (`sudo`)
- Network access to the target domain controller (on campus or VPN)
- An AD account with permission to join computers to the target OU
- If you plan to use AD groups for login or sudo, create them in AD **before** running the script

## Install and run

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/SDSU-Research-CI/ad-realm-join-automation.git
cd ad-realm-join-automation
chmod +x join-ad.sh
sudo ./join-ad.sh
```

To get later updates, run `git pull` inside the folder.

## Answering the prompts

| Prompt | What to enter |
| --- | --- |
| New hostname | Press **Enter** to keep the current name, or type a new one (1 to 15 letters, digits or hyphens). Do not type `y` or `n`; the script rejects them. |
| AD domain for `/etc/hosts` | Press **Enter** for `id.sdsu.edu`. |
| Use default domain? | `y` for `ID.SDSU.EDU`. |
| Department | `1` Business, `2` Sciences, or `3` custom. |
| Admin account | Your AD admin account without `@ID.SDSU.EDU`, exactly as it works at login. |
| Computer OU | Press **Enter** to accept the default. Anything else must be a full DN (`OU=...,DC=...`); a stray `y` is rejected. |
| Proceed? | `y` to run `realm join`, then enter the admin password. |
| `override_gid`, login group, sudo group | Leave blank to skip. |
| Permit an individual user or group for login now? | `y` to add someone, `n` to skip. Then type the word `user` or `group`, and the exact AD name. The script checks that the name exists in AD and warns if it does not, and offers to grant sudo. It then asks "Permit another user or group?" until you answer `n`. Any answer other than y or n is asked again. |

## Allowing individual users (no AD group)

At the "Permit an individual user or group for login now?" prompt, add each person as a `user` and answer `y` to "Also grant sudo". The script writes the sudoers entry to `/etc/sudoers.d/domain` after validating it with `visudo`.

You can also do it by hand later:

```bash
sudo realm permit user1 user2
sudo visudo -f /etc/sudoers.d/domain
#   user1 ALL=(ALL:ALL) ALL
#   user2 ALL=(ALL:ALL) ALL
sudo chmod 0440 /etc/sudoers.d/domain
sudo realm permit --withdraw wronguser    # remove a mistaken entry
sudo realm permit --all                   # reset to allow all AD users
```

## What it does NOT automate

- Creating the AD security group itself. That happens in Active Directory, not on the Linux box. Create it *before* running the script.
- SSH access restriction (`sshusers` group + `sshd_config` changes), only needed on some machines.
- `chmod g+s` on shared directories. This is folder-specific, so run it manually as needed.

## Notes on department OU presets

The Business/Sciences `--computer-ou` presets are provided as a convenience starting point pulled from an internal runbook. **Verify the exact OU string for your environment before joining a production machine.** An incorrect OU can place the computer object in the wrong location in AD.

## Re-joining a machine already on the domain

If the machine is already joined to the target domain, the script runs `realm leave` first, then rejoins.

## Verifying a successful join

After the reboot, from a local admin account:

```bash
realm list                              # configured: kerberos-member, check permitted-logins
id <domainuser>
sudo klist -k                           # computer account keytab entries
sudo sssctl domain-status ID.SDSU.EDU   # should be Online
sudo -l -U <domainuser>                 # confirms sudo rules
touch testfile && ls -l testfile        # check group ownership if override_gid was set
```

Then test a real AD login (SSH or the login screen) and confirm the home directory is created. Keep a local admin session open until you have done this.

## Troubleshooting

- **`Preauthentication failed`**: wrong password, wrong admin account name, or a locked account. Test with `kinit <admin>@ID.SDSU.EDU` (install `krb5-user`) and avoid repeated attempts, which can lock the account.
- **Typed the wrong hostname or OU**: set the hostname back with `sudo hostnamectl set-hostname NAME`, check `/etc/hosts` (the original is saved as `/etc/hosts.bak-preadjoin`), and run the script again.
- **Only one user can log in, or nobody can**: check `realm list` for `login-policy` and `permitted-logins`. Fix with `sudo realm permit <user>`, or reset with `sudo realm permit --all`.
- **Clock skew errors**: check `timedatectl status` and the NTP servers in `/etc/systemd/timesyncd.conf`.

