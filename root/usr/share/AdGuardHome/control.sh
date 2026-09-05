#!/bin/sh
# /usr/share/AdGuardHome/control.sh
. /usr/share/AdGuardHome/helper.sh

ENABLED="$1"

NFT_RULES_TPL="/usr/share/AdGuardHome/adguardhome.nft.tpl"
NFT_RULES_FILE="/var/etc/adguardhome.nft"
NFT_TABLE="adguardhome"

# Volatile runtime state.
# Describes the last redirect mode applied by this script.
RUNTIME_STATE_FILE="/var/run/adguardhome.state"

# Persistent backup of the user's original dnsmasq configuration.
# This file is intentionally stored under /var/lib/adguardhome rather than
# /var/run so the original configuration can survive a reboot.
DNSMASQ_STATE_DIR="/var/lib/adguardhome"
DNSMASQ_STATE_FILE="${DNSMASQ_STATE_DIR}/dnsmasq.state"


# ---------------------------------------------------------------------------
# nftables redirect
# ---------------------------------------------------------------------------

set_nft_redirect() {
    local port="$1"
    local wan_section_name
    local wan_ifs=""
    local wan_nft_set=""
    local ifname

    [ -n "$port" ] || return 1
    [ -f "$NFT_RULES_TPL" ] || return 1

    # Get network interfaces assigned to wan zone
    wan_ifs="$(uci -q get firewall.wan.network 2>/dev/null)"
    if [ -z "$wan_ifs" ]; then
        wan_section_name="$(
            uci show firewall 2>/dev/null |
                awk -F'.' '/\.name='\''wan'\''$/ {print $2}' | head -n 1
        )"
        [ -n "$wan_section_name" ] && wan_ifs="$(uci -q get firewall."$wan_section_name".network 2>/dev/null)"
    fi

    for ifname in $wan_ifs; do
        [ -n "$wan_nft_set" ] && wan_nft_set="${wan_nft_set}, "
        wan_nft_set="${wan_nft_set}\"${ifname}\""
    done

    sed \
        -e "s/__WAN_EXCLUDES__/${wan_nft_set}/g" \
        -e "s/__AGH_PORT__/${port}/g" \
        "$NFT_RULES_TPL" > "$NFT_RULES_FILE" || return 1

    nft delete table inet "$NFT_TABLE" 2>/dev/null
    # Explicitly load generated nftables rules file
    nft -f "$NFT_RULES_FILE" 2>/dev/null || true
    fw4 reload >/dev/null 2>&1

    logger -t adguardhome \
        "nft table $NFT_TABLE applied on port $port, WAN excludes: ${wan_nft_set:-none}"
}


clear_nft_redirect() {
    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        [ -f "$NFT_RULES_FILE" ] && > "$NFT_RULES_FILE"

        nft delete table inet "$NFT_TABLE" 2>/dev/null
        fw4 reload >/dev/null 2>&1

        logger -t adguardhome "nft table $NFT_TABLE cleared"
    fi
}


# ---------------------------------------------------------------------------
# Persistent dnsmasq state
# ---------------------------------------------------------------------------

dnsmasq_state_save() {
    local configpath="$1"
    local mode="$2"

    local server_values
    local value
    local resolvfile
    local noresolv
    local dnsmasq_port
    local agh_port

    # Existing backup always wins.
    [ -f "$DNSMASQ_STATE_FILE" ] && return 0

    mkdir -p "$DNSMASQ_STATE_DIR" || {
        logger -t adguardhome "failed to create dnsmasq state directory"
        return 1
    }

    chmod 0700 "$DNSMASQ_STATE_DIR"

    {
        printf 'version=1\n'
        printf 'mode=%s\n' "$mode"

        # ---------------------------------------------------------------
        # Original dnsmasq server list
        # ---------------------------------------------------------------

        if uci -q get dhcp.@dnsmasq[0].server >/dev/null 2>&1; then
            printf 'server_exists=1\n'

            server_values="$(
                uci -q get dhcp.@dnsmasq[0].server 2>/dev/null
            )"

            # Use for-loop to correctly handle space and line-separated values
            for value in $server_values; do
                [ -n "$value" ] || continue
                printf 'server_item=%s\n' "$value"
            done
        else
            printf 'server_exists=0\n'
        fi

        # ---------------------------------------------------------------
        # Original resolvfile
        # ---------------------------------------------------------------

        if resolvfile="$(uci -q get dhcp.@dnsmasq[0].resolvfile 2>/dev/null)"; then
            printf 'resolvfile_exists=1\n'
            printf 'resolvfile=%s\n' "$resolvfile"
        else
            printf 'resolvfile_exists=0\n'
        fi

        # ---------------------------------------------------------------
        # Original noresolv
        # ---------------------------------------------------------------

        if noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)"; then
            printf 'noresolv_exists=1\n'
            printf 'noresolv=%s\n' "$noresolv"
        else
            printf 'noresolv_exists=0\n'
        fi

        # ---------------------------------------------------------------
        # Original dnsmasq port
        # ---------------------------------------------------------------

        if dnsmasq_port="$(uci -q get dhcp.@dnsmasq[0].port 2>/dev/null)"; then
            printf 'dnsmasq_port_exists=1\n'
            printf 'dnsmasq_port=%s\n' "$dnsmasq_port"
        else
            printf 'dnsmasq_port_exists=0\n'
        fi

        # ---------------------------------------------------------------
        # Original AdGuard Home DNS port
        # ---------------------------------------------------------------

        agh_port="$(
            config_editor 'dns.port' '' "$configpath" '1'
        )"

        printf 'agh_port=%s\n' "$agh_port"

    } > "${DNSMASQ_STATE_FILE}.tmp" || {
        rm -f "${DNSMASQ_STATE_FILE}.tmp"
        return 1
    }

    chmod 0600 "${DNSMASQ_STATE_FILE}.tmp"

    mv -f "${DNSMASQ_STATE_FILE}.tmp" "$DNSMASQ_STATE_FILE" || {
        rm -f "${DNSMASQ_STATE_FILE}.tmp"
        return 1
    }

    logger -t adguardhome "saved original dnsmasq configuration, mode=$mode"

    return 0
}


dnsmasq_state_mode() {
    [ -f "$DNSMASQ_STATE_FILE" ] || return 1

    sed -n 's/^mode=//p' "$DNSMASQ_STATE_FILE" | head -n 1
}


dnsmasq_state_restore() {
    local configpath="$1"

    local old_mode
    local server_exists
    local resolvfile_exists
    local noresolv_exists
    local dnsmasq_port_exists

    local resolvfile
    local noresolv
    local dnsmasq_port
    local agh_port
    local value

    [ -f "$DNSMASQ_STATE_FILE" ] || return 0

    old_mode="$(
        sed -n 's/^mode=//p' "$DNSMASQ_STATE_FILE" | head -n 1
    )"

    server_exists="$(
        sed -n 's/^server_exists=//p' "$DNSMASQ_STATE_FILE" | head -n 1
    )"

    resolvfile_exists="$(
        sed -n 's/^resolvfile_exists=//p' "$DNSMASQ_STATE_FILE" | head -n 1
    )"

    noresolv_exists="$(
        sed -n 's/^noresolv_exists=//p' "$DNSMASQ_STATE_FILE" | head -n 1
    )"

    dnsmasq_port_exists="$(
        sed -n 's/^dnsmasq_port_exists=//p' "$DNSMASQ_STATE_FILE" | head -n 1
    )"

    agh_port="$(
        sed -n 's/^agh_port=//p' "$DNSMASQ_STATE_FILE" | head -n 1
    )"

    # ---------------------------------------------------------------
    # Restore original server list
    # ---------------------------------------------------------------

    uci -q delete dhcp.@dnsmasq[0].server

    if [ "$server_exists" = "1" ]; then
        sed -n 's/^server_item=//p' "$DNSMASQ_STATE_FILE" |
        while IFS= read -r value; do
            [ -n "$value" ] || continue
            uci add_list dhcp.@dnsmasq[0].server="$value"
        done
    fi

    # ---------------------------------------------------------------
    # Restore resolvfile
    # ---------------------------------------------------------------

    uci -q delete dhcp.@dnsmasq[0].resolvfile

    if [ "$resolvfile_exists" = "1" ]; then
        resolvfile="$(
            sed -n 's/^resolvfile=//p' "$DNSMASQ_STATE_FILE" | head -n 1
        )"
        uci set dhcp.@dnsmasq[0].resolvfile="$resolvfile"
    fi

    # ---------------------------------------------------------------
    # Restore noresolv
    # ---------------------------------------------------------------

    uci -q delete dhcp.@dnsmasq[0].noresolv

    if [ "$noresolv_exists" = "1" ]; then
        noresolv="$(
            sed -n 's/^noresolv=//p' "$DNSMASQ_STATE_FILE" | head -n 1
        )"
        uci set dhcp.@dnsmasq[0].noresolv="$noresolv"
    fi

    # ---------------------------------------------------------------
    # Restore dnsmasq port
    # ---------------------------------------------------------------

    uci -q delete dhcp.@dnsmasq[0].port

    if [ "$dnsmasq_port_exists" = "1" ]; then
        dnsmasq_port="$(
            sed -n 's/^dnsmasq_port=//p' "$DNSMASQ_STATE_FILE" | head -n 1
        )"
        uci set dhcp.@dnsmasq[0].port="$dnsmasq_port"
    fi

    uci commit dhcp

    # ---------------------------------------------------------------
    # Restore AGH DNS port only for exchange mode
    # ---------------------------------------------------------------

    if [ "$old_mode" = "exchange" ] &&
        [ -n "$agh_port" ] &&
        [ -f "$configpath" ]; then

        config_editor 'dns.port' "$agh_port" "$configpath"
    fi

    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    agh_reload

    rm -f "$DNSMASQ_STATE_FILE"

    logger -t adguardhome "restored original dnsmasq configuration"
}


# ---------------------------------------------------------------------------
# dnsmasq takeover
# ---------------------------------------------------------------------------

set_forward_dnsmasq() {
    local port="$1"
    local configpath="$2"
    local addr="127.0.0.1#$port"

    dnsmasq_state_save "$configpath" 'dnsmasq-upstream' || {
        logger -t adguardhome "failed to save original dnsmasq configuration"
        return 1
    }

    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server="$addr"

    uci -q delete dhcp.@dnsmasq[0].resolvfile
    uci set dhcp.@dnsmasq[0].noresolv=1

    uci commit dhcp

    /etc/init.d/dnsmasq restart >/dev/null 2>&1
}


use_port53() {
    local configpath
    local adguardhome_port
    local dnsmasq_port

    configpath="$(uci -q get adguardhome.config.config_file)"
    [ -n "$configpath" ] || configpath='/etc/adguardhome/adguardhome.yaml'

    adguardhome_port="$(config_editor 'dns.port' '' "$configpath" '1')"
    dnsmasq_port="$(uci -q get dhcp.@dnsmasq[0].port)"
    [ -n "$dnsmasq_port" ] || dnsmasq_port='53'

    dnsmasq_state_save "$configpath" 'exchange' || {
        logger -t adguardhome "failed to save original dnsmasq configuration for exchange mode"
        return 1
    }

    if [ "$dnsmasq_port" = "$adguardhome_port" ]; then
        if [ "$adguardhome_port" = '53' ]; then
            adguardhome_port='1745'
        fi
    elif [ "$adguardhome_port" = '53' ]; then
        return 0
    fi

    config_editor 'dns.port' '53' "$configpath"

    uci set dhcp.@dnsmasq[0].port="$adguardhome_port"
    uci commit dhcp

    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    agh_reload
}


# ---------------------------------------------------------------------------
# ubus reload helper
# ---------------------------------------------------------------------------

agh_reload() {
    ubus call service event \
        '{"type":"config.change","data":{"package":"adguardhome"}}' \
        >/dev/null 2>&1
}


# ---------------------------------------------------------------------------
# Redirect state indicator
# ---------------------------------------------------------------------------

mark_redirect_flag() {
    local enabled="$1"
    local redirect="$2"
    local agh_port="$3"

    local configpath
    local flag=0

    configpath="$(uci -q get adguardhome.config.config_file)"
    [ -n "$configpath" ] || configpath='/etc/adguardhome/adguardhome.yaml'
    [ -n "$agh_port" ] || agh_port='5353'

    if [ "$enabled" = '1' ] && [ "$redirect" != 'none' ]; then
        flag=1

        if [ "$redirect" = 'redirect' ]; then
            nft list table inet "$NFT_TABLE" >/dev/null 2>&1 || flag=0

        elif [ "$redirect" = 'dnsmasq-upstream' ]; then
            local server_values
            server_values="$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)"

            echo "$server_values" |
                grep -q -E "(^|[[:space:]])127\\.0\\.0\\.1#${agh_port}([[:space:]]|$)" ||
                flag=0

        elif [ "$redirect" = 'exchange' ]; then
            local cfgp
            local dport

            cfgp="$(config_editor 'dns.port' '' "$configpath" '1')"
            dport="$(uci -q get dhcp.@dnsmasq[0].port 2>/dev/null)"

            if [ "$cfgp" != '53' ] || [ "$dport" = '53' ]; then
                flag=0
            fi
        fi
    fi

    printf '%s' "$flag" > /var/run/AdGredir
}


# ---------------------------------------------------------------------------
# Main controller
# ---------------------------------------------------------------------------

_do_redirect() {
    local enabled="$1"

    local configpath
    local adguardhome_port
    local redirect

    local old_redirect='none'
    local old_port='0'
    local old_enabled='0'

    local saved_mode

    configpath="$(uci -q get adguardhome.config.config_file)"
    [ -n "$configpath" ] || configpath='/etc/adguardhome/adguardhome.yaml'

    adguardhome_port="$(config_editor 'dns.port' '' "$configpath" '1')"
    [ -n "$adguardhome_port" ] || adguardhome_port='0'

    redirect="$(uci -q get adguardhome.config.redirect)"
    [ -n "$redirect" ] || redirect='none'

    if [ -f "$RUNTIME_STATE_FILE" ]; then
        old_redirect="$(sed -n 's/^old_redirect=//p' "$RUNTIME_STATE_FILE" | tr -d '"')"
        old_port="$(sed -n 's/^old_port=//p' "$RUNTIME_STATE_FILE" | tr -d '"')"
        old_enabled="$(sed -n 's/^old_enabled=//p' "$RUNTIME_STATE_FILE" | tr -d '"')"
    fi

    # Restore existing dnsmasq state before switching modes or disabling
    if [ -f "$DNSMASQ_STATE_FILE" ]; then
        saved_mode="$(dnsmasq_state_mode)"

        if [ "$enabled" = '0' ]; then
            dnsmasq_state_restore "$configpath"

        elif [ "$redirect" = 'dnsmasq-upstream' ]; then
            if [ "$saved_mode" != "$redirect" ]; then
                dnsmasq_state_restore "$configpath"
            fi

        elif [ "$redirect" = 'exchange' ]; then
            if [ "$saved_mode" != "$redirect" ]; then
                dnsmasq_state_restore "$configpath"
            elif [ "$old_enabled" = '1' ] &&
                 [ "$old_redirect" = 'exchange' ] &&
                 [ "$old_port" != "$adguardhome_port" ]; then
                dnsmasq_state_restore "$configpath"
            fi

        else
            dnsmasq_state_restore "$configpath"
        fi
    fi

    # Clean old nft redirect when leaving redirect mode
    if [ "$old_enabled" = '1' ] && [ "$old_redirect" = 'redirect' ]; then
        if [ "$enabled" = '0' ] ||
           [ "$redirect" != 'redirect' ] ||
           [ "$old_port" != "$adguardhome_port" ]; then

            clear_nft_redirect
        fi
    fi

    # Service disabled
    if [ "$enabled" = '0' ]; then
        printf '0' > /var/run/AdGredir
        rm -f "$RUNTIME_STATE_FILE"
        return 1
    fi

    # Ensure dnsmasq has an explicit port before exchange mode
    if ! uci -q get dhcp.@dnsmasq[0].port >/dev/null 2>&1; then
        uci set dhcp.@dnsmasq[0].port='53'
        uci commit dhcp
    fi

    # Apply current mode
    if [ "$redirect" = 'redirect' ]; then

        set_nft_redirect "$adguardhome_port"

    elif [ "$redirect" = 'dnsmasq-upstream' ]; then

        set_forward_dnsmasq "$adguardhome_port" "$configpath"

    elif [ "$redirect" = 'exchange' ]; then

        local current_dnsmasq_port
        current_dnsmasq_port="$(uci -q get dhcp.@dnsmasq[0].port)"

        if [ "$current_dnsmasq_port" = '53' ]; then
            use_port53
        fi
    fi

    # Save volatile runtime state
    cat > "$RUNTIME_STATE_FILE" <<EOF_STATE
old_redirect="$redirect"
old_port="$adguardhome_port"
old_enabled="$enabled"
EOF_STATE

    mark_redirect_flag "$enabled" "$redirect" "$adguardhome_port"
}


_do_redirect "$ENABLED"
