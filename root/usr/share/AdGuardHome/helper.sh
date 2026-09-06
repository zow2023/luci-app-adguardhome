#!/bin/sh
# Auxiliary functions for reading and writing simple two-level YAML values.
#
# Supported format:
#   section:
#     key: value
#
# This helper is intentionally limited to the simple scalar YAML values
# used by AdGuard Home. It is not a general-purpose YAML parser.

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

    # -----------------------------------------------------------------------
    # Read mode
    # -----------------------------------------------------------------------

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

                # Ignore blank lines and comments.
                if (line ~ /^[[:space:]]*$/ ||
                    line ~ /^[[:space:]]*#/) {
                    next
                }

                # Top-level section.
                if (line !~ /^[[:space:]]/) {
                    current_section = line
                    sub(/:.*/, "", current_section)
                    current_section = trim(current_section)

                    in_section = (current_section == section)
                    next
                }

                if (!in_section || key == "")
                    next

                # Match the requested key inside the section.
                current_key = line
                sub(/^[[:space:]]*/, "", current_key)
                sub(/:.*/, "", current_key)
                current_key = trim(current_key)

                if (current_key == key) {
                    result = line
                    sub(/^[^:]*:[[:space:]]*/, "", result)
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

    # -----------------------------------------------------------------------
    # Write mode
    # -----------------------------------------------------------------------

    [ -n "$key" ] || return 1

    local tmp
    local mode

    tmp="${file}.tmp.$$"
    mode="$(stat -c '%a' "$file" 2>/dev/null)"

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

            # Preserve blank lines and comments.
            if (line ~ /^[[:space:]]*$/ ||
                line ~ /^[[:space:]]*#/) {
                print line
                next
            }

            # Top-level section.
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

            # Get indentation and key.
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

    [ -n "$mode" ] && chmod "$mode" "$tmp"

    mv -f "$tmp" "$file" || {
        rm -f "$tmp"
        return 1
    }

    return 0
}
