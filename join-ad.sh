#!/usr/bin/env bash
#
# join-ad.sh — Automates joining an Ubuntu (22.04+) machine to ID.SDSU.EDU
# following the "Realm Join Instructions" runbook.
#
# Runs in two stages because a reboot is required in the middle:
#   STAGE 1 (first run):  time sync + hostname config, then reboot
#   STAGE 2 (after reboot, run script again): package install, realm
#            join, sssd.conf tuning, home dirs, sudoers group
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
stage1() {
  echo "=== Stage 1: time sync + hostname ==="

  read -r -p "NTP server to use (blank = leave timesyncd.conf default): " NTP_SERVER
  if [[ -n "${NTP_SERVER}" ]]; then
    backup_file /etc/systemd/timesyncd.conf
    if grep -q '^NTP=' /etc/systemd/timesyncd.conf 2>/dev/null; then
      sed -i "s/^NTP=.*/NTP=${NTP_SERVER}/" /etc/systemd/timesyncd.conf
    else
      echo "NTP=${NTP_SERVER}" >> /etc/systemd/timesyncd.conf
    fi
    timedatectl set-ntp true
    echo "Updated /etc/systemd/timesyncd.conf (backup at .bak-preadjoin)."
  fi

  read -r -p "New hostname for this machine (blank = keep current: $(hostname)): " NEW_HOSTNAME
  if [[ -n "${NEW_HOSTNAME}" ]]; then
    read -r -p "AD domain for the FQDN line in /etc/hosts [id.sdsu.edu]: " HOSTS_DOMAIN
    HOSTS_DOMAIN=${HOSTS_DOMAIN:-id.sdsu.edu}
    backup_file /etc/hostname
    backup_file /etc/hosts
    echo "${NEW_HOSTNAME}" > /etc/hostname
    hostnamectl set-hostname "${NEW_HOSTNAME}"
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${NEW_HOSTNAME}.${HOSTS_DOMAIN}\t${NEW_HOSTNAME}/" /etc/hosts
    else
      printf '127.0.1.1\t%s.%s\t%s\n' "${NEW_HOSTNAME}" "${HOSTS_DOMAIN}" "${NEW_HOSTNAME}" >> /etc/hosts
    fi
    echo "Updated hostname to ${NEW_HOSTNAME} (backups at .bak-preadjoin)."
  fi

  touch "${MARKER}"
  echo
  echo "Stage 1 complete. A reboot is required before joining the domain."
  if pause_confirm "Reboot now?"; then
    reboot
  else
    echo "Reboot manually, then re-run this script (sudo ./join-ad.sh) to continue with Stage 2."
  fi
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

  read -r -p "AD domain to join [ID.SDSU.EDU]: " DOMAIN
  DOMAIN=${DOMAIN:-ID.SDSU.EDU}

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

  read -r -p "Admin account to join with (e.g. jdoe-admin@${DOMAIN}): " ADMIN_USER
  read -r -p "Computer OU [${DEFAULT_OU}]: " COMPUTER_OU
  COMPUTER_OU=${COMPUTER_OU:-$DEFAULT_OU}

  if [[ -z "${ADMIN_USER}" || -z "${COMPUTER_OU}" ]]; then
    echo "Admin account and computer OU are required. Aborting join." >&2
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

  read -r -p "Lowercase AD group name to grant sudo (blank = skip, e.g. cos-ph-doganlab-sudo): " SUDO_GROUP
  if [[ -n "${SUDO_GROUP}" ]]; then
    echo "%${SUDO_GROUP} ALL=(ALL:ALL) ALL" > /etc/sudoers.d/domain
    chmod 440 /etc/sudoers.d/domain
    visudo -cf /etc/sudoers.d/domain
    echo "Wrote /etc/sudoers.d/domain granting sudo to %${SUDO_GROUP}."
  fi

  echo
  if pause_confirm "Restrict domain logins to specific users/groups (realm deny --all, then permit)?"; then
    realm deny --all
    echo "All domain users are now denied login by default."
    while pause_confirm "Permit another user or group?"; do
      read -r -p "  Type 'user' or 'group': " KIND
      read -r -p "  Name: " NAME
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
  echo "  - Creating the AD security group itself (AADSync > COS > Groups > Labs OU in AD)"
  echo "  - SSH access restriction (sshusers group + sshd_config) — see runbook if needed"
  echo "  - Shared directory setgid permissions (chmod g+s <folder>) — run per-folder as needed"
  echo "  - UMASK hardening in /etc/login.defs and /etc/profile — run manually if required"
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
