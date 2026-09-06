#!/bin/sh
# Auxiliary functions for reading and writing simple YAML scalar values.
#
# Supported path format:
#   section.key
#
# This helper is intentionally limited to the simple scalar YAML structure
# used by AdGuard Home. It is not intended to be a general YAML parser.

config_editor() {
    local yaml="$1"
    local value="$2"
    local file="$3"
    local ro="$4"

    [ -n "$yaml" ] || return 1
    [ -f "$file" ] || return 1

    # Read-only mode.
    if [ "$ro" = "1" ]; then
        awk -v yaml="$yaml" '
            BEGIN {
                split(yaml, path, ".")
                depth = length(path)

                parent_found = (depth == 1)
                parent_indent = -1
            }

            {
                line = $0

                # Ignore empty lines and comments.
                if (line ~ /^[[:space:]]*$/ ||
                    line ~ /^[[:space:]]*#/) {
                    next
                }

                # Count leading spaces.
                indent = length(line) - length(substr(line, match(line, /[^ ]/)))

                key = line
                sub(/^[[:space:]]*/, "", key)
                sub(/:.*/, "", key)

                # Top-level key.
                if (indent == 0) {
                    if (depth == 1 && key == path[1]) {
                        value = line
                        sub(/^[^:]*:[[:space:]]*/, "", value)
                        print value
                        found = 1
                        exit
                    }

                    if (depth > 1 && key == path[1]) {
                        parent_found = 1
                        parent_indent = indent
                        next
                    }

                    parent_found = 0
                    next
                }

                # Nested key.
                if (depth > 1 &&
                    parent_found &&
                    indent > parent_indent &&
                    key == path[depth]) {

                    value = line
                    sub(/^[^:]*:[[:space:]]*/, "", value)

                    print value
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

    # Write mode.
    local tmp
    local mode

    tmp="${file}.tmp.$$"
    mode="$(stat -c '%a' "$file" 2>/dev/null)"

    VALUE="$value" awk -v yaml="$yaml" '
        BEGIN {
            split(yaml, path, ".")
            depth = length(path)

            parent_found = (depth == 1)
            parent_indent = -1
            found = 0
        }

        {
            line = $0

            # Preserve empty lines and comments.
            if (line ~ /^[[:space:]]*$/ ||
                line ~ /^[[:space:]]*#/) {
                print line
                next
            }

            # Count leading spaces.
            indent = length(line) - length(substr(line, match(line, /[^ ]/)))

            key = line
            sub(/^[[:space:]]*/, "", key)
            sub(/:.*/, "", key)

            # Top-level key.
            if (indent == 0) {
                if (depth == 1 && key == path[1]) {
                    prefix = line
                    sub(/[^:]*:.*/, "", prefix)

                    print prefix key ": " ENVIRON["VALUE"]
                    found = 1
                    next
                }

                if (depth > 1 && key == path[1]) {
                    parent_found = 1
                    parent_indent = indent
                } else {
                    parent_found = 0
                }

                print line
                next
            }

            # Nested key.
            if (depth > 1 &&
                parent_found &&
                indent > parent_indent &&
                key == path[depth]) {

                prefix = line
                sub(/[^:]*:.*/, "", prefix)

                print prefix key ": " ENVIRON["VALUE"]
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
