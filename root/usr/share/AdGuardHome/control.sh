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
# Keep it under /etc/adguardhome because /etc survives reboot on OpenWrt.
DNSMASQ_STATE_DIR="/etc/adguardhome"
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

        [ -n "$wan_section_name" ] &&
            wan_ifs="$(uci -q get firewall."$wan_section_name".network 2>/dev/null)"
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
    local agh_port="$3"

    local server_values
    local value
    local resolvfile
    local noresolv
    local dnsmasq_port

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

            # Keep the original upstream servers while placing AGH first.
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

        # The caller passes this value BEFORE AGH is modified.
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

    logger -t adguardhome \
        "saved original dnsmasq configuration, mode=$mode"

    return 0
}


dnsmasq_state_mode() {
    [ -f "$DNSMASQ_STATE_FILE" ] || return 1

    sed -n 's/^mode=//p' "$DNSMASQ_STATE_FILE" |
        head -n 1
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
        sed -n 's/^mode=//p' "$DNSMASQ_STATE_FILE" |
            head -n 1
    )"

    server_exists="$(
        sed -n 's/^server_exists=//p' "$DNSMASQ_STATE_FILE" |
            head -n 1
    )"

    resolvfile_exists="$(
        sed -n 's/^resolvfile_exists=//p' "$DNSMASQ_STATE_FILE" |
            head -n 1
    )"

    noresolv_exists="$(
        sed -n 's/^noresolv_exists=//p' "$DNSMASQ_STATE_FILE" |
            head -n 1
    )"

    dnsmasq_port_exists="$(
        sed -n 's/^dnsmasq_port_exists=//p' "$DNSMASQ_STATE_FILE" |
            head -n 1
    )"

    agh_port="$(
        sed -n 's/^agh_port=//p' "$DNSMASQ_STATE_FILE" |
            head -n 1
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
            sed -n 's/^resolvfile=//p' "$DNSMASQ_STATE_FILE" |
                head -n 1
        )"

        uci set dhcp.@dnsmasq[0].resolvfile="$resolvfile"
    fi

    # ---------------------------------------------------------------
    # Restore noresolv
    # ---------------------------------------------------------------

    uci -q delete dhcp.@dnsmasq[0].noresolv

    if [ "$noresolv_exists" = "1" ]; then
        noresolv="$(
            sed -n 's/^noresolv=//p' "$DNSMASQ_STATE_FILE" |
                head -n 1
        )"

        uci set dhcp.@dnsmasq[0].noresolv="$noresolv"
    fi

    # ---------------------------------------------------------------
    # Restore dnsmasq port
    # ---------------------------------------------------------------

    uci -q delete dhcp.@dnsmasq[0].port

    if [ "$dnsmasq_port_exists" = "1" ]; then
        dnsmasq_port="$(
            sed -n 's/^dnsmasq_port=//p' "$DNSMASQ_STATE_FILE" |
                head -n 1
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

    /etc/init.d/dnsmasq reload >/dev/null 2>&1
    agh_reload

    rm -f "$DNSMASQ_STATE_FILE"

    logger -t adguardhome "restored original dnsmasq configuration"
}


# ---------------------------------------------------------------------------
# dnsmasq upstream mode
# ---------------------------------------------------------------------------

set_forward_dnsmasq() {
    local port="$1"
    local configpath="$2"

    local addr="127.0.0.1#$port"
    local old_server
    local server

    old_server="$(
        uci -q get dhcp.@dnsmasq[0].server 2>/dev/null
    )"

    # Already using AGH as an upstream server.
    echo "$old_server" |
        grep -q -E "(^|[[:space:]])${addr}([[:space:]]|$)" &&
        return 0

    # Save the user's original configuration before taking over.
    dnsmasq_state_save \
        "$configpath" \
        'dnsmasq-upstream' \
        "$port" || {
        logger -t adguardhome "failed to save original dnsmasq configuration"
        return 1
    }

    # Follow rufengsuixing's upstream behavior:
    # AGH is placed first while existing upstream servers are retained.
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server="$addr"

    for server in $old_server; do
        [ -n "$server" ] || continue
        [ "$server" = "$addr" ] && continue
        uci add_list dhcp.@dnsmasq[0].server="$server"
    done

    uci -q delete dhcp.@dnsmasq[0].resolvfile
    uci set dhcp.@dnsmasq[0].noresolv=1
    uci commit dhcp

    /etc/init.d/dnsmasq reload >/dev/null 2>&1
}


# ---------------------------------------------------------------------------
# Exchange AGH and dnsmasq port 53
# ---------------------------------------------------------------------------

use_port53() {
    local configpath
    local adguardhome_port
    local dnsmasq_port
    local original_agh_port

    configpath="$(uci -q get adguardhome.config.config_file)"
    [ -n "$configpath" ] ||
        configpath='/etc/adguardhome/adguardhome.yaml'

    adguardhome_port="$(
        config_editor 'dns.port' '' "$configpath" '1'
    )"

    [ -n "$adguardhome_port" ] ||
        adguardhome_port='53'

    dnsmasq_port="$(
        uci -q get dhcp.@dnsmasq[0].port
    )"

    [ -n "$dnsmasq_port" ] ||
        dnsmasq_port='53'

    # Already in exchange state:
    # AGH owns 53 and dnsmasq owns a non-53 port.
    if [ "$adguardhome_port" = '53' ] &&
        [ "$dnsmasq_port" != '53' ]; then
        return 0
    fi

    original_agh_port="$adguardhome_port"

    # Save the complete pre-exchange state BEFORE modifying either side.
    dnsmasq_state_save \
        "$configpath" \
        'exchange' \
        "$original_agh_port" || {
        logger -t adguardhome \
            "failed to save original dnsmasq configuration for exchange mode"
        return 1
    }

    if [ "$dnsmasq_port" = "$adguardhome_port" ]; then
        if [ "$adguardhome_port" = '53' ]; then
            adguardhome_port='1745'
        fi
    elif [ "$adguardhome_port" = '53' ]; then
        return 0
    fi

    # AGH gets port 53.
    config_editor 'dns.port' '53' "$configpath"

    # dnsmasq gets the original AGH port.
    uci set dhcp.@dnsmasq[0].port="$adguardhome_port"
    uci commit dhcp

    /etc/init.d/dnsmasq reload >/dev/null 2>&1
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
    [ -n "$configpath" ] ||
        configpath='/etc/adguardhome/adguardhome.yaml'

    [ -n "$agh_port" ] || agh_port='5353'

    if [ "$enabled" = '1' ] &&
        [ "$redirect" != 'none' ]; then

        flag=1

        if [ "$redirect" = 'redirect' ]; then

            nft list table inet "$NFT_TABLE" \
                >/dev/null 2>&1 ||
                flag=0

        elif [ "$redirect" = 'dnsmasq-upstream' ]; then

            local server_values

            server_values="$(
                uci -q get dhcp.@dnsmasq[0].server 2>/dev/null
            )"

            echo "$server_values" |
                grep -q -E \
                    "(^|[[:space:]])127\\.0\\.0\\.1#${agh_port}([[:space:]]|$)" ||
                flag=0

        elif [ "$redirect" = 'exchange' ]; then

            local cfgp
            local dport

            cfgp="$(
                config_editor 'dns.port' '' "$configpath" '1'
            )"

            dport="$(
                uci -q get dhcp.@dnsmasq[0].port 2>/dev/null
            )"

            if [ "$cfgp" != '53' ] ||
                [ "$dport" = '53' ]; then
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
    local config_agh_port
    local current_dnsmasq_port
    local redirect

    local old_redirect='none'
    local old_port='0'
    local old_enabled='0'

    local saved_mode

    configpath="$(uci -q get adguardhome.config.config_file)"
    [ -n "$configpath" ] ||
        configpath='/etc/adguardhome/adguardhome.yaml'

    # Current AGH port from the actual YAML configuration.
    config_agh_port="$(
        config_editor 'dns.port' '' "$configpath" '1'
    )"

    [ -n "$config_agh_port" ] ||
        config_agh_port='0'

    # Current dnsmasq port from UCI.
    current_dnsmasq_port="$(
        uci -q get dhcp.@dnsmasq[0].port
    )"

    [ -n "$current_dnsmasq_port" ] ||
        current_dnsmasq_port='53'

    redirect="$(
        uci -q get adguardhome.config.redirect
    )"

    [ -n "$redirect" ] ||
        redirect='none'

    # Load the last runtime state.
    if [ -f "$RUNTIME_STATE_FILE" ]; then
        old_redirect="$(
            sed -n 's/^old_redirect=//p' "$RUNTIME_STATE_FILE" |
                tr -d '"'
        )"

        old_port="$(
            sed -n 's/^old_port=//p' "$RUNTIME_STATE_FILE" |
                tr -d '"'
        )"

        old_enabled="$(
            sed -n 's/^old_enabled=//p' "$RUNTIME_STATE_FILE" |
                tr -d '"'
        )"
    fi

    # Ensure dnsmasq has an explicit port before exchange mode.
    if [ -z "$current_dnsmasq_port" ]; then
        current_dnsmasq_port='53'
        uci set dhcp.@dnsmasq[0].port='53'
        uci commit dhcp
    fi

    # -----------------------------------------------------------------------
    # Restore an existing dnsmasq takeover before applying a different mode.
    #
    # config_agh_port is never overwritten with the dnsmasq port.
    # -----------------------------------------------------------------------

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

                # Different takeover mode: restore the original state first.
                dnsmasq_state_restore "$configpath"

            elif [ "$old_enabled" = '1' ] &&
                [ "$old_redirect" = 'exchange' ] &&
                [ "$config_agh_port" != '53' ]; then

                # Exchange mode should always leave AGH on port 53.
                #
                # If the YAML was manually changed while exchange was active,
                # restore the original snapshot and rebuild exchange.
                dnsmasq_state_restore "$configpath"
            fi

        else

            # Current mode no longer needs dnsmasq takeover.
            dnsmasq_state_restore "$configpath"
        fi
    fi

    # Refresh current dnsmasq port after any possible restore.
    current_dnsmasq_port="$(
        uci -q get dhcp.@dnsmasq[0].port
    )"

    [ -n "$current_dnsmasq_port" ] ||
        current_dnsmasq_port='53'

    # -----------------------------------------------------------------------
    # Clean old nft redirect when leaving redirect mode.
    # -----------------------------------------------------------------------

    if [ "$old_enabled" = '1' ] &&
        [ "$old_redirect" = 'redirect' ]; then

        if [ "$enabled" = '0' ] ||
            [ "$redirect" != 'redirect' ] ||
            [ "$old_port" != "$config_agh_port" ]; then

            clear_nft_redirect
        fi
    fi

    # -----------------------------------------------------------------------
    # Service disabled.
    # -----------------------------------------------------------------------

    if [ "$enabled" = '0' ]; then
        printf '0' > /var/run/AdGredir
        rm -f "$RUNTIME_STATE_FILE"
        return 1
    fi

    # -----------------------------------------------------------------------
    # Apply current mode.
    # -----------------------------------------------------------------------

    if [ "$redirect" = 'redirect' ]; then

        set_nft_redirect "$config_agh_port"

    elif [ "$redirect" = 'dnsmasq-upstream' ]; then

        set_forward_dnsmasq \
            "$config_agh_port" \
            "$configpath"

    elif [ "$redirect" = 'exchange' ]; then

        current_dnsmasq_port="$(
            uci -q get dhcp.@dnsmasq[0].port
        )"

        [ -n "$current_dnsmasq_port" ] ||
            current_dnsmasq_port='53'

        if [ "$current_dnsmasq_port" = '53' ]; then
            use_port53
        fi
    fi

    # -----------------------------------------------------------------------
    # Save runtime state.
    # -----------------------------------------------------------------------

    cat > "$RUNTIME_STATE_FILE" <<EOF_STATE
old_redirect="$redirect"
old_port="$config_agh_port"
old_enabled="$enabled"
EOF_STATE

    mark_redirect_flag \
        "$enabled" \
        "$redirect" \
        "$config_agh_port"
}


_do_redirect "$ENABLED"
