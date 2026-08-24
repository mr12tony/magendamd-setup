#!/bin/bash
#
#	rustdesk-daemon-install - public domain 2024

#	Ver	Who	Date	Note
#	001	GK	241219	Initial setup - tested on ProxMox machine - permissions had to be manually responded to in GUI
#	002	HM	250224	Fix custom client support: APP_NAME, pref paths, plist labels, MDM user detection
#	003	HM	250224	Fix GetAssets timing (require $APP), apply correct_app_name to install.scpt
#	004	HM	250224	Split GetAssets: view options (-v) no longer blocked by user/app checks
#	005	HM	250224	Fix -a/-d/-s blocked by user validation; fix dscl space-in-path truncation


#	Setup RustDesk services for Mac - even in a VM environment (presuming a copy of Preferences from another machine)

#	Optionally set ID and password - to make it work on a MacOS Vm

#	Server is for a user
#	Service is for the machine

#
# This script will find the app in /Applications or a subfolder or subfolder of a subfolder
#

# From lib/log
Msg()	{	echo "$(date +%d:%k%M%S)	$$	$@" >&2;	}
Err()	{	Msg "<***> $@ <***>"; return 42;			}
Throw()	{	[ -n "$1" ] && Msg "=== $1 ==="; exit ${2:-22}; exit 9;	}

#
# ===== CUSTOM CLIENT CONFIGURATION =====
# For custom clients, only change DEFAULTPATH to your app path.
# Everything else is auto-derived.
#
# Example:
#   DEFAULTPATH='/Applications/MyApp.app'
#   DEFAULTPATH='/Applications/Subfolder/MyApp.app'
#   DEFAULTPATH='/opt/MyApp.app'   (also works — FindApp checks DEFAULTPATH first)
#
# How naming works (hardcoded in RustDesk, cannot be changed):
#   APP_NAME     = basename of DEFAULTPATH without .app  (e.g. "MyApp")
#   FULL_NAME    = "com.carriez.{APP_NAME}"  (e.g. "com.carriez.MyApp")
#   Plist files  = /Library/LaunchDaemons/com.carriez.MyApp_service.plist
#                  /Library/LaunchAgents/com.carriez.MyApp_server.plist
#   Config path  = ~/Library/Preferences/com.carriez.MyApp/
#   Config files = MyApp.toml, MyApp2.toml
#
# Note: The app's bundle identifier (e.g. com.mycompany.myapp) does NOT affect
#       any of the above. RustDesk always uses "com.carriez.{APP_NAME}" internally.
# ========================================
#

# ========================== CONFIGURATION ==========================

DEFAULTPATH='/Applications/RustDesk.app'
# On reinstall, clear the "stop-service" flag left by a previous uninstall:
#   1 = remove stop-service line from existing toml configs before installing
#       (recommended for MDM redeployment — prevents the "service running but not
#       connecting" issue when redeploying to a Mac that had the service stopped/uninstalled)
#   0 = leave existing config untouched (original behavior)
CLEAR_STOP_SERVICE=1
# If config files don't exist:
#   1 = auto-create empty config files (recommended for custom clients / MDM deployment,
#       server config is embedded in the binary at build time, service will populate on first run)
#   0 = exit with error (original behavior, useful when you need pre-configured toml files)
AUTO_CREATE_CONFIG=1

# ========================== END CONFIGURATION ==========================

# Derive APP_NAME from DEFAULTPATH (e.g. /Applications/Test2.app -> Test2)
APP_NAME="$(basename "$DEFAULTPATH" .app)"

# FULL_NAME matches RustDesk's get_full_name(): "{ORG}.{APP_NAME}"
# ORG is always "com.carriez" on macOS (hardcoded in config.rs)
FULL_NAME="com.carriez.${APP_NAME}"

# Are we running as root - not really normal for a mac - maybe sudo'd
# Enhanced for MDM context where SUDO_USER and USER may be empty
FORUSER_OVERRIDE=''

if [ $(id -u) -eq 0 ]; then
	SUDO=''
	FORUSER=${SUDO_USER:-$USER}
	# In MDM postinstall context, both SUDO_USER and USER can be empty
	if [ -z "$FORUSER" ] || [ "$FORUSER" = "root" ]; then
		FORUSER=$(scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null | awk '/Name :/ && !/loginwindow/ { print $3 }')
	fi
else
	SUDO='sudo'
	FORUSER=$(id -un)
fi

APP=''

AGENT=''	# Assets from Github
DAEMON=''
ASCPT=''

USESCRIPT=0		#	Use AppleScript instead of direct install
USE_ID=''		#	Set ID of this machine via id= in toml file
USE_PWD=''		#	Set permanent password to this if non-null
VIEW_ONLY=0		#	Set by -a/-d/-s to skip the infinite wait loop

agent_path="/Library/LaunchAgents/${FULL_NAME}_server.plist"
daemon_path="/Library/LaunchDaemons/${FULL_NAME}_service.plist"
root_pref_path="/var/root/Library/Preferences/$FULL_NAME"
# user_pref_path is set after FORUSER is resolved (depends on user's home directory)

pref_files="${APP_NAME}.toml ${APP_NAME}2.toml"

EnsureConfig()
 {
	local i
	Msg "Verify $FORUSER ($FORUID) preferences..."

	# Ensure preference directory and config files exist
	if [ ! -d "$user_pref_path" ]; then
		if [ "$AUTO_CREATE_CONFIG" -eq 1 ]; then
			Msg "Creating preference directory: $user_pref_path"
			$SUDO mkdir -p "$user_pref_path"
			$SUDO chown "$FORUSER" "$user_pref_path"
		else
			Throw "Preference directory $user_pref_path does not exist for user $FORUSER"
		fi
	fi
	for i in $pref_files; do
		if [ ! -s "$user_pref_path/$i" ]; then
			if [ "$AUTO_CREATE_CONFIG" -eq 1 ]; then
				Msg "Config file $i not found for user $FORUSER — creating empty config (service will populate on first run)"
				$SUDO touch "$user_pref_path/$i"
				$SUDO chown "$FORUSER" "$user_pref_path/$i"
			else
				Throw "Missing preference file $i for user $FORUSER - this is needed for the system-wide settings copy

	If running this in a VM
		Copy a known good $FULL_NAME
			from ~/Library/Preferences
			on a real mac
			(or a Linux .config/$FULL_NAME)
			to $user_pref_path on this VM

		Then run this script again and use the -i ID option to
			set the ID of this ${APP_NAME} node.

	Or set AUTO_CREATE_CONFIG=1 to auto-create empty config files.
"
			fi
		fi
	done
 }

DownloadAssets()
 {
	APP_NAME_LOWER=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]')

	# Read real bundle identifier from the app's Info.plist (matches macos.rs get_bundle_id())
	BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null)
	if [ -z "$BUNDLE_ID" ]; then
		Msg "Warning: Cannot read CFBundleIdentifier from $APP/Contents/Info.plist — using com.carriez.${APP_NAME_LOWER} as fallback"
		BUNDLE_ID="com.carriez.${APP_NAME_LOWER}"
	fi

	Msg 'Loading assets from github'
	# Download plist templates and apply replacements to match correct_app_name() in macos.rs:
	#   1. Replace AssociatedBundleIdentifiers (com.carriez.rustdesk → real bundle ID)
	#   2. Replace lowercase "rustdesk" → lowercase app name (for log paths etc.)
	#   3. Replace "RustDesk" → APP_NAME (for labels, executable name, app path)
	AGENT=$(curl -sf 'https://raw.githubusercontent.com/rustdesk/rustdesk/master/src/platform/privileges_scripts/agent.plist' \
		| sed -e "s|com.carriez.rustdesk|${BUNDLE_ID}|g" \
		      -e "s|rustdesk|${APP_NAME_LOWER}|g" \
		      -e "s|RustDesk|${APP_NAME}|g" \
		      -e "s|/Applications/${APP_NAME}.app|$APP|g")
	DAEMON=$(curl -sf 'https://raw.githubusercontent.com/rustdesk/rustdesk/master/src/platform/privileges_scripts/daemon.plist' \
		| sed -e "s|com.carriez.rustdesk|${BUNDLE_ID}|g" \
		      -e "s|rustdesk|${APP_NAME_LOWER}|g" \
		      -e "s|RustDesk|${APP_NAME}|g" \
		      -e "s|/Applications/${APP_NAME}.app|$APP|g")
	# Apply same correct_app_name() replacements to install.scpt (matches macos.rs:200)
	ASCPT=$(curl -sf 'https://raw.githubusercontent.com/rustdesk/rustdesk/master/src/platform/privileges_scripts/install.scpt' \
		| sed -e "s|com.carriez.rustdesk|${BUNDLE_ID}|g" \
		      -e "s|rustdesk|${APP_NAME_LOWER}|g" \
		      -e "s|RustDesk|${APP_NAME}|g")
	[ -z "$AGENT" -o -z "$DAEMON" -o -z "$ASCPT" ] && Throw "Error getting one or more assets - url probably changed. (A/D/S sizes: ${#AGENT}/${#DAEMON}/${#ASCPT})"
 }

InstallViaAppleScript()
 {
	Msg "Current User:	$FORUSER"

	# This script is pretty stoopid. It does not get the home directory e.g. by algorithm
	$SUDO osascript -e "$ASCPT" "$DAEMON" "$AGENT" "$FORUSER"
 }

KickstartServerGUI()
 {
	if [ -s "$agent_path" ]; then
		Msg "Kickstart server for $FORUID ($FORUSER)"
		$SUDO launchctl enable "gui/$FORUID/${FULL_NAME}_server" 2>/dev/null
		# kickstart -k = kill existing, -p = print PID
		if ! $SUDO launchctl kickstart -kp "gui/$FORUID/${FULL_NAME}_server" 2>/dev/null; then
			Msg "Kickstart skipped — GUI session for $FORUSER not available (expected in MDM context). Agent will auto-start on user login."
		fi
	else
		Err "Ooops - where is $agent_path"
	fi
 }

InstallViaShell()
 {
	Msg "Install agent:	$agent_path"
	echo "$AGENT" | $SUDO tee "$agent_path" >/dev/null

	Msg "Install daemon:	$daemon_path"
	echo "$DAEMON" | $SUDO tee "$daemon_path" >/dev/null

	# Should already be - but incase they were created by user error
	$SUDO chown 0:0 "$agent_path" "$daemon_path"

	# Clear stale stop-service flag from previous uninstall (prevents service from
	# ignoring rendezvous connections even though launchd started it successfully).
	# The flag is written by RustDesk's uninstall_service() into {APP_NAME}2.toml
	# (Config2 options store). Controlled by CLEAR_STOP_SERVICE option.
	if [ "$CLEAR_STOP_SERVICE" -eq 1 ]; then
		local opts_toml="${APP_NAME}2.toml"
		for _cfg in "$user_pref_path/$opts_toml" "$root_pref_path/$opts_toml"; do
			if [ -f "$_cfg" ] && $SUDO grep -qE '^[[:space:]]*"?stop-service"?[[:space:]]*=' "$_cfg" 2>/dev/null; then
				Msg "Clearing stale stop-service flag in $_cfg"
				$SUDO sed -i'.bak' '/^[[:space:]]*"*stop-service"*[[:space:]]*=/d' "$_cfg"
				$SUDO rm -f "$_cfg.bak"
			fi
		done
	fi

	local i
	$SUDO mkdir -p "$root_pref_path"
	for i in $pref_files; do
		$SUDO cp -a "$user_pref_path/$i" "$root_pref_path"
	done

	# Use modern launchctl API (bootstrap/bootout) instead of deprecated load/remove
	# Daemon = system-wide (system domain), Agent = per-user (gui/<uid> domain)

	Msg "Unload / Reload Daemon (system domain)"
	# Ensure clean state: disable + bootout (handles cases where service is stuck)
	$SUDO launchctl disable "system/${FULL_NAME}_service" 2>/dev/null
	$SUDO launchctl bootout "system/${FULL_NAME}_service" 2>/dev/null
	$SUDO launchctl bootout system "$daemon_path" 2>/dev/null
	# Also try legacy unload in case bootstrap API state is inconsistent
	$SUDO launchctl unload -w "$daemon_path" 2>/dev/null
	sleep 1
	if ! $SUDO launchctl bootstrap system "$daemon_path" 2>/dev/null; then
		Msg "bootstrap failed — falling back to launchctl load -w"
		if ! $SUDO launchctl load -w "$daemon_path"; then
			Err "Daemon load also failed. Checking /tmp/${APP_NAME_LOWER}_service.err for details."
			$SUDO cat "/tmp/${APP_NAME_LOWER}_service.err" 2>/dev/null
			Throw "Failed to load daemon ${FULL_NAME}_service"
		fi
	fi
	$SUDO launchctl enable "system/${FULL_NAME}_service" 2>/dev/null

	Msg "Unload / Reload Agent for $FORUSER (gui/$FORUID domain)"
	# Agent must be loaded into the user's GUI domain, not the system domain.
	# In MDM postinstall context, the GUI domain may not exist yet (user not logged in).
	# In that case, bootstrap will fail — this is expected. launchd will automatically
	# load the agent from /Library/LaunchAgents/ when the user logs in.
	$SUDO launchctl bootout "gui/$FORUID/${FULL_NAME}_server" >/dev/null 2>&1
	if $SUDO launchctl bootstrap "gui/$FORUID" "$agent_path" 2>/dev/null; then
		$SUDO launchctl enable "gui/$FORUID/${FULL_NAME}_server"
	else
		Msg "Agent bootstrap skipped — GUI session for $FORUSER not available (expected in MDM context). Agent will auto-load on user login."
	fi
 }

FindApp()
 {
	# First check DEFAULTPATH directly (supports custom paths outside /Applications)
	if [ -d "$DEFAULTPATH" ]; then
		APP="$DEFAULTPATH"
		Msg "Found app at DEFAULTPATH:	$APP"
		return
	fi
	# Fall back: scan /Applications up to two levels deep
	local d
	APP=''
	for d in /Applications /Applications/* /Applications/*/*; do if [ -d "$d" ]; then
		[ -d "$d/${APP_NAME}.app" ] && { APP="$d/${APP_NAME}.app"; Msg "Found app:	$APP"; break; }
	fi; done
 }

IsServiceLoaded()
 {
	local p
	p=$($SUDO launchctl list 2>/dev/null | while read pid sta com; do
			[ "$com" = "$1" ] && { echo "$pid:$sta"; break; }
		done)
	[ -n "$p" ]
 }

Help()
 {
	Throw "

Usage: ${0##*/} [options]

	-a	Show Agent plist contents
	-d	Show Daemon plist contents
	-h	This help
	-i id	Set ${APP_NAME} ID (does not install service)
	-p pwd	Set ${APP_NAME} permanent password (does not install service)
	-s	Show Script contents
	-S	Use AppleScript to install - not recommended
	-u user	Specify target user (for MDM/headless context)
	-v	List the Agent/Daemon plists installed
"
 }


# Begin Script Body
Msg "##################################################################"
Msg "# $(date) | Starting ${0##*/}"
Msg "#*								*#"
Msg	"#**      If prompted for a password - that is proably sudo     **#"
Msg "##################################################################"

# === Phase 1: Parse all options ===
while getopts 'adhi:p:sSvu:' o; do case "$o" in
	'a'|'d'|'s')	VIEW_ONLY=1				;;
	'h')	Help							;;
	'i')	USE_ID="$OPTARG"				;;
	'p')	USE_PWD="$OPTARG"				;;
	'u')	FORUSER_OVERRIDE="$OPTARG"	;;
	'v')	ls -l "$agent_path" "$daemon_path" 2>/dev/null; Throw 'Done.'	;;
	'S')	USESCRIPT=1						;;
	*)		;;
esac; done
OPTIND=1  # Reset for second pass

# === Phase 1.5: Handle -i/-p (set ID/password only, no service install) ===
if [ -n "$USE_ID" ] || [ -n "$USE_PWD" ]; then
	FindApp
	while [ ! -d "$APP" ]; do
		Msg "Could not find ${APP_NAME}.app installed in /Applications/... - sleeping 30"
		sleep 30
		FindApp
	done
	local_bin="${APP}/Contents/MacOS/${APP_NAME}"
	if [ -n "$USE_ID" ]; then
		Msg "Setting ID to: $USE_ID"
		$SUDO "$local_bin" --set-id "$USE_ID"
	fi
	if [ -n "$USE_PWD" ]; then
		Msg "Setting permanent password"
		$SUDO "$local_bin" --password "$USE_PWD"
	fi
	Throw "Done." 0
fi

# === Phase 2: Find app + download assets (needed by -a/-d/-s view options) ===
FindApp

# Wait for app to be installed (e.g. MDM deployment in progress)
# For view-only options (-a/-d/-s), don't loop — fail fast
while [ ! -d "$APP" ]; do
	if [ "$VIEW_ONLY" -eq 1 ]; then
		Throw "Cannot find ${APP_NAME}.app in /Applications — required to generate plist/script content"
	fi
	Msg "Could not find ${APP_NAME}.app installed in /Applications/... - sleeping 30"
    sleep 30
    FindApp
done

Msg "##################################################################"
# DownloadAssets requires $APP to be set (reads Info.plist, substitutes app path in plists)
DownloadAssets

# === Phase 3: Handle view options that only need downloaded assets (-a/-d/-s) ===
# Also collect install option (-S) for later use
while getopts 'adhsSvu:' o; do case "$o" in
	'a')	echo "$AGENT"; Throw 'Done.'	;;
	'd')	echo "$DAEMON"; Throw 'Done.'	;;
	'h')	Help							;;
	's')	echo "$ASCPT"; Throw 'Done.'	;;
	'S')	USESCRIPT=1						;;
	'u')	;;  # Already handled in phase 1
	'v')	;;  # Already handled in phase 1
esac; done; shift $(($OPTIND - 1))

# === Phase 4: Resolve target user (only needed for actual installation) ===

# Apply user override if specified via -u
if [ -n "$FORUSER_OVERRIDE" ]; then
	FORUSER="$FORUSER_OVERRIDE"
fi

# Validate FORUSER
if [ -z "$FORUSER" ] || [ "$FORUSER" = "root" ]; then
	Throw "Cannot determine target user. In MDM context, use -u <username> to specify the target user."
fi

FORUID=$(id -u "$FORUSER" 2>/dev/null) || Throw "User '$FORUSER' not found on this system"

# Resolve user's home directory for preference path
# Always use dscl when FORUSER differs from current user (covers both root and non-root with -u)
if [ "$FORUSER" != "$(id -un)" ]; then
	user_home=$(dscl . -read "/Users/$FORUSER" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory:[[:space:]]*//')
	[ -z "$user_home" ] && Throw "Cannot resolve home directory for user $FORUSER"
else
	user_home="$HOME"
fi
user_pref_path="${user_home}/Library/Preferences/$FULL_NAME"

# === Phase 5: Install ===

IsServiceLoaded "${FULL_NAME}_service" && \
	Throw  "${FULL_NAME}_service is already loaded"

# EnsureConfig creates preference dirs/files only when actually installing (no side effects for view options)
EnsureConfig

Msg "******* STARTING SERVICE INSTALLATION *******"
[ $USESCRIPT -eq 1 ] && InstallViaAppleScript || InstallViaShell
KickstartServerGUI

Msg "Done. Note - if you move the app, you will have to reinstall or edit the LaunchDaemon and LaunchAgent plists"
ls -l "$agent_path" "$daemon_path"
