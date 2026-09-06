#!/bin/sh

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

BINPATH="/usr/bin/AdGuardHome"
CONTROL_INIT="/etc/init.d/adguardhome"

UPDATE_DIR="/tmp/AdGuardHome_Update"
UPDATE_LOG="/tmp/AdGuardHome_update.log"

UPDATE_STATE="/var/run/update_core"
UPDATE_DONE="/var/run/update_core_done"
UPDATE_ERROR="/var/run/update_core_error"
UPDATE_PID="/var/run/AdGuardHome_update.pid"

DEFAULT_UPDATE_URL="https://static.adtidy.org/adguardhome/release/AdGuardHome_linux_\${Arch}.tar.gz"

# ---------------------------------------------------------------------------
# First invocation: detach into background.
# Keep the existing external interface used by LuCI.
# ---------------------------------------------------------------------------

if [ "$1" != "bg_run" ]; then
	rm -f \
		"$UPDATE_STATE" \
		"$UPDATE_DONE" \
		"$UPDATE_ERROR" \
		"$UPDATE_PID" \
		"$UPDATE_LOG"

	touch "$UPDATE_STATE"

	/usr/share/AdGuardHome/update_core.sh \
		bg_run "$1" </dev/null >"$UPDATE_LOG" 2>&1 &

	exit 0
fi

shift

UPDATE_MODE="$1"

# ---------------------------------------------------------------------------
# Exit / cleanup
# ---------------------------------------------------------------------------

EXIT() {
	local rc="$1"

	rm -rf "$UPDATE_DIR" 2>/dev/null
	rm -f "$UPDATE_PID" "$UPDATE_STATE" 2>/dev/null

	if [ "$rc" != "0" ]; then
		touch "$UPDATE_ERROR"
	fi

	exit "$rc"
}

trap 'EXIT 1' INT TERM HUP

# ---------------------------------------------------------------------------
# Basic helpers
# ---------------------------------------------------------------------------

log() {
	echo "$*"
}


sha256_file() {
	sha256sum "$1" 2>/dev/null | awk '{print $1}'
}


get_file_size() {
	ls -ln "$1" 2>/dev/null | awk '{print $5}'
}

# ---------------------------------------------------------------------------
# Check for existing update task
# ---------------------------------------------------------------------------

Check_Task() {
	local pid
	local i

	if [ -f "$UPDATE_PID" ]; then
		pid="$(cat "$UPDATE_PID" 2>/dev/null)"

		if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
			case "$1" in
				force)
					log "Force update requested"
					log "Stopping update task PID ${pid} ..."

					kill "$pid" 2>/dev/null || true

					for i in 1 2 3 4 5; do
						kill -0 "$pid" 2>/dev/null || break
						sleep 1
					done

					if kill -0 "$pid" 2>/dev/null; then
						log "Update task did not stop, killing it ..."
						kill -9 "$pid" 2>/dev/null || true
					fi
					;;

				*)
					echo \
						"An update task is already running (PID ${pid}). Please wait or use Force update." \
						>&2
					EXIT 2
					;;
			esac
		else
			rm -f "$UPDATE_PID"
		fi
	fi

	echo "$$" > "$UPDATE_PID"
}

# ---------------------------------------------------------------------------
# Downloader
# ---------------------------------------------------------------------------

Check_Downloader() {
	if command -v curl >/dev/null 2>&1; then
		PKG="curl"
		return 0
	fi

	if command -v wget >/dev/null 2>&1; then
		PKG="wget"
		return 0
	fi

	echo "Neither curl nor wget is installed, cannot check updates!" >&2
	EXIT 1
}


download_file() {
	local url="$1"
	local output="$2"

	case "$PKG" in
		curl)
			curl -fL \
				--connect-timeout 10 \
				--max-time 300 \
				-o "$output" \
				"$url"
			;;

		wget)
			wget \
				-T 10 \
				--timeout=10 \
				--tries=2 \
				-O "$output" \
				"$url"
			;;

		*)
			return 1
			;;
	esac
}


fetch_text() {
	local url="$1"

	case "$PKG" in
		curl)
			curl -fsSL \
				--connect-timeout 10 \
				--max-time 30 \
				"$url"
			;;

		wget)
			wget -q \
				-T 10 \
				--timeout=10 \
				-O - \
				"$url"
			;;

		*)
			return 1
			;;
	esac
}

# ---------------------------------------------------------------------------
# Architecture
# ---------------------------------------------------------------------------

GET_Arch() {
	local Archt

	Archt="$(uname -m)"

	case "$Archt" in
		i386|i686)
			Arch="i386"
			;;

		x86_64|amd64)
			Arch="amd64"
			;;

		mipsel|mipsel*)
			Arch="mipsle_softfloat"
			;;

		mips|mips*)
			Arch="mips_softfloat"
			;;

		mips64el)
			Arch="mips64le_softfloat"
			;;

		mips64)
			Arch="mips64_softfloat"
			;;

		armv5*|armv5l|armv5tel)
			Arch="armv5"
			;;

		armv6*|armv6l)
			Arch="armv6"
			;;

		armv7*|armv7l)
			Arch="armv7"
			;;

		arm|armhf)
			Arch="armv7"
			;;

		aarch64)
			Arch="arm64"
			;;

		*)
			echo "Unsupported architecture: [$Archt]" >&2
			EXIT 1
			;;
	esac

	log "Detected architecture: $Arch"
}

# ---------------------------------------------------------------------------
# Release version
# ---------------------------------------------------------------------------

Get_Latest_Version() {
	local api_url
	local api_data

	api_url="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest"

	log "Checking latest stable release ..."

	api_data="$(fetch_text "$api_url" 2>/dev/null)" || {
		echo "Failed to query GitHub release API." >&2
		EXIT 1
	}

	Cloud_Version="$(
		echo "$api_data" |
			awk -F'"' '
				/"tag_name"[[:space:]]*:/ {
					print $4
					exit
				}
			'
	)"

	[ -n "$Cloud_Version" ] || {
		echo "Failed to determine latest stable version." >&2
		EXIT 1
	}
}


Get_Beta_Version() {
	local api_url
	local api_data

	api_url="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases?per_page=30"

	log "Checking beta releases ..."

	api_data="$(fetch_text "$api_url" 2>/dev/null)" || {
		echo "Failed to query GitHub release API." >&2
		EXIT 1
	}

	Cloud_Version="$(
		echo "$api_data" |
			awk -F'"' '
				/tag_name"[[:space:]]*:/ {
					tag=$4
				}
				/prerelease"[[:space:]]*:[[:space:]]*true/ {
					if (tag != "") {
						print tag
						exit
					}
				}
			'
	)"

	[ -n "$Cloud_Version" ] || {
		echo "Failed to determine latest beta version." >&2
		EXIT 1
	}
}


Get_Current_Version() {
	if [ -x "$BINPATH" ]; then
		Current_Version="$(
			"$BINPATH" --version 2>/dev/null |
				sed -n \
					's/.*version[[:space:]]\+\(v[0-9][^,[:space:]]*\).*/\1/p' |
				head -n 1
		)"
	else
		Current_Version="unknown"
	fi

	[ -n "$Current_Version" ] || Current_Version="unknown"
}

# ---------------------------------------------------------------------------
# Release asset digest
# ---------------------------------------------------------------------------

Get_Asset_Digest() {
	local tag="$1"
	local asset_name="$2"
	local api_url
	local api_data

	api_url="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/tags/${tag}"

	log "Getting SHA-256 digest for ${asset_name} ..."

	api_data="$(fetch_text "$api_url" 2>/dev/null)" || {
		echo "Failed to query release asset metadata." >&2
		return 1
	}

	EXPECTED_SHA256="$(
		echo "$api_data" |
			awk -v asset="$asset_name" '
				{
					if (index($0, "\"name\": \"" asset "\"") > 0) {
						found=1
						next
					}

					if (found && index($0, "\"digest\": \"sha256:") > 0) {
						line=$0
						sub(/^.*"digest": "sha256:/, "", line)
						sub(/".*$/, "", line)
						print line
						exit
					}

					if (found && index($0, "\"name\": \"") > 0) {
						found=0
					}
				}
			'
	)"

	[ -n "$EXPECTED_SHA256" ] || {
		echo "SHA-256 digest for ${asset_name} was not found." >&2
		return 1
	}

	return 0
}


Verify_Digest() {
	local file="$1"
	local expected="$2"
	local actual

	actual="$(sha256_file "$file")" || {
		echo "sha256sum is not available." >&2
		return 1
	}

	log "SHA-256: $actual"

	if [ "$actual" != "$expected" ]; then
		echo "SHA-256 verification failed!" >&2
		echo "Expected: $expected" >&2
		echo "Actual:   $actual" >&2
		return 1
	fi

	log "SHA-256 verification passed."
	return 0
}

# ---------------------------------------------------------------------------
# Expand configured update URL without eval.
# Preserve both existing LuCI download sources.
# ---------------------------------------------------------------------------

Build_Update_Link() {
	local template="$1"
	local link

	link="$template"

	[ -n "$link" ] || link="$DEFAULT_UPDATE_URL"

	link="${link//\$\{Arch\}/$Arch}"
	link="${link//\$\{Cloud_Version\}/$Cloud_Version}"

	UPDATE_LINK="$link"
}


Validate_Update_Link() {
	case "$UPDATE_LINK" in
		https://static.adtidy.org/adguardhome/release/AdGuardHome_linux_*.tar.gz)
			;;

		https://github.com/AdguardTeam/AdGuardHome/releases/download/*/AdGuardHome_linux_*.tar.gz)
			;;

		*)
			echo \
				"Unsupported update URL. Please use the official AdGuard Home mirror or GitHub Releases." \
				>&2
			return 1
			;;
	esac

	return 0
}

# ---------------------------------------------------------------------------
# Check current release
# ---------------------------------------------------------------------------

Check_Updates() {
	local asset_name
	local template

	Check_Downloader
	GET_Arch

	case "$core_version" in
		beta)
			Get_Beta_Version
			;;

		*)
			Get_Latest_Version
			;;
	esac

	Get_Current_Version

	log "Binary path: ${BINPATH%/*}"
	log "Current version: $Current_Version"
	log "Latest version: $Cloud_Version"

	template="$update_url"
	Build_Update_Link "$template"

	Validate_Update_Link || EXIT 1

	asset_name="AdGuardHome_linux_${Arch}.tar.gz"

	Get_Asset_Digest "$Cloud_Version" "$asset_name" || EXIT 1

	if [ "$Cloud_Version" != "$Current_Version" ] ||
		[ "$UPDATE_MODE" = "force" ]; then

		Update_Core "$asset_name" || EXIT 1
	else
		log "Already up to date."
		EXIT 0
	fi

	EXIT 0
}


# ---------------------------------------------------------------------------
# Validate downloaded archive contents
# ---------------------------------------------------------------------------

Validate_Tar_Archive() {
	local archive="$1"
	local list_file="$UPDATE_DIR/archive.list"
	local entry

	log "Checking archive structure ..."

	if ! tar -tzf "$archive" > "$list_file" 2>/dev/null; then
		echo "Archive integrity check failed." >&2
		return 1
	fi

	while IFS= read -r entry; do
		case "$entry" in
			/*|../*|*/../*)
				echo "Unsafe archive path detected: $entry" >&2
				return 1
				;;
		esac
	done < "$list_file"

	return 0
}


# ---------------------------------------------------------------------------
# Extract and locate binary
# ---------------------------------------------------------------------------

Prepare_Binary() {
	local archive="$1"

	if [ "${archive##*.}" = "gz" ]; then
		log "Extracting AdGuardHome ..."

		Validate_Tar_Archive "$archive" || return 1

		if ! tar -zxf "$archive" -C "$UPDATE_DIR"; then
			echo "Extraction failed!" >&2
			return 1
		fi

		if [ ! -f "$UPDATE_DIR/AdGuardHome/AdGuardHome" ]; then
			echo "Extraction failed: AdGuardHome binary not found!" >&2
			return 1
		fi

		DOWNLOAD_BIN="$UPDATE_DIR/AdGuardHome/AdGuardHome"
	else
		DOWNLOAD_BIN="$archive"
	fi

	[ -f "$DOWNLOAD_BIN" ] || {
		echo "Downloaded binary not found." >&2
		return 1
	}

	chmod 0755 "$DOWNLOAD_BIN" 2>/dev/null || return 1

	return 0
}


Validate_Binary() {
	local version

	log "Validating downloaded AdGuardHome binary ..."

	version="$(
		"$DOWNLOAD_BIN" --version 2>/dev/null |
			sed -n \
				's/.*version[[:space:]]\+\(v[0-9][^,[:space:]]*\).*/\1/p' |
			head -n 1
	)"

	[ -n "$version" ] || {
		echo "Downloaded binary failed --version validation." >&2
		return 1
	}

	log "Downloaded binary version: $version"

	return 0
}

# ---------------------------------------------------------------------------
# Stop service safely
# ---------------------------------------------------------------------------

Stop_Service() {
	local i

	log "Stopping AdGuardHome service ..."

	if ! "$CONTROL_INIT" stop >/dev/null 2>&1; then
		echo "Failed to stop AdGuardHome service." >&2
		return 1
	fi

	for i in 1 2 3 4 5 6 7 8 9 10; do
		if ! pidof AdGuardHome >/dev/null 2>&1; then
			return 0
		fi

		sleep 1
	done

	echo "AdGuardHome process did not stop." >&2
	return 1
}

# ---------------------------------------------------------------------------
# Install binary atomically
# ---------------------------------------------------------------------------

Install_Binary() {
	local stage
	local backup
	local old_mode

	stage="/usr/bin/.AdGuardHome.new.$$"
	backup="$UPDATE_DIR/AdGuardHome.old"

	old_mode="$(stat -c '%a' "$BINPATH" 2>/dev/null)"
	[ -n "$old_mode" ] || old_mode="755"

	log "Preparing atomic binary replacement ..."

	rm -f "$stage"

	if [ -f "$BINPATH" ]; then
		log "Backing up current binary ..."

		if ! cp -p "$BINPATH" "$backup"; then
			echo "Failed to back up current AdGuardHome binary." >&2
			rm -f "$stage"
			return 1
		fi
	fi

	if ! cp "$DOWNLOAD_BIN" "$stage"; then
		echo "Failed to stage new AdGuardHome binary." >&2
		rm -f "$stage"
		return 1
	fi

	chmod "$old_mode" "$stage" 2>/dev/null ||
		chmod 0755 "$stage"

	log "Validating staged binary ..."

	if ! "$stage" --version >/dev/null 2>&1; then
		echo "Staged binary validation failed." >&2
		rm -f "$stage"
		return 1
	fi

	if ! mv -f "$stage" "$BINPATH"; then
		echo "Atomic binary replacement failed." >&2
		rm -f "$stage"
		return 1
	fi

	chmod +x "$BINPATH"

	return 0
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------

Rollback_Binary() {
	local backup="$1"

	[ -f "$backup" ] || {
		echo "No previous binary is available for rollback." >&2
		return 1
	}

	log "Rolling back previous AdGuardHome binary ..."

	if ! cp -p "$backup" "$BINPATH"; then
		echo "Rollback failed." >&2
		return 1
	fi

	chmod +x "$BINPATH"

	return 0
}

# ---------------------------------------------------------------------------
# Restart and verify
# ---------------------------------------------------------------------------

Start_And_Verify() {
	local i

	log "Starting AdGuardHome service ..."

	if ! "$CONTROL_INIT" start >/dev/null 2>&1; then
		echo "Failed to start AdGuardHome service." >&2
		return 1
	fi

	for i in 1 2 3 4 5 6 7 8 9 10; do
		if pidof AdGuardHome >/dev/null 2>&1; then
			log "AdGuardHome process is running."

			if "$BINPATH" --version >/dev/null 2>&1; then
				return 0
			fi
		fi

		sleep 1
	done

	echo "AdGuardHome failed to become ready." >&2
	return 1
}

# ---------------------------------------------------------------------------
# Core update
# ---------------------------------------------------------------------------

Update_Core() {
	local asset_name="$1"
	local archive
	local filename
	local backup

	rm -rf "$UPDATE_DIR"

	mkdir -p "$UPDATE_DIR" || {
		echo "Unable to create temporary update directory." >&2
		return 1
	}

	archive="$UPDATE_DIR/$asset_name"
	filename="$asset_name"

	log "Download link: $UPDATE_LINK"
	log "File name: $filename"
	log "Downloading AdGuardHome core ..."

	if ! download_file "$UPDATE_LINK" "$archive"; then
		echo "Download failed." >&2
		return 1
	fi

	[ -s "$archive" ] || {
		echo "Downloaded file is empty." >&2
		return 1
	}

	log "Downloaded size: $(get_file_size "$archive") bytes"

	Verify_Digest "$archive" "$EXPECTED_SHA256" || return 1

	Prepare_Binary "$archive" || return 1

	Validate_Binary || return 1

	backup="$UPDATE_DIR/AdGuardHome.old"

	Stop_Service || return 1

	Install_Binary || {
		"$CONTROL_INIT" start >/dev/null 2>&1 || true
		return 1
	}

	if ! Start_And_Verify; then
		echo \
			"New AdGuardHome binary failed to start. Starting rollback ..." \
			>&2

		"$CONTROL_INIT" stop >/dev/null 2>&1 || true

		if Rollback_Binary "$backup"; then
			if Start_And_Verify; then
				echo "Rollback completed successfully." >&2
			else
				echo \
					"Rollback completed, but AdGuardHome still failed to start." \
					>&2
			fi
		else
			echo "CRITICAL: AdGuardHome rollback failed." >&2
		fi

		return 1
	fi

	rm -f "$backup"

	log "AdGuardHome core updated successfully."
	touch "$UPDATE_DONE"

	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	Check_Task "$UPDATE_MODE"

	rm -f "$UPDATE_DONE" "$UPDATE_ERROR" 2>/dev/null
	touch "$UPDATE_STATE"

	core_version="$(uci -q get adguardhome.config.core_version)"
	update_url="$(uci -q get adguardhome.config.update_url)"

	Check_Updates
}

main
