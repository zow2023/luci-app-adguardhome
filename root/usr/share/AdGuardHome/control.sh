#!/bin/sh
# /usr/share/AdGuardHome/control.sh

. /usr/share/AdGuardHome/helper.sh

ENABLED="$1"

NFT_RULES_TPL="/usr/share/AdGuardHome/adguardhome.nft.tpl"
NFT_RULES_FILE="/var/etc/adguardhome.nft"
NFT_TABLE="adguardhome"

RUNTIME_STATE_FILE="/var/run/adguardhome.state"
DNSMASQ_STATE_DIR="/etc/adguardhome"
DNSMASQ_STATE_FILE="${DNSMASQ_STATE_DIR}/dnsmasq.state"


# nftables redirect

set_nft_redirect() {
	local port="$1" wan_section_name wan_ifs="" wan_nft_set="" ifname

	[ -n "$port" ] || return 1
	[ -f "$NFT_RULES_TPL" ] || return 1

	case "$port" in
		''|*[!0-9]*)
			logger -t adguardhome "invalid AGH nft port: $port"
			return 1
			;;
	esac

	[ "$port" -ge 1 ] 2>/dev/null || return 1
	[ "$port" -le 65535 ] 2>/dev/null || return 1

	wan_ifs="$(uci -q get firewall.wan.network 2>/dev/null)"

	if [ -z "$wan_ifs" ]; then
		wan_section_name="$(
			uci show firewall 2>/dev/null |
				awk -F'.' '/\.name='\''wan'\''$/ {print $2}' |
				head -n 1
		)"

		if [ -n "$wan_section_name" ]; then
			wan_ifs="$(
				uci -q get firewall."$wan_section_name".network 2>/dev/null
			)"
		fi
	fi

	for ifname in $wan_ifs; do
		[ -n "$wan_nft_set" ] &&
			wan_nft_set="${wan_nft_set}, "
		wan_nft_set="${wan_nft_set}\"${ifname}\""
	done

	if [ -n "$wan_nft_set" ]; then
		sed \
			-e "s/__WAN_EXCLUDES__/${wan_nft_set}/g" \
			-e "s/__AGH_PORT__/${port}/g" \
			"$NFT_RULES_TPL" > "$NFT_RULES_FILE"
	else
		sed \
			-e "/iifname { __WAN_EXCLUDES__ } return/d" \
			-e "s/__AGH_PORT__/${port}/g" \
			"$NFT_RULES_TPL" > "$NFT_RULES_FILE"
	fi

	if [ $? -ne 0 ]; then
		logger -t adguardhome "failed to generate nft rules"
		return 1
	fi

	if ! nft -c -f "$NFT_RULES_FILE" >/dev/null 2>&1; then
		logger -t adguardhome "generated nft rules failed validation"
		return 1
	fi

	nft delete table inet "$NFT_TABLE" 2>/dev/null

	if ! nft -f "$NFT_RULES_FILE" >/dev/null 2>&1; then
		logger -t adguardhome "failed to apply nft table $NFT_TABLE"
		return 1
	fi

	if ! fw4 reload >/dev/null 2>&1; then
		logger -t adguardhome \
			"fw4 reload failed after applying nft table $NFT_TABLE"
		return 1
	fi

	if ! nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
		logger -t adguardhome \
			"nft table $NFT_TABLE missing after fw4 reload"
		return 1
	fi

	logger -t adguardhome \
		"nft table $NFT_TABLE applied on port $port, WAN excludes: ${wan_nft_set:-none}"

	return 0
}


clear_nft_redirect() {
	if ! nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
		[ -f "$NFT_RULES_FILE" ] && > "$NFT_RULES_FILE"
		return 0
	fi

	if ! nft delete table inet "$NFT_TABLE" 2>/dev/null; then
		logger -t adguardhome "failed to clear nft table $NFT_TABLE"
		return 1
	fi

	[ -f "$NFT_RULES_FILE" ] && > "$NFT_RULES_FILE"

	if ! fw4 reload >/dev/null 2>&1; then
		logger -t adguardhome \
			"fw4 reload failed while clearing nft table $NFT_TABLE"
		return 1
	fi

	if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
		logger -t adguardhome \
			"nft table $NFT_TABLE still exists after clear"
		return 1
	fi

	logger -t adguardhome "nft table $NFT_TABLE cleared"
	return 0
}


# Persistent dnsmasq state

dnsmasq_state_save() {
	local configpath="$1" mode="$2" agh_port="$3"
	local server_values value resolvfile noresolv dnsmasq_port

	[ -f "$DNSMASQ_STATE_FILE" ] && return 0

	mkdir -p "$DNSMASQ_STATE_DIR" || {
		logger -t adguardhome "failed to create dnsmasq state directory"
		return 1
	}

	chmod 0700 "$DNSMASQ_STATE_DIR"

	{
		printf 'version=1\n'
		printf 'mode=%s\n' "$mode"

		if uci -q get dhcp.@dnsmasq[0].server >/dev/null 2>&1; then
			printf 'server_exists=1\n'
			server_values="$(
				uci -q get dhcp.@dnsmasq[0].server 2>/dev/null
			)"

			for value in $server_values; do
				[ -n "$value" ] || continue
				printf 'server_item=%s\n' "$value"
			done
		else
			printf 'server_exists=0\n'
		fi

		if resolvfile="$(uci -q get dhcp.@dnsmasq[0].resolvfile 2>/dev/null)"; then
			printf 'resolvfile_exists=1\n'
			printf 'resolvfile=%s\n' "$resolvfile"
		else
			printf 'resolvfile_exists=0\n'
		fi

		if noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)"; then
			printf 'noresolv_exists=1\n'
			printf 'noresolv=%s\n' "$noresolv"
		else
			printf 'noresolv_exists=0\n'
		fi

		if dnsmasq_port="$(uci -q get dhcp.@dnsmasq[0].port 2>/dev/null)"; then
			printf 'dnsmasq_port_exists=1\n'
			printf 'dnsmasq_port=%s\n' "$dnsmasq_port"
		else
			printf 'dnsmasq_port_exists=0\n'
		fi

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
	sed -n 's/^mode=//p' "$DNSMASQ_STATE_FILE" | head -n 1
}


dnsmasq_state_restore() {
	local configpath="$1"
	local old_mode server_exists resolvfile_exists noresolv_exists dnsmasq_port_exists
	local resolvfile noresolv dnsmasq_port agh_port value

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

	uci -q delete dhcp.@dnsmasq[0].server

	if [ "$server_exists" = "1" ]; then
		sed -n 's/^server_item=//p' "$DNSMASQ_STATE_FILE" |
			while IFS= read -r value; do
				[ -n "$value" ] || continue
				uci add_list dhcp.@dnsmasq[0].server="$value"
			done
	fi

	uci -q delete dhcp.@dnsmasq[0].resolvfile

	if [ "$resolvfile_exists" = "1" ]; then
		resolvfile="$(
			sed -n 's/^resolvfile=//p' "$DNSMASQ_STATE_FILE" |
				head -n 1
		)"

		uci set dhcp.@dnsmasq[0].resolvfile="$resolvfile"
	fi

	uci -q delete dhcp.@dnsmasq[0].noresolv

	if [ "$noresolv_exists" = "1" ]; then
		noresolv="$(
			sed -n 's/^noresolv=//p' "$DNSMASQ_STATE_FILE" |
				head -n 1
		)"

		uci set dhcp.@dnsmasq[0].noresolv="$noresolv"
	fi

	uci -q delete dhcp.@dnsmasq[0].port

	if [ "$dnsmasq_port_exists" = "1" ]; then
		dnsmasq_port="$(
			sed -n 's/^dnsmasq_port=//p' "$DNSMASQ_STATE_FILE" |
				head -n 1
		)"

		uci set dhcp.@dnsmasq[0].port="$dnsmasq_port"
	fi

	uci commit dhcp

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


# dnsmasq upstream mode

set_forward_dnsmasq() {
	local port="$1" configpath="$2"
	local addr="127.0.0.1#$port" old_server server

	old_server="$(
		uci -q get dhcp.@dnsmasq[0].server 2>/dev/null
	)"

	echo "$old_server" |
		grep -q -E "(^|[[:space:]])${addr}([[:space:]]|$)" &&
		return 0

	dnsmasq_state_save \
		"$configpath" \
		'dnsmasq-upstream' \
		"$port" || {
		logger -t adguardhome \
			"failed to save original dnsmasq configuration"
		return 1
	}

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


# Exchange AGH and dnsmasq port 53

use_port53() {
	local configpath adguardhome_port dnsmasq_port original_agh_port

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

	if [ "$adguardhome_port" = '53' ] &&
		[ "$dnsmasq_port" != '53' ]; then
		return 0
	fi

	original_agh_port="$adguardhome_port"

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

	config_editor 'dns.port' '53' "$configpath"

	uci set dhcp.@dnsmasq[0].port="$adguardhome_port"
	uci commit dhcp

	/etc/init.d/dnsmasq reload >/dev/null 2>&1
	agh_reload
}


# ubus reload helper

agh_reload() {
	ubus call service event \
		'{"type":"config.change","data":{"package":"adguardhome"}}' \
		>/dev/null 2>&1
}


# Redirect state indicator

mark_redirect_flag() {
	local enabled="$1" redirect="$2" agh_port="$3" configpath flag=0

	configpath="$(uci -q get adguardhome.config.config_file)"
	[ -n "$configpath" ] ||
		configpath='/etc/adguardhome/adguardhome.yaml'

	case "$agh_port" in
		''|*[!0-9]*)
			agh_port='0'
			;;
	esac

	if [ "$enabled" = '1' ] &&
		[ "$redirect" != 'none' ]; then

		flag=1

		if [ "$redirect" = 'redirect' ]; then
			local nft_rules

			nft_rules="$(
				nft list chain inet "$NFT_TABLE" prerouting 2>/dev/null
			)"

			echo "$nft_rules" |
				grep -q "udp dport 53 redirect to :${agh_port}" ||
				flag=0

			echo "$nft_rules" |
				grep -q "tcp dport 53 redirect to :${agh_port}" ||
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
			local cfgp dport

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


# Main controller

_do_redirect() {
	local enabled="$1"
	local configpath config_agh_port current_dnsmasq_port redirect
	local old_redirect='none' old_port='0' old_enabled='0' saved_mode

	configpath="$(uci -q get adguardhome.config.config_file)"
	[ -n "$configpath" ] ||
		configpath='/etc/adguardhome/adguardhome.yaml'

	config_agh_port="$(
		config_editor 'dns.port' '' "$configpath" '1'
	)"

	[ -n "$config_agh_port" ] ||
		config_agh_port='0'

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

	if [ -z "$current_dnsmasq_port" ]; then
		current_dnsmasq_port='53'
		uci set dhcp.@dnsmasq[0].port='53'
		uci commit dhcp
	fi

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
				[ "$config_agh_port" != '53' ]; then
				dnsmasq_state_restore "$configpath"
			fi

		else
			dnsmasq_state_restore "$configpath"
		fi
	fi

	current_dnsmasq_port="$(
		uci -q get dhcp.@dnsmasq[0].port
	)"

	[ -n "$current_dnsmasq_port" ] ||
		current_dnsmasq_port='53'

	if [ "$old_enabled" = '1' ] &&
		[ "$old_redirect" = 'redirect' ]; then

		if [ "$enabled" = '0' ]; then
			if ! clear_nft_redirect; then
				logger -t adguardhome \
					"failed to clear previous redirect rules"
				return 1
			fi
		elif [ "$redirect" != 'redirect' ]; then
			if ! clear_nft_redirect; then
				logger -t adguardhome \
					"failed to clear previous redirect rules"
				return 1
			fi
		elif [ "$old_port" != "$config_agh_port" ]; then
			if ! clear_nft_redirect; then
				logger -t adguardhome \
					"failed to clear previous redirect rules"
				return 1
			fi
		fi
	fi

	if [ "$enabled" = '0' ]; then
		printf '0' > /var/run/AdGredir
		rm -f "$RUNTIME_STATE_FILE"
		return 0
	fi

	if [ "$redirect" = 'redirect' ]; then
		if ! set_nft_redirect "$config_agh_port"; then
			logger -t adguardhome "failed to apply redirect mode"
			return 1
		fi

	elif [ "$redirect" = 'dnsmasq-upstream' ]; then
		if ! set_forward_dnsmasq \
			"$config_agh_port" \
			"$configpath"; then
			logger -t adguardhome \
				"failed to apply dnsmasq-upstream mode"
			return 1
		fi

	elif [ "$redirect" = 'exchange' ]; then
		current_dnsmasq_port="$(
			uci -q get dhcp.@dnsmasq[0].port
		)"

		[ -n "$current_dnsmasq_port" ] ||
			current_dnsmasq_port='53'

		if [ "$current_dnsmasq_port" = '53' ]; then
			if ! use_port53; then
				logger -t adguardhome "failed to apply exchange mode"
				return 1
			fi
		fi
	fi

	cat > "$RUNTIME_STATE_FILE" <<EOF_STATE
old_redirect="$redirect"
old_port="$config_agh_port"
old_enabled="$enabled"
EOF_STATE

	mark_redirect_flag \
		"$enabled" \
		"$redirect" \
		"$config_agh_port"

	if [ "$redirect" = 'redirect' ] &&
		[ "$(cat /var/run/AdGredir 2>/dev/null)" != '1' ]; then
		logger -t adguardhome \
			"redirect rules were applied but state verification failed"
		return 1
	fi

	return 0
}


_do_redirect "$ENABLED"
