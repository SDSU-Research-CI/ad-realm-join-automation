#!/usr/bin/env bash
#
# join-ad.sh — Automates joining an Ubuntu (22.04+) machine to ID.SDSU.EDU
# following the "Realm Join Instructions" runbook.
#
# Runs in two stages, re-run the script to move to Stage 2:
#   STAGE 1 (first run):  NTP time sync (auto-detected/applied) + hostname
#            + /etc/hosts config
#   STAGE 2 (run script again): package install, realm join, sssd.conf
#            tuning, home dirs, access/sudoers groups, then a reboot at
#            the very end so you can log back in and verify everything.
#
# The script detects which stage to run via a marker file in /var/tmp.
#
# Must be run with sudo/root privileges.
#
set -euo pipefail

MARKER=/var/tmp/ad-join-stage1-done
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

### ---------------------------------------------------------------------
### STAGE 1: time sync + hostname (pre-join, pre-reboot)
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

stage1() {
  echo "=== Stage 1: time sync + hostname ==="

  configure_ntp

  read -r -p "New hostname for this machine (blank = keep current: $(hostname)): " NEW_HOSTNAME
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

  touch "${MARKER}"
  echo
  echo "Stage 1 complete. Re-run this script (sudo ./join-ad.sh) to continue with Stage 2."
  echo "A reboot will be offered at the end of Stage 2, once the domain join and all"
  echo "post-join configuration is finished, so you can log back in and verify it worked."
}

### ---------------------------------------------------------------------
### STAGE 2: packages + realm join + post-join config
### ---------------------------------------------------------------------
stage2() {
  echo "=== Stage 2: package install + domain join ==="

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

  read -r -p "Computer OU [${DEFAULT_OU}]: " COMPUTER_OU
  COMPUTER_OU=${COMPUTER_OU:-$DEFAULT_OU}

  if [[ -z "${COMPUTER_OU}" ]]; then
    echo "Computer OU is required. Aborting join." >&2
    exit 1
  fi

  echo
  echo "About to run:"
  echo "  realm join -v -U ${ADMIN_USER} ${DOMAIN} --computer-ou=\"${COMPUTER_OU}\""
  if ! pause_confirm "Proceed?"; then
    echo "Aborted before join. Re-run the script to try again."
    exit 0
  fi

  # If this machine was previously joined, leave first so the join is clean.
  realm list | grep -q "${DOMAIN}" && { echo "Already joined — leaving first (rejoin)."; realm leave || true; }

  realm join -v -U "${ADMIN_USER}" "${DOMAIN}" --computer-ou="${COMPUTER_OU}"

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
    echo "%${SUDO_GROUP} ALL=(ALL:ALL) ALL" > /etc/sudoers.d/domain
    chmod 440 /etc/sudoers.d/domain
    visudo -cf /etc/sudoers.d/domain
    echo "Wrote /etc/sudoers.d/domain granting sudo to %${SUDO_GROUP} (lowercased automatically)."
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
      read -r -p "  Type 'user' or 'group': " KIND
      read -r -p "  Name: " NAME
      NAME=$(echo "${NAME}" | tr '[:upper:]' '[:lower:]')
      if [[ "${KIND}" == "group" ]]; then
        realm permit --groups "${NAME}"
      else
        realm permit "${NAME}"
      fi
    done
  fi

  rm -f "${MARKER}"

  echo
  echo "=== Done ==="
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
  if [[ -f "${MARKER}" ]]; then
    stage2
  else
    stage1
  fi
}

main "$@"
