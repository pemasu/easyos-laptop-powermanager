#!/usr/bin/env bash
# ----------------------------------------------------------------------
#  vpower-engine.sh — universal power saver for Linux laptops
#  Detects your processor (Intel / AMD / ARM) when it runs and adapts.
#
#    sudo ./flight-mode.sh             switch flight mode on
#    sudo ./flight-mode.sh --dry-run   preview, change nothing
#    ./flight-mode.sh --status         CPU, battery and power draw
#    sudo ./flight-mode.sh --restore   back to your normal settings
# ----------------------------------------------------------------------
set -u

# ---- Settings: 1 = on, 0 = off (edit freely) -------------------------
PLATFORM_PROFILE="${PLATFORM_PROFILE:-1}"        # "power-saver" profile / firmware low-power mode
CPU_POWERSAVE="${CPU_POWERSAVE:-1}"           # power-saving governor + energy preference "power"
DISABLE_TURBO="${DISABLE_TURBO:-1}"           # Intel Turbo Boost / AMD Precision Boost off
MAX_FREQ_PERCENT="${MAX_FREQ_PERCENT:-70}"      # CPU & graphics top speed, % of maximum (100 = no cap)
KEEP_CORES="${KEEP_CORES:-0}"             # CPU threads kept on, most efficient first (0 = all)
SET_BRIGHTNESS="${SET_BRIGHTNESS:-1}"
BRIGHTNESS_PERCENT="${BRIGHTNESS_PERCENT:-25}"
KEYBOARD_BACKLIGHT_OFF="${KEYBOARD_BACKLIGHT_OFF:-1}"
WIFI_MODE="${WIFI_MODE:-off}"       # keep | powersave | off
BLUETOOTH_OFF="${BLUETOOTH_OFF:-1}"
WWAN_OFF="${WWAN_OFF:-1}"                # mobile broadband modem
USB_AUTOSUSPEND="${USB_AUTOSUSPEND:-1}"         # mice and keyboards are always left awake
PCI_RUNTIME_PM="${PCI_RUNTIME_PM:-1}"
PCIE_ASPM="${PCIE_ASPM:-1}"
SATA_LPM="${SATA_LPM:-1}"
AUDIO_POWERSAVE="${AUDIO_POWERSAVE:-1}"
GPU_LOW_POWER="${GPU_LOW_POWER:-1}"
KERNEL_TWEAKS="${KERNEL_TWEAKS:-1}"           # NMI watchdog off, batched disk writes
STOP_SERVICES="${STOP_SERVICES:-}"
RUN_POWERTOP="${RUN_POWERTOP:-1}"            # powertop --auto-tune
INSTALL_TOOLS="${INSTALL_TOOLS:-0}"           # install powertop / iw if missing (needs internet)

RFKILL_ALL="${RFKILL_ALL:-0}"         # 1 = rfkill block all

# ======================================================================
#  Engine — no need to edit below this line
# ======================================================================
STATE_FILE="/var/tmp/vpower.restore"
DRY_RUN=0
MODE=apply
SELF="${VPOWER_SELF:-$0}"

usage() {
  cat <<'USAGE'
Usage: sudo ./flight-mode.sh [option]
  (no option)   apply the power-saving settings
  --dry-run     show what would change, change nothing
  --status      show CPU, battery and power draw
  --restore     put back the values saved before applying
  --help        this text
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --restore|off) MODE=restore ;;
    --status|status) MODE=status ;;
    on) MODE=apply ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

if [ -t 1 ]; then
  C_HEAD=$'\033[1;33m'; C_OK=$'\033[0;32m'; C_SKIP=$'\033[0;90m'; C_WARN=$'\033[0;31m'; C_END=$'\033[0m'
else
  C_HEAD=""; C_OK=""; C_SKIP=""; C_WARN=""; C_END=""
fi
section() { printf '\n%s== %s ==%s\n' "$C_HEAD" "$*" "$C_END"; }
ok()      { printf '  %s+%s %s\n' "$C_OK" "$C_END" "$*"; }
skip()    { printf '  %s-%s %s\n' "$C_SKIP" "$C_END" "$*"; }
warn()    { printf '  %s!%s %s\n' "$C_WARN" "$C_END" "$*"; }
have()    { command -v "$1" >/dev/null 2>&1; }
would()   { printf '    would %s\n' "$*"; }

# remember KEY VALUE — keeps only the first (original) value of each key
remember() {
  [ "$DRY_RUN" = 1 ] && return 0
  if [ -f "$STATE_FILE" ] && awk -F'\t' -v k="$1" '$1==k{f=1} END{exit !f}' "$STATE_FILE"; then
    return 0
  fi
  printf '%s\t%s\n' "$1" "$2" >> "$STATE_FILE"
}

# current_val PATH — reads a sysfs value; "a [b] c" style files return b
current_val() {
  local v
  v=$(cat "$1" 2>/dev/null) || return 1
  case "$v" in
    *"["*"]"*) v=$(printf '%s' "$v" | sed -n 's/.*\[\([^]]*\)\].*/\1/p') ;;
  esac
  printf '%s' "$v"
}

# set_val PATH VALUE — writes a sysfs/procfs value and saves the old one
set_val() {
  local path="$1" value="$2" old
  [ -e "$path" ] || return 1
  old=$(current_val "$path") || return 1
  [ "$old" = "$value" ] && return 0
  if [ "$DRY_RUN" = 1 ]; then
    would "set $path: $old -> $value"
    return 0
  fi
  if printf '%s' "$value" > "$path" 2>/dev/null; then
    remember "$path" "$old"
    return 0
  fi
  return 1
}

# expand_list "0-3,8" -> one number per line
expand_list() {
  local IFS=, part
  for part in $1; do
    case "$part" in
      *-*) seq "${part%-*}" "${part#*-}" ;;
      *) echo "$part" ;;
    esac
  done
}

is_usb_input() { grep -qsx '03' "$1"/*/bInterfaceClass; }

install_pkg() {
  local pkg="$1"
  if [ "$DRY_RUN" = 1 ]; then would "install $pkg"; return 0; fi
  {
    if have apt-get; then apt-get install -y "$pkg"
    elif have dnf; then dnf install -y "$pkg"
    elif have pacman; then pacman -S --noconfirm --needed "$pkg"
    elif have zypper; then zypper --non-interactive install "$pkg"
    elif have apk; then apk add "$pkg"
    elif have xbps-install; then xbps-install -y "$pkg"
    else false
    fi
  } >/dev/null 2>&1 && { ok "Installed $pkg"; return 0; }
  warn "Could not install $pkg (no internet or unknown package manager)"
  return 1
}

# ---------------------------------------------------------------- detect
detect_cpu() {
  CPU_VENDOR=$(awk -F': *' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
  CPU_MODEL=$(awk -F': *' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
  if [ -z "$CPU_MODEL" ] && have lscpu; then
    CPU_MODEL=$(lscpu 2>/dev/null | awk -F': *' '/^Model name/{print $2; exit}')
  fi
  case "$CPU_VENDOR" in
    GenuineIntel) CPU_KIND=intel ;;
    AuthenticAMD|HygonGenuine) CPU_KIND=amd ;;
    *) case "$(uname -m)" in aarch64|arm*) CPU_KIND=arm ;; *) CPU_KIND=other ;; esac ;;
  esac
  CPU_DRIVER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo none)
  CPU_THREADS=$(nproc --all 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
  CPU_ECORES=""
  if [ -r /sys/devices/cpu_atom/cpus ]; then CPU_ECORES=$(cat /sys/devices/cpu_atom/cpus); fi
}

# CPU numbers, most efficient first (cpu0 always first: it usually cannot go offline)
core_order() {
  local list="" f n d
  if [ -n "$CPU_ECORES" ]; then
    list=$(expand_list "$CPU_ECORES")
  elif ls /sys/devices/system/cpu/cpu[0-9]*/cpu_capacity >/dev/null 2>&1; then
    list=$(for f in /sys/devices/system/cpu/cpu[0-9]*/cpu_capacity; do
      n=${f%/cpu_capacity}; n=${n##*cpu}; echo "$(cat "$f") $n"
    done | sort -n | awk '{print $2}')
  fi
  {
    echo 0
    echo "$list"
    for d in /sys/devices/system/cpu/cpu[0-9]*; do echo "${d##*cpu}"; done | sort -n
  } | awk 'NF && !seen[$0]++'
}

check_conflicts() {
  if have systemctl && systemctl is-active --quiet tlp 2>/dev/null; then
    warn "TLP is running — it may undo some settings when you plug/unplug power"
  fi
  if have systemctl && systemctl is-active --quiet auto-cpufreq 2>/dev/null; then
    warn "auto-cpufreq is running — it will fight the CPU settings"
  fi
}

# ---------------------------------------------------------------- apply
apply_platform() {
  section "Power profile"
  local cur
  if have powerprofilesctl && cur=$(powerprofilesctl get 2>/dev/null); then
    if [ "$cur" != power-saver ]; then
      if [ "$DRY_RUN" = 1 ]; then would "run powerprofilesctl set power-saver"
      elif powerprofilesctl set power-saver 2>/dev/null; then remember "ppd:" "$cur"
      else warn "powerprofilesctl failed"; return; fi
    fi
    ok "System power profile: power-saver"
    return
  fi
  if [ -e /sys/firmware/acpi/platform_profile ]; then
    local choices p
    choices=" $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null) "
    for p in low-power quiet cool; do
      case "$choices" in
        *" $p "*) set_val /sys/firmware/acpi/platform_profile "$p" && ok "Firmware profile: $p"; return ;;
      esac
    done
  fi
  skip "No power profile service or firmware profile found"
}

apply_cpu() {
  section "Processor"
  ok "Detected: ${CPU_MODEL:-unknown CPU} ($CPU_KIND, driver $CPU_DRIVER, $CPU_THREADS threads)"
  [ -n "$CPU_ECORES" ] && ok "Hybrid CPU, efficiency cores: $CPU_ECORES"
  local pol n f

  if [ "$CPU_POWERSAVE" = 1 ]; then
    local avail gov="" g pref
    case "$CPU_DRIVER" in
      intel_pstate|amd-pstate-epp) pref="powersave" ;;
      *) pref="conservative schedutil powersave" ;;
    esac
    n=0
    for pol in /sys/devices/system/cpu/cpufreq/policy*; do
      [ -d "$pol" ] || continue
      avail=" $(cat "$pol/scaling_available_governors" 2>/dev/null) "
      gov=""
      if [ -n "$GOVERNOR" ]; then case "$avail" in *" $GOVERNOR "*) gov=$GOVERNOR ;; esac; fi
      [ -z "$gov" ] && for g in $pref; do case "$avail" in *" $g "*) gov=$g; break ;; esac; done
      [ -n "$gov" ] && set_val "$pol/scaling_governor" "$gov" && n=$((n+1))
    done
    if [ "$n" -gt 0 ]; then ok "Governor: $gov ($n CPU groups)"; else skip "No CPU frequency scaling available"; fi

    n=0
    for f in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do
      [ -e "$f" ] && set_val "$f" power && n=$((n+1))
    done
    if [ "$n" -gt 0 ]; then ok "Energy preference: power"; else skip "Energy preference not supported by $CPU_DRIVER"; fi

    n=0
    for f in /sys/devices/system/cpu/cpu[0-9]*/power/energy_perf_bias; do
      [ -e "$f" ] && set_val "$f" 15 && n=$((n+1))
    done
    [ "$n" -gt 0 ] && ok "Energy bias: maximum power saving"
  fi

  if [ "$DISABLE_TURBO" = 1 ]; then
    if set_val /sys/devices/system/cpu/intel_pstate/no_turbo 1; then ok "Intel Turbo Boost off"
    elif set_val /sys/devices/system/cpu/cpufreq/boost 0; then ok "CPU boost off"
    else
      n=0
      for f in /sys/devices/system/cpu/cpufreq/policy*/boost; do
        [ -e "$f" ] && set_val "$f" 0 && n=$((n+1))
      done
      if [ "$n" -gt 0 ]; then ok "CPU boost off ($n CPU groups)"; else skip "Boost control not available"; fi
    fi
  fi

  if [ "$MAX_FREQ_PERCENT" -lt 100 ]; then
    local max min target
    [ -e /sys/devices/system/cpu/intel_pstate/max_perf_pct ] && \
      set_val /sys/devices/system/cpu/intel_pstate/max_perf_pct "$MAX_FREQ_PERCENT"
    n=0
    for pol in /sys/devices/system/cpu/cpufreq/policy*; do
      max=$(cat "$pol/cpuinfo_max_freq" 2>/dev/null) || continue
      min=$(cat "$pol/cpuinfo_min_freq" 2>/dev/null || echo 0)
      target=$(( max * MAX_FREQ_PERCENT / 100 ))
      [ "$target" -lt "$min" ] && target=$min
      set_val "$pol/scaling_max_freq" "$target" && n=$((n+1))
    done
    if [ "$n" -gt 0 ]; then ok "Top speed capped at $MAX_FREQ_PERCENT%"; else skip "Cannot cap CPU speed"; fi
  fi

  if [ "$KEEP_CORES" -gt 0 ] && [ "$KEEP_CORES" -lt "$CPU_THREADS" ]; then
    local i=0 c off=0
    for c in $(core_order); do
      i=$((i+1))
      [ "$i" -le "$KEEP_CORES" ] && continue
      set_val "/sys/devices/system/cpu/cpu$c/online" 0 && off=$((off+1))
    done
    if [ "$off" -gt 0 ]; then ok "$off CPU threads switched off, $KEEP_CORES kept (most efficient first)"
    else skip "CPU threads cannot be switched off on this machine"; fi
  fi
}

apply_display() {
  section "Screen & keyboard"
  local bl max target n=0 led
  if [ "$SET_BRIGHTNESS" = 1 ]; then
    for bl in /sys/class/backlight/*; do
      [ -e "$bl/brightness" ] || continue
      max=$(cat "$bl/max_brightness" 2>/dev/null) || continue
      target=$(( max * BRIGHTNESS_PERCENT / 100 ))
      [ "$target" -lt 1 ] && target=1
      set_val "$bl/brightness" "$target" && n=$((n+1))
    done
    if [ "$n" -gt 0 ]; then ok "Screen brightness: $BRIGHTNESS_PERCENT%"; else skip "No adjustable screen backlight found"; fi
  fi
  if [ "$KEYBOARD_BACKLIGHT_OFF" = 1 ]; then
    n=0
    for led in /sys/class/leds/*kbd_backlight*; do
      [ -e "$led/brightness" ] && set_val "$led/brightness" 0 && n=$((n+1))
    done
    if [ "$n" -gt 0 ]; then ok "Keyboard backlight off"; else skip "No keyboard backlight found"; fi
  fi
}

rfkill_block() {
  local type="$1" label="$2" list
  have rfkill || { skip "rfkill not installed — $label left on"; return; }
  list=$(rfkill list "$type" 2>/dev/null)
  if printf '%s' "$list" | grep -q 'Soft blocked: no'; then
    if [ "$DRY_RUN" = 1 ]; then would "run rfkill block $type"
    else rfkill block "$type" && remember "rfkill:$type" unblocked; fi
    ok "$label off"
  elif printf '%s' "$list" | grep -q 'Soft blocked: yes'; then
    ok "$label already off"
  else
    skip "No $label hardware"
  fi
}

apply_radios() {
  section "Wireless"
  if [ "$RFKILL_ALL" = 1 ]; then rfkill_block all "All radios"; return 0; fi
  case "$WIFI_MODE" in
    off) rfkill_block wifi "Wi-Fi" ;;
    powersave)
      if ! have iw && [ "$INSTALL_TOOLS" = 1 ]; then install_pkg iw; fi
      if have iw; then
        local dev ifc cur n=0
        for dev in /sys/class/net/*; do
          [ -d "$dev/wireless" ] || [ -d "$dev/phy80211" ] || continue
          ifc=${dev##*/}
          cur=$(iw dev "$ifc" get power_save 2>/dev/null | awk '{print $NF}')
          [ -n "$cur" ] || continue
          if [ "$cur" != on ]; then
            if [ "$DRY_RUN" = 1 ]; then would "run iw dev $ifc set power_save on"
            else iw dev "$ifc" set power_save on 2>/dev/null && remember "iw:$ifc" "$cur"; fi
          fi
          n=$((n+1))
        done
        if [ "$n" -gt 0 ]; then ok "Wi-Fi power saving on"; else skip "No Wi-Fi adapter found"; fi
      else
        skip "iw not installed — Wi-Fi power saving skipped"
      fi
      ;;
    *) skip "Wi-Fi left as is" ;;
  esac
  [ "$BLUETOOTH_OFF" = 1 ] && rfkill_block bluetooth "Bluetooth"
  [ "$WWAN_OFF" = 1 ] && rfkill_block wwan "Mobile broadband"
  return 0
}

apply_devices() {
  section "Devices"
  local dev n f
  if [ "$USB_AUTOSUSPEND" = 1 ]; then
    n=0
    for dev in /sys/bus/usb/devices/*; do
      [ -e "$dev/power/control" ] || continue
      is_usb_input "$dev" && continue
      set_val "$dev/power/control" auto && n=$((n+1))
    done
    ok "USB auto-sleep on $n devices (mice and keyboards stay awake)"
  fi
  if [ "$PCI_RUNTIME_PM" = 1 ]; then
    n=0
    for dev in /sys/bus/pci/devices/*; do
      [ -e "$dev/power/control" ] && set_val "$dev/power/control" auto && n=$((n+1))
    done
    ok "PCI auto-sleep on $n devices"
  fi
  if [ "$PCIE_ASPM" = 1 ]; then
    if set_val /sys/module/pcie_aspm/parameters/policy powersupersave || \
       set_val /sys/module/pcie_aspm/parameters/policy powersave; then
      ok "PCIe link power saving on"
    else
      skip "PCIe link power saving locked by firmware"
    fi
  fi
  if [ "$SATA_LPM" = 1 ]; then
    n=0
    for f in /sys/class/scsi_host/host*/link_power_management_policy; do
      [ -e "$f" ] || continue
      { set_val "$f" med_power_with_dipm || set_val "$f" min_power; } && n=$((n+1))
    done
    if [ "$n" -gt 0 ]; then ok "SATA link power saving on"; else skip "No SATA links"; fi
  fi
  if [ "$AUDIO_POWERSAVE" = 1 ]; then
    if set_val /sys/module/snd_hda_intel/parameters/power_save 1; then
      set_val /sys/module/snd_hda_intel/parameters/power_save_controller Y
      ok "Sound chip sleeps when silent"
    else
      skip "Sound power saving not available"
    fi
  fi
  if [ "$GPU_LOW_POWER" = 1 ]; then
    n=0
    for f in /sys/class/drm/card[0-9]*/device/power_dpm_force_performance_level; do
      [ -e "$f" ] && set_val "$f" low && n=$((n+1))
    done
    local card rpn rp0
    for card in /sys/class/drm/card[0-9]*; do
      [ -e "$card/gt_max_freq_mhz" ] && [ -e "$card/gt_RPn_freq_mhz" ] || continue
      rpn=$(cat "$card/gt_RPn_freq_mhz"); rp0=$(cat "$card/gt_RP0_freq_mhz" 2>/dev/null || echo "$rpn")
      set_val "$card/gt_boost_freq_mhz" "$rpn" 2>/dev/null
      set_val "$card/gt_max_freq_mhz" $(( rpn + (rp0 - rpn) * MAX_FREQ_PERCENT / 100 )) && n=$((n+1))
    done
    if [ "$n" -gt 0 ]; then ok "Graphics chip in low-power mode"; else skip "No adjustable graphics chip"; fi
  fi
}

apply_kernel() {
  section "System"
  if set_val /proc/sys/kernel/nmi_watchdog 0; then ok "NMI watchdog off"; else skip "NMI watchdog not adjustable"; fi
  if set_val /proc/sys/vm/dirty_writeback_centisecs 1500; then ok "Disk writes batched every 15 s"; fi
  if set_val /proc/sys/vm/laptop_mode 5; then ok "Laptop mode on"; fi
}

apply_services() {
  [ -n "$STOP_SERVICES" ] || return 0
  section "Background services"
  have systemctl || { skip "systemd not found"; return; }
  local s
  for s in $STOP_SERVICES; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then
      if [ "$DRY_RUN" = 1 ]; then would "run systemctl stop $s"
      else systemctl stop "$s" 2>/dev/null && remember "service:$s" active; fi
      ok "Stopped $s"
    else
      skip "$s not running"
    fi
  done
}

apply_powertop() {
  section "PowerTOP"
  if ! have powertop && [ "$INSTALL_TOOLS" = 1 ]; then install_pkg powertop; fi
  if ! have powertop; then
    skip "powertop not installed — install it before your flight"
    return
  fi
  if [ "$DRY_RUN" = 1 ]; then would "run powertop --auto-tune"; return; fi
  if powertop --auto-tune >/dev/null 2>&1; then
    ok "powertop --auto-tune applied (a reboot undoes it)"
  else
    warn "powertop --auto-tune failed"
  fi
  # powertop also puts mice and keyboards to sleep, which makes them lag — wake them
  local dev
  for dev in /sys/bus/usb/devices/*; do
    [ -e "$dev/power/control" ] && is_usb_input "$dev" && printf on > "$dev/power/control" 2>/dev/null
  done
  ok "Mice, trackpads and keyboards kept awake"
}

# ---------------------------------------------------------------- status
show_battery() {
  local bat found=0 cap status pw en cur volt line
  for bat in /sys/class/power_supply/*; do
    [ "$(cat "$bat/type" 2>/dev/null)" = Battery ] || continue
    found=1; pw=""; en=""
    cap=$(cat "$bat/capacity" 2>/dev/null || echo "?")
    status=$(cat "$bat/status" 2>/dev/null || echo "?")
    volt=$(cat "$bat/voltage_now" 2>/dev/null || echo "")
    if [ -r "$bat/power_now" ]; then
      pw=$(cat "$bat/power_now")
    elif [ -r "$bat/current_now" ] && [ -n "$volt" ]; then
      cur=$(cat "$bat/current_now"); cur=${cur#-}
      pw=$(( cur / 1000 * volt / 1000 ))
    fi
    pw=${pw#-}
    if [ -r "$bat/energy_now" ]; then
      en=$(cat "$bat/energy_now")
    elif [ -r "$bat/charge_now" ] && [ -n "$volt" ]; then
      en=$(( $(cat "$bat/charge_now") / 1000 * volt / 1000 ))
    fi
    line="${bat##*/}: $cap% ($status)"
    if [ -n "$pw" ] && [ "$pw" -gt 0 ] 2>/dev/null; then
      line="$line, using $(awk -v p="$pw" 'BEGIN{printf "%.1f W", p/1e6}')"
      if [ -n "$en" ] && [ "$status" = Discharging ]; then
        line="$line, about $(awk -v e="$en" -v p="$pw" 'BEGIN{h=e/p; printf "%dh %02dm", int(h), (h-int(h))*60}') left"
      fi
    fi
    ok "$line"
  done
  [ "$found" = 1 ] || skip "No battery found"
}

show_status() {
  section "Processor"
  ok "${CPU_MODEL:-unknown CPU} ($CPU_KIND, driver $CPU_DRIVER)"
  ok "Online threads: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo '?') of $CPU_THREADS"
  ok "Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  ok "Energy preference: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo n/a)"
  if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    ok "Turbo: $([ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" = 1 ] && echo off || echo on)"
  elif [ -r /sys/devices/system/cpu/cpufreq/boost ]; then
    ok "Boost: $([ "$(cat /sys/devices/system/cpu/cpufreq/boost)" = 0 ] && echo off || echo on)"
  fi
  section "Battery"
  show_battery
  section "Saved settings"
  if [ -f "$STATE_FILE" ]; then ok "Power saving ON — press Restore to undo"; else skip "off"; fi
}

do_restore() {
  section "Restoring your normal settings"
  if [ ! -f "$STATE_FILE" ]; then
    skip "Nothing saved — flight mode is not on"
    return
  fi
  local key value n=0
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] || continue
    if [ "$DRY_RUN" = 1 ]; then would "restore $key -> $value"; continue; fi
    case "$key" in
      rfkill:*) rfkill unblock "${key#rfkill:}" ;;
      service:*) systemctl start "${key#service:}" ;;
      iw:*) iw dev "${key#iw:}" set power_save "$value" ;;
      ppd:) powerprofilesctl set "$value" ;;
      *) printf '%s' "$value" > "$key" ;;
    esac 2>/dev/null && n=$((n+1)) || warn "Could not restore $key"
  done < <(tac "$STATE_FILE")
  [ "$DRY_RUN" = 1 ] && return
  rm -f "$STATE_FILE"
  ok "$n settings restored"
  skip "powertop changes are undone by a reboot"
}

# ---------------------------------------------------------------- main
if [ "$(uname -s)" != Linux ]; then
  echo "This script is for Linux laptops."
  exit 1
fi
if [ "$MODE" != status ] && [ "$DRY_RUN" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root:  sudo $SELF $*"
  exit 1
fi

detect_cpu
case "$MODE" in
  status) show_status ;;
  restore) do_restore ;;
  apply)
    printf '%s%s%s' "$C_HEAD" "${MODE_NAME:-Flight mode}" "$C_END"
    [ "$DRY_RUN" = 1 ] && printf ' — dry run, nothing will change'
    printf '\n'
    check_conflicts
    [ "$PLATFORM_PROFILE" = 1 ] && apply_platform
    apply_cpu
    apply_display
    apply_radios
    apply_devices
    [ "$KERNEL_TWEAKS" = 1 ] && apply_kernel
    apply_services
    [ "$RUN_POWERTOP" = 1 ] && apply_powertop
    section "Battery"
    show_battery
    printf '\nDone. Power readings settle after a minute: %s --status\n' "$SELF"
    printf 'Back to normal: press Restore\n'
    ;;
esac
exit 0
