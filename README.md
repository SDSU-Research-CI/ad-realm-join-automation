# AD Realm Join Automation

Automates joining Ubuntu 22.04+ machines to an Active Directory domain (`realmd`/`sssd`), based on an internal "Realm Join Instructions" runbook.

> **Heads up:** this repo is public and references internal domain/OU naming conventions (e.g. `ID.SDSU.EDU`, delegated OU paths, sudo group naming). Nothing here is a credential or secret, but review the script before publishing if you'd rather keep that structure private.

## What it does

`join-ad.sh` walks through the full join process in two stages (a reboot is required in between):

- **Stage 1:** auto-detects and configures NTP if not already set, hostname/hosts update (including on cloud-init images where the hostname is mapped via a `127.0.0.1` line instead of `127.0.1.1`).
- **Stage 2** (run the script again): installs required packages, discovers the domain, prompts for the admin account (just the short name — the domain is appended automatically) and computer OU (with presets as a starting point), joins the domain, applies recommended `sssd.conf` settings, enables home directory creation on login, applies UMASK 007 hardening, optionally sets a default primary group (`override_gid`), optionally grants an AD group login access and/or sudo access (group names are auto-lowercased), and ends with a reboot so you can log back in and verify everything.

It tracks progress via a marker file (`/var/tmp/ad-join-stage1-done`) so re-running the script resumes automatically at Stage 2. Every config file it touches is backed up once as `<file>.bak-preadjoin` before editing.

## Requirements

- Ubuntu 22.04 or newer
- Run as root (`sudo`)
- Network access to the target domain controller
- An AD account with permission to join computers to the target OU

## Usage

```bash
chmod +x join-ad.sh
sudo ./join-ad.sh
# follow prompts, reboot when asked
sudo ./join-ad.sh
# follow prompts to complete the join
```

## What it does NOT automate

- Creating the AD security group itself — that happens in Active Directory, not on the Linux box. Create it *before* running the script, since Stage 2 asks for the access/sudo group names near the end.
- SSH access restriction (`sshusers` group + `sshd_config` changes) — only needed on some machines.
- `chmod g+s` on shared directories — folder-specific, run manually as needed.

## Notes on department OU presets

The Business/Sciences `--computer-ou` presets are provided as a convenience starting point pulled from an internal runbook. **Verify the exact OU string for your environment before joining a production machine** — an incorrect OU can place the computer object in the wrong location in AD.

## Re-joining a machine already on the domain

If Stage 2 detects the machine is already joined to the target domain, it runs `realm leave` first, then rejoins.

## Verifying a successful join

```bash
realm list
id <domainuser>
touch testfile && ls -l testfile   # check group ownership if override_gid was set
```

## License

MIT — see [LICENSE](LICENSE), or remove this section if you'd rather not license it for reuse.
