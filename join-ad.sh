#!/usr/bin/env bash
#
# join-ad.sh — Automates joining an Ubuntu (22.04+) machine to ID.SDSU.EDU
# following the "Realm Join Instructions" runbook.
#
# Runs everything in a single pass, one "sudo ./join-ad.sh" invocation:
#   1. NTP time sync (auto-detected/applied) + hostname + /etc/hosts config
#   2. package install, realm join, sssd.conf tuning, home dirs, UMASK
#      hardening, access/sudoers groups
#   3. a reboot prompt at the very end so you can log back in and verify
#      everything worked.
#
# No reboot is needed partway through, so there's no need to run this
# script more than once.
#
# Prompt tips: at free-text prompts (hostname, Computer OU) press Enter to
# accept the default. A stray "y" or "n" is rejected instead of being used
# as a value. Individual users can be permitted for login and given sudo
# without creating an AD security group.
#
# Must be run with sudo/root privileges.
#
set -euo pipefail

SSSD_CONF=/etc/sssd/sssd.conf

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run this script with sudo." >&2
    exit 1
  fi
}

pause_confirm() {
  local prompt="$1"
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

backup_file() {
  local f="$1"
  if [[ -f "$f" && ! -f "${f}.bak-preadjoin" ]]; then
    cp "$f" "${f}.bak-preadjoin"
  fi
}

# True when the answer looks like a stray yes/no typed at a free-text prompt.
looks_like_yes_no() {
  [[ "${1,,}" =~ ^(y|n|yes|no)$ ]]
}

# 1 to 15 characters (NetBIOS limit for AD computer accounts), letters,
# digits and hyphens, not starting or ending with a hyphen.
valid_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,13}[A-Za-z0-9])?$ ]]
}

# Expect a distinguished name such as OU=Workstations,OU=Dept,DC=id,DC=sdsu,DC=edu
valid_ou() {
  [[ "${1^^}" =~ ^(OU|CN)=.+,DC=.+ ]]
}

# Add one line to /etc/sudoers.d/domain. The change is validated on a
# temporary copy first, so a typo can never break sudo.
add_sudoers_line() {
  local line="$1" target=/etc/sudoers.d/domain tmp
  tmp=$(mktemp)
  if [[ -f "${target}" ]]; then
    cp "${target}" "${tmp}"
  fi
  if grep -qxF "${line}" "${tmp}"; then
    echo "Sudoers already contains: ${line}"
  else
    echo "${line}" >> "${tmp}"
  fi
  if visudo -cf "${tmp}" >/dev/null; then
    install -m 0440 -o root -g root "${tmp}" "${target}"
    echo "Sudoers updated (${target}): ${line}"
  else
    echo "WARNING: invalid sudoers line, not applied: ${line}" >&2
  fi
  rm -f "${tmp}"
}

### ---------------------------------------------------------------------
### Step 1: time sync + hostname
### ---------------------------------------------------------------------

# SDSU campus NTP servers, used as the auto-applied default when no NTP
# server is already configured in timesyncd.conf.
NTP_PRIMARY="130.191.1.1"
NTP_SECONDARY="130.191.200.1"

configure_ntp() {
  local existing
  existing=$(grep -E '^NTP=' /etc/systemd/timesyncd.conf 2>/dev/null | sed 's/^NTP=//' | xargs || true)

  if [[ -n "${existing}" ]]; then
    echo "NTP already configured in timesyncd.conf (NTP=${existing}) — leaving as-is."
    return
  fi

  echo "No NTP server configured yet. Setting NTP=${NTP_PRIMARY} ${NTP_SECONDARY}."
  backup_file /etc/systemd/timesyncd.conf
  if grep -q '^NTP=' /etc/systemd/timesyncd.conf 2>/dev/null; then
    sed -i "s/^NTP=.*/NTP=${NTP_PRIMARY} ${NTP_SECONDARY}/" /etc/systemd/timesyncd.conf
  else
    echo "NTP=${NTP_PRIMARY} ${NTP_SECONDARY}" >> /etc/systemd/timesyncd.conf
  fi
  timedatectl set-ntp true
  echo "Set primary NTP server ${NTP_PRIMARY} and secondary ${NTP_SECONDARY} (backup at .bak-preadjoin)."
}

# Ensure /etc/hosts has a correct FQDN + short-hostname mapping.
#
# NOTE: many Ubuntu server/cloud/cloud-init images do NOT have a 127.0.1.1
# line at all — they map the hostname via a 127.0.0.1 line instead (e.g.
# "127.0.0.1 old-hostname old-hostname"). Only handling 127.0.1.1, like
# earlier versions of this script did, misses that case: it appends a new
# 127.0.1.1 line but leaves the stale 127.0.0.1 entry with the OLD hostname
# in place, so the FQDN never resolves correctly. This handles both forms.
update_etc_hosts() {
  local new_hostname="$1" hosts_domain="$2"
  local fqdn="${new_hostname}.${hosts_domain}"

  backup_file /etc/hosts

  # Does a 127.0.0.1 line exist whose fields (after the IP) are something
  # other than just "localhost" — i.e. cloud-init style hostname mapping
  # such as "127.0.0.1 old-hostname old-hostname"?
  local loopback_line loopback_rest_trimmed=""
  loopback_line=$(grep -E '^127\.0\.0\.1[[:space:]]' /etc/hosts | head -n1 || true)
  if [[ -n "${loopback_line}" ]]; then
    loopback_rest_trimmed=$(echo "${loopback_line}" | awk '{ $1=""; print }' | xargs)
  fi

  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${fqdn}\t${new_hostname}/" /etc/hosts
  elif [[ -n "${loopback_rest_trimmed}" && "${loopback_rest_trimmed}" != "localhost" ]]; then
    # cloud-init style: 127.0.0.1 <old-hostname> [<old-hostname>] — replace
    # with a plain localhost entry and add a dedicated 127.0.1.1 FQDN line.
    sed -i -E "s/^127\.0\.0\.1[[:space:]].*/127.0.0.1\tlocalhost/" /etc/hosts
    printf '127.0.1.1\t%s\t%s\n' "${fqdn}" "${new_hostname}" >> /etc/hosts
  else
    printf '127.0.1.1\t%s\t%s\n' "${fqdn}" "${new_hostname}" >> /etc/hosts
  fi

  if ! grep -qE "^127\.0\.1\.1[[:space:]]+${fqdn//./\\.}[[:space:]]+${new_hostname}\$" /etc/hosts; then
    echo "WARNING: /etc/hosts does not look like it has the expected FQDN line after update." >&2
    echo "Check it manually: grep ^127 /etc/hosts" >&2
  fi
}

time_sync_and_hostname() {
  echo "=== Step 1: time sync + hostname ==="

  configure_ntp

  while true; do
    read -r -p "New hostname for this machine (press Enter to keep: $(hostname)): " NEW_HOSTNAME
    if [[ -z "${NEW_HOSTNAME}" ]]; then
      break
    elif looks_like_yes_no "${NEW_HOSTNAME}"; then
      echo "'${NEW_HOSTNAME}' looks like a yes/no answer. This prompt wants a hostname, or press Enter to keep '$(hostname)'."
    elif ! valid_hostname "${NEW_HOSTNAME}"; then
      echo "Invalid hostname. Use 1 to 15 letters, digits or hyphens (AD computer name limit)."
    else
      break
    fi
  done
  if [[ -n "${NEW_HOSTNAME}" ]]; then
    read -r -p "AD domain for the FQDN line in /etc/hosts [id.sdsu.edu]: " HOSTS_DOMAIN
    HOSTS_DOMAIN=${HOSTS_DOMAIN:-id.sdsu.edu}
    backup_file /etc/hostname
    echo "${NEW_HOSTNAME}" > /etc/hostname
    hostnamectl set-hostname "${NEW_HOSTNAME}"
    update_etc_hosts "${NEW_HOSTNAME}" "${HOSTS_DOMAIN}"
    echo "Updated hostname to ${NEW_HOSTNAME} (backups at .bak-preadjoin)."
    echo "Verify: grep ^127 /etc/hosts"
  fi

  echo
  echo "Time sync + hostname done. Continuing straight into the domain join —"
  echo "no reboot is needed until everything below is finished."
  echo
}

### ---------------------------------------------------------------------
### Packages + realm join + post-join config
### ---------------------------------------------------------------------
join_domain_and_configure() {
  echo "=== Step 2: package install + domain join ==="

  echo "Installing required packages..."
  apt-get update -y
  apt-get install -y realmd libnss-sss libpam-sss sssd sssd-tools adcli \
    samba-common-bin oddjob oddjob-mkhomedir packagekit

  DEFAULT_DOMAIN="ID.SDSU.EDU"
  if pause_confirm "Use default domain ${DEFAULT_DOMAIN}?"; then
    DOMAIN="${DEFAULT_DOMAIN}"
  else
    read -r -p "AD domain to join: " DOMAIN
    if [[ -z "${DOMAIN}" ]]; then
      echo "No domain entered. Aborting." >&2
      exit 1
    fi
  fi

  echo "Discovering domain ${DOMAIN}..."
  realm discover "${DOMAIN}" || echo "Warning: discover did not return output — check DNS before continuing."

  echo
  echo "Department presets (from the runbook — verify the OU string before use,"
  echo "these are supplied as a starting point, not a guarantee of correctness):"
  echo "  1) Business    admin pattern: <you>-admin@${DOMAIN}"
  echo "                 OU: OU=Workstations,OU=CBA,OU=AA,OU=Delegated OUs,DC=id,DC=sdsu,DC=edu"
  echo "  2) Sciences    admin pattern: <you>-admin@${DOMAIN}"
  echo "                 OU: OU=Workstations,OU=COS,OU=AA,OU=Delegated OUs,DC=id,DC=sdsu,DC=edu"
  echo "  3) Custom / other — enter your own admin account and OU"
  read -r -p "Choose 1, 2, or 3: " DEPT_CHOICE

  case "${DEPT_CHOICE}" in
    1)
      DEFAULT_OU="OU=Workstations,OU=CBA,OU=AA,OU=Delegated OUs,DC=id,DC=sdsu,DC=edu"
      ;;
    2)
      DEFAULT_OU="OU=Workstations,OU=COS,OU=AA,OU=Delegated OUs,DC=id,DC=sdsu,DC=edu"
      ;;
    *)
      DEFAULT_OU=""
      ;;
  esac

  read -r -p "Admin account name to join with, without @${DOMAIN} (e.g. jdoe-admin): " ADMIN_USER_SHORT
  if [[ -z "${ADMIN_USER_SHORT}" ]]; then
    echo "Admin account is required. Aborting join." >&2
    exit 1
  fi
  # Strip an @domain suffix if the user pasted one in anyway, so we don't
  # end up with a doubled-up "user@domain@domain" string.
  ADMIN_USER_SHORT="${ADMIN_USER_SHORT%%@*}"
  ADMIN_USER="${ADMIN_USER_SHORT}@${DOMAIN}"
  echo "Using admin account: ${ADMIN_USER}"

  while true; do
    read -r -p "Computer OU (press Enter to accept the default) [${DEFAULT_OU}]: " COMPUTER_OU
    COMPUTER_OU=${COMPUTER_OU:-$DEFAULT_OU}
    if [[ -z "${COMPUTER_OU}" ]]; then
      echo "A Computer OU is required. Enter the full DN, e.g. OU=Workstations,OU=Dept,DC=id,DC=sdsu,DC=edu"
    elif ! valid_ou "${COMPUTER_OU}"; then
      echo "That does not look like an OU distinguished name (expected OU=...,DC=...). Try again."
    else
      break
    fi
  done

  echo
  echo "About to run:"
  echo "  realm join -v -U ${ADMIN_USER} ${DOMAIN} --computer-ou=\"${COMPUTER_OU}\""
  if ! pause_confirm "Proceed?"; then
    echo "Aborted before join. Re-run the script to try again."
    exit 0
  fi

  # If this machine was previously joined, leave first so the join is clean.
  realm list | grep -q "${DOMAIN}" && { echo "Already joined — leaving first (rejoin)."; realm leave || true; }

  if ! realm join -v -U "${ADMIN_USER}" "${DOMAIN}" --computer-ou="${COMPUTER_OU}"; then
    echo >&2
    echo "The domain join failed. Common causes:" >&2
    echo "  - 'Preauthentication failed': wrong password, wrong admin account name, or a locked account." >&2
    echo "    Test with 'kinit ${ADMIN_USER}' (needs krb5-user) and avoid repeated attempts, which can lock the account." >&2
    echo "  - Wrong Computer OU, or the account lacks rights on that OU." >&2
    echo "  - Clock skew: check 'timedatectl status'." >&2
    echo "Fix the cause and run the script again." >&2
    exit 1
  fi

  echo
  echo "=== Post-join configuration ==="

  echo "Enabling home directory creation on first login..."
  pam-auth-update --enable mkhomedir

  echo "Applying UMASK hardening..."
  backup_file /etc/login.defs
  backup_file /etc/profile
  if grep -qE '^UMASK[[:space:]]' /etc/login.defs; then
    sed -i -E 's/^UMASK[[:space:]].*/UMASK           007/' /etc/login.defs
  else
    echo "UMASK           007" >> /etc/login.defs
  fi
  if grep -qE '^USERGROUPS_ENAB[[:space:]]' /etc/login.defs; then
    sed -i -E 's/^USERGROUPS_ENAB[[:space:]].*/USERGROUPS_ENAB no/' /etc/login.defs
  else
    echo "USERGROUPS_ENAB no" >> /etc/login.defs
  fi
  if ! grep -qE '^umask 007$' /etc/profile; then
    echo "umask 007" >> /etc/profile
  fi
  echo "Set UMASK 007 in /etc/login.defs and /etc/profile (backups at .bak-preadjoin)."

  backup_file "${SSSD_CONF}"

  echo "Applying recommended sssd.conf settings..."
  set_sssd_kv() {
    local key="$1" val="$2"
    if grep -q "^${key}[[:space:]]*=" "${SSSD_CONF}"; then
      sed -i "s|^${key}[[:space:]]*=.*|${key} = ${val}|" "${SSSD_CONF}"
    else
      # Append under [domain/...] section if present, else under [sssd]/global
      printf '%s = %s\n' "${key}" "${val}" >> "${SSSD_CONF}"
    fi
  }

  set_sssd_kv "use_fully_qualified_names" "False"
  set_sssd_kv "fallback_homedir" "/home/%u"
  set_sssd_kv "ad_gpo_access_control" "permissive"
  set_sssd_kv "ignore_group_members" "true"
  set_sssd_kv "ldap_referrals" "false"
  set_sssd_kv "auto_private_groups" "true"

  read -r -p "GID to set as default primary group for domain users (override_gid; blank = skip): " OVERRIDE_GID
  if [[ -n "${OVERRIDE_GID}" ]]; then
    set_sssd_kv "override_gid" "${OVERRIDE_GID}"
  fi

  chmod 600 "${SSSD_CONF}"

  echo "Restarting sssd and clearing cache..."
  systemctl stop sssd
  rm -rf /var/lib/sss/db/*
  systemctl start sssd

  read -r -p "AD group name to allow login access (realm permit --groups; blank = skip, e.g. COS-PH-DoganLab-Access): " ACCESS_GROUP
  ACCESS_GROUP=$(echo "${ACCESS_GROUP}" | tr '[:upper:]' '[:lower:]')

  read -r -p "AD group name to grant sudo (blank = skip, e.g. COS-PH-DoganLab-SudoPermission): " SUDO_GROUP
  SUDO_GROUP=$(echo "${SUDO_GROUP}" | tr '[:upper:]' '[:lower:]')

  if [[ -n "${SUDO_GROUP}" ]]; then
    add_sudoers_line "%${SUDO_GROUP} ALL=(ALL:ALL) ALL"
    echo "(group name lowercased automatically)"
  fi

  echo
  if [[ -n "${ACCESS_GROUP}" ]]; then
    if pause_confirm "Restrict domain logins to only the '${ACCESS_GROUP}' group (realm deny --all, then permit --groups)?"; then
      realm deny --all
      realm permit --groups "${ACCESS_GROUP}"
      echo "Login restricted to members of '${ACCESS_GROUP}' (lowercased automatically)."
    fi
  fi
  if pause_confirm "Permit any additional individual users or groups for login?"; then
    while pause_confirm "Permit another user or group?"; do
      KIND=""
      while [[ "${KIND}" != "user" && "${KIND}" != "group" ]]; do
        read -r -p "  Type the word 'user' or 'group': " KIND
        KIND=$(echo "${KIND}" | tr '[:upper:]' '[:lower:]')
      done
      read -r -p "  Exact AD ${KIND} name: " NAME
      NAME=$(echo "${NAME}" | tr '[:upper:]' '[:lower:]')
      if [[ -z "${NAME}" ]]; then
        echo "  No name entered, skipping."
        continue
      fi
      # Make sure the name exists in AD before it goes into the login policy.
      if [[ "${KIND}" == "group" ]]; then
        LOOKUP="group"
      else
        LOOKUP="passwd"
      fi
      if ! getent "${LOOKUP}" "${NAME}" >/dev/null; then
        echo "  '${NAME}' was not found in AD (getent ${LOOKUP}). Check the spelling."
        if ! pause_confirm "  Permit '${NAME}' anyway?"; then
          continue
        fi
      fi
      if [[ "${KIND}" == "group" ]]; then
        realm permit --groups "${NAME}"
        if pause_confirm "  Also grant sudo to members of '${NAME}'?"; then
          add_sudoers_line "%${NAME} ALL=(ALL:ALL) ALL"
        fi
      else
        realm permit "${NAME}"
        if pause_confirm "  Also grant sudo to '${NAME}'?"; then
          add_sudoers_line "${NAME} ALL=(ALL:ALL) ALL"
        fi
      fi
    done
  fi

  echo
  echo "=== Done ==="
  realm list || true
  echo
  echo "Verify with:"
  echo "  realm list"
  echo "  id <domainuser>"
  echo "  touch testfile && ls -l testfile   # check group ownership if override_gid was set"
  echo
  echo "Still manual (not automated by this script):"
  echo "  - Creating the AD security group itself (AADSync > COS > Groups > Labs OU in AD) — do this BEFORE running the script"
  echo "  - SSH access restriction (sshusers group + sshd_config) — see runbook if needed"
  echo "  - Shared directory setgid permissions (chmod g+s <folder>) — run per-folder as needed"
  echo
  echo "A reboot is recommended now so you can log back in and confirm the domain join,"
  echo "group access, and sudo permissions all work end-to-end."
  if pause_confirm "Reboot now?"; then
    reboot
  else
    echo "Remember to reboot manually, then log in to verify (see the checks above)."
  fi
}

### ---------------------------------------------------------------------
main() {
  require_root
  time_sync_and_hostname
  join_domain_and_configure
}

main "$@"
