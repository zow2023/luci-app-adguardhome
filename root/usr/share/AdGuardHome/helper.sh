#!/bin/sh

config_editor() {
	local yaml="$1"
	local value="$2"
	local file="$3"
	local ro="$4"

	[ -n "$yaml" ] || return 1
	[ -f "$file" ] || return 1

	local section
	local key

	case "$yaml" in
		*.*)
			section="${yaml%%.*}"
			key="${yaml#*.}"
			;;
		*)
			section="$yaml"
			key=""
			;;
	esac

	[ -n "$section" ] || return 1

	if [ "$ro" = "1" ]; then
		awk \
			-v section="$section" \
			-v key="$key" '
			function trim(s) {
				sub(/^[[:space:]]+/, "", s)
				sub(/[[:space:]]+$/, "", s)
				return s
			}
			{
				line = $0
				if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/)
					next
				if (line !~ /^[[:space:]]/) {
					current_section = line
					sub(/:.*/, "", current_section)
					current_section = trim(current_section)
					in_section = (current_section == section)
					next
				}
				if (!in_section || key == "")
					next
				current_key = line
				sub(/^[[:space:]]*/, "", current_key)
				sub(/:.*/, "", current_key)
				current_key = trim(current_key)
				if (current_key == key) {
					result = line
					sub(/^[^:]*:[[:space:]]*/, "", result)
					sub(/[[:space:]]+$/, "", result)
					# Strip surrounding quotes, e.g. port: "53"
					# must read back as 53, otherwise downstream
					# comparisons (use_port53 / mark_redirect_flag)
					# fail and the start aborts.
					if (result ~ /^".*"$/) {
						result = substr(result, 2, length(result) - 2)
					}
					print result
					found = 1
					exit
				}
			}
			END {
				if (!found)
					exit 1
			}
			' "$file"
		return $?
	fi

	[ -n "$key" ] || return 1

	local tmp
	local uid
	local gid

	uid="$(ls -ln "$file" 2>/dev/null | awk '{print $3}')"
	gid="$(ls -ln "$file" 2>/dev/null | awk '{print $4}')"

	[ -n "$uid" ] || return 1
	[ -n "$gid" ] || return 1

	tmp="${file}.tmp.$$"

	awk \
		-v section="$section" \
		-v key="$key" \
		-v new_value="$value" '
		function trim(s) {
			sub(/^[[:space:]]+/, "", s)
			sub(/[[:space:]]+$/, "", s)
			return s
		}
		{
			line = $0

			if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) {
				print line
				next
			}

			if (line !~ /^[[:space:]]/) {
				current_section = line
				sub(/:.*/, "", current_section)
				current_section = trim(current_section)
				in_section = (current_section == section)
				print line
				next
			}

			if (!in_section) {
				print line
				next
			}

			indent = line
			sub(/[^ ].*/, "", indent)

			current_key = line
			sub(/^[[:space:]]*/, "", current_key)
			sub(/:.*/, "", current_key)
			current_key = trim(current_key)

			if (current_key == key) {
				print indent key ": " new_value
				found = 1
				next
			}

			print line
		}
		END {
			if (!found)
				exit 1
		}
		' "$file" > "$tmp"

	if [ $? -ne 0 ]; then
		rm -f "$tmp"
		return 1
	fi

	chmod 600 "$tmp" || {
		rm -f "$tmp"
		return 1
	}

	chown "$uid:$gid" "$tmp" || {
		rm -f "$tmp"
		return 1
	}

	mv -f "$tmp" "$file" || {
		rm -f "$tmp"
		return 1
	}

	return 0
}
