'use strict';

'require dom';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require view';

const DEFAULT_CONFIG_FILE = '/etc/adguardhome/adguardhome.yaml';
const DEFAULT_WORK_DIR = '/var/lib/adguardhome';
const DEFAULT_USER = 'adguardhome';
const DEFAULT_GROUP = DEFAULT_USER;

const DEFAULT_GOGC = '0';
const DEFAULT_GOMAXPROCS = '0';
const DEFAULT_GOMEMLIMIT = '0';

const PATH_REGEX = new RegExp('^/etc(/[^/]+)?/?$');

const POLL_INTERVAL = 5;

const RUNNING_SPAN = `<span style="color: green; font-weight: bold">${_('Running')}</span>`;
const NOT_RUNNING_SPAN = `<span style="color: red; font-weight: bold">${_('Not running')}</span>`;

const STORAGE_KEY = 'luci-app-adguardhome';
const STORAGE_KEY_CORE = 'luci-app-adguardhome_core_update';

function getServiceInfo(name) {
	const fn = rpc.declare({
		object: 'service',
		method: 'list',
		params: ['name'],
		expect: { [name]: { instances: { [name]: {} }}},
	});
	return () => fn(name);
}

const getAGHServiceInfo = getServiceInfo('adguardhome');

async function getStatus() {
	try {
		const res = await getAGHServiceInfo();
		const isRunning = res?.instances?.adguardhome?.running;
		return isRunning ?? false;
	} catch (e) {
		console.error(e);
		return false;
	}
}

function getStatusValue(isRunning) {
	return isRunning ? RUNNING_SPAN : NOT_RUNNING_SPAN;
}

async function getVersion() {
	try {
		const res = await fs.exec('/usr/bin/AdGuardHome', ['--version']);
		const version = res.stdout
			? (res.stdout.match(/version\s+(.*)/) || [null, res.stdout.trim()])[1]
			: '';
		return version;
	} catch (e) {
		console.error(e);
		return '';
	}
}

function updateStatus(node) {
	const output = node?.querySelector('output');
	return output
		? async () => {
			const isRunning = await getStatus();
			dom.content(output, getStatusValue(isRunning));
		}
		: () => {};
}

function validateConfigFile(_unused, value) {
	if (value == null || value === '') {
		return true;
	}
	if (!value.startsWith('/')) {
		return _('Path must be absolute.');
	}
	if (value.endsWith('/')) {
		return _('Path must not end with a slash.');
	}
	if (PATH_REGEX.test(value)) {
		return _('Configuration file must be stored in its own directory, and not in \'/etc\'.');
	}
	return true;
}

function validateWorkDir(_unused, value) {
	if (value == null || value === '') {
		return true;
	}
	if (!value.startsWith('/')) {
		return _('Path must be absolute.');
	}
	return true;
}

//
// FIX: robust YAML section extraction helpers.
// The previous code matched the *second* occurrence of "port:" anywhere
// in the file and assumed it was dns.port, and matched the *first*
// "address:" anywhere for the WebUI listener.  Both break when sections
// are reordered or absent (pprof, tls, etc.).  Now we locate the
// "dns:" / "http:" top-level sections first and only parse inside them.
//

function extractSection(yaml, section) {
	const re = new RegExp(`(?:^|\\n)${section}:\\s*(?:#.*)?\\n`);
	const m = yaml.match(re);
	if (!m) {
		return null;
	}
	const start = m.index + m[0].length;
	// The section body continues until the next non-indented line.
	const rest = yaml.slice(start);
	const endMatch = rest.match(/^(?!\s)(?!\s*$)/m);
	const body = endMatch ? rest.slice(0, endMatch.index) : rest;
	return body;
}

function extractDnsPort(yaml) {
	const body = extractSection(yaml, 'dns');
	if (!body) {
		return null;
	}
	const pm = body.match(/^\s*port:\s*["']?(\d+)/m);
	return pm ? pm[1] : null;
}

function extractHttpAddress(yaml) {
	const body = extractSection(yaml, 'http');
	if (!body) {
		return null;
	}
	const am = body.match(/^\s*address:\s*["']?([^\s"']+)/m);
	return am ? am[1] : null;
}

return view.extend({
	load() {
		return Promise.all([
			getStatus(),
			getVersion(),
			uci.load('adguardhome').then(() => {
				const sections = uci.sections('adguardhome', 'adguardhome');
				const sec = sections.length > 0 ? sections[0] : {};
				const configFile = sec.config_file || DEFAULT_CONFIG_FILE;
				return fs.read(configFile).catch(() => null);
			})
		]);
	},

	async render([isRunning, version, yamlContent]) {
		const coreExists = Boolean(version);

		// FIX: parse dns.port from its own section.
		let dnsPort = yamlContent ? extractDnsPort(yamlContent) : null;
		if (!dnsPort) {
			dnsPort = '53';
		}

		const sections = uci.sections('adguardhome', 'adguardhome');
		const savedHttpPort = (sections.length > 0 && sections[0].httpport) ? sections[0].httpport : '3008';

		const map = new form.Map('adguardhome', _('AdGuard Home'));

		const statusSect = map.section(form.TypedSection, 'status');
		statusSect.anonymous = true;
		statusSect.cfgsections = () => ['status_section'];

		const versionOpt = statusSect.option(form.DummyValue, '_version', _('Version'));
		versionOpt.cfgvalue = () => version || `<span style="color: var(--error-color-high); font-weight: bold;">${_('Not installed')}</span>`;
		versionOpt.rawhtml = true;

		const statusOpt = statusSect.option(form.DummyValue, '_status', _('Service Status'));
		statusOpt.rawhtml = true;
		statusOpt.cfgvalue = () => getStatusValue(isRunning);

		const mainSect = map.section(form.TypedSection, 'adguardhome');
		mainSect.anonymous = true;

		mainSect.tab('general', _('General Settings'));
		mainSect.tab(
			'jail',
			_('File System Access'),
			_('Files and directories that AdGuard Home should have read-only or read-write access to.'),
		);
		mainSect.tab('dns_redirect', _('Services Settings'));
		mainSect.tab(
			'core_update',
			_('Core Update'),
			_('Settings and operations for updating the AdGuardHome core binary.')
		);
		mainSect.tab(
			'advanced',
			_('Advanced Settings'),
			_('Go environment variables that tune garbage collector and memory management.') +
				' ' + _('Modify at your own risk.'),
		);

		mainSect.tab('logs', _('Logs'));

		const enabledOpt = mainSect.taboption(
			'general',
			form.Flag,
			'enabled',
			_('Enable')
		);
		enabledOpt.default = '0';
		enabledOpt.rmempty = false;
		if (!coreExists) {
			enabledOpt.description = `<span style="color: var(--error-color-high); font-weight: bold;">${_('Core binary not found. Enable the service to trigger an automatic download.')}</span>`;
		}

		const configFileOpt = mainSect.taboption(
			'general',
			form.Value,
			'config_file',
			_('Configuration file'),
			_('Configuration file must be stored in its own directory, and not in \'/etc\'.') +
				'<br />' + _('Parent directory will be owned by the service user.') +
				'<br />' + _('If empty, defaults to') + ` '${DEFAULT_CONFIG_FILE}'.`,
		);
		configFileOpt.placeholder = DEFAULT_CONFIG_FILE;
		configFileOpt.validate = validateConfigFile;

		const workDirOpt = mainSect.taboption(
			'general',
			form.Value,
			'work_dir',
			_('Working directory'),
			_('Directory where filters, logs, and statistics are stored.') +
				'<br />' + _('Will be owned by the service user.') +
				'<br />' + _('If empty, defaults to') + ` '${DEFAULT_WORK_DIR}'.`,
		);
		workDirOpt.placeholder = DEFAULT_WORK_DIR;
		workDirOpt.validate = validateWorkDir;

		const userOpt = mainSect.taboption(
			'general',
			form.Value,
			'user',
			_('Service user'),
			_('User the service runs under.') + ' ' + _('If empty, defaults to') +
				` '${DEFAULT_USER}'.`,
		);
		userOpt.placeholder = DEFAULT_USER;

		const groupOpt = mainSect.taboption(
			'general',
			form.Value,
			'group',
			_('Service group'),
			_('Group the service runs under.') + ' ' + _('If empty, defaults to') +
				` '${DEFAULT_GROUP}'.`,

		);
		groupOpt.placeholder = DEFAULT_GROUP;

		const verboseOpt = mainSect.taboption(
			'general',
			form.Flag,
			'verbose',
			_('Verbose logging'),
		);
		verboseOpt.default = '0';

		const advSettingsOpt = mainSect.taboption(
			'general',
			form.Flag,
			'advanced_settings',
			_('Advanced Settings'),
		);
		advSettingsOpt.default = '0';
		advSettingsOpt.rmempty = false;
		advSettingsOpt.load = () => sessionStorage.getItem(STORAGE_KEY) || '0';
		advSettingsOpt.remove = () => {};
		advSettingsOpt.write = (_, value) => sessionStorage.setItem(STORAGE_KEY, value);

		const coreUpdateToggleOpt = mainSect.taboption(
			'general',
			form.Flag,
			'enable_core_update',
			_('Core Update'),
			_('Show the tab and settings for updating the AdGuardHome core binary.')
		);
		coreUpdateToggleOpt.default = '0';
		coreUpdateToggleOpt.rmempty = false;
		coreUpdateToggleOpt.load = () => sessionStorage.getItem(STORAGE_KEY_CORE) || '0';
		coreUpdateToggleOpt.remove = () => {};
		coreUpdateToggleOpt.write = (_, value) => sessionStorage.setItem(STORAGE_KEY_CORE, value);

		mainSect.taboption('jail', form.DynamicList, 'jail_mount', _('Read-only access'));
		mainSect.taboption('jail', form.DynamicList, 'jail_mount_rw', _('Read-write access'));

		const gcOpt = mainSect.taboption(
			'advanced',
			form.Value,
			'gc',
			'GOGC',
			_('Tunes the garbage collector\'s aggressiveness by setting the percentage of heap ' +
				'growth allowed before the next collection cycle triggers.') + '<br />' +
				_('If empty, defaults to') + ' ' + _('unset and 100') + '.',
				'<a href="https://go.dev/doc/gc-guide#GOGC" target="_blank">https://go.dev/doc/gc-guide#GOGC</a>'
		);
		gcOpt.datatype = 'uinteger';
		gcOpt.depends('advanced_settings', '1');
		gcOpt.placeholder = DEFAULT_GOGC;
		gcOpt.retain = true;

		const maxProcsOpt = mainSect.taboption(
			'advanced',
			form.Value,
			'maxprocs',
			'GOMAXPROCS',
			_('The maximum number of operating system threads that can execute user-level Go code' +
				' simultaneously.') + '<br />' +
				_('If empty, defaults to') + ' ' + _('unset and matching the number of CPUs') + '.',
		);
		maxProcsOpt.datatype = 'uinteger';
		maxProcsOpt.depends('advanced_settings', '1');
		maxProcsOpt.placeholder = DEFAULT_GOMAXPROCS;
		maxProcsOpt.retain = true;

		const memLimitOpt = mainSect.taboption(
			'advanced',
			form.Value,
			'memlimit',
			'GOMEMLIMIT',
			_('A soft memory cap for the Go runtime, allowing the garbage collector to run more ' +
				'frequently as usage approaches the limit to prevent Out-of-Memory (OOM) kills.') +
				'<br />' +
				_('If empty, defaults to') + ' ' + _('unset') + '.',
		);
		memLimitOpt.datatype = 'uinteger';
		memLimitOpt.depends('advanced_settings', '1');
		memLimitOpt.placeholder = DEFAULT_GOMEMLIMIT;
		memLimitOpt.retain = true;

		const logsOpt = mainSect.taboption(
			'logs',
			form.DummyValue,
			'_logs',
			''
		);

		logsOpt.rawhtml = true;
		logsOpt.cfgvalue = () => `
			<div id="agh-log-container" style="width:100%; max-width:none;">
				<div style="margin-bottom:8px; display:flex; gap:8px; align-items:center;">
					<button type="button" class="btn cbi-button cbi-button-apply" id="btn-agh-log-refresh">${_('Refresh')}</button>
					<button type="button" class="btn cbi-button cbi-button-reset" id="btn-agh-log-clear" disabled>${_('Clear Logs')}</button>
				</div>
				<div style="margin-bottom:8px;">${_('Showing last 50 lines')}</div>
				<textarea
					id="agh-syslog"
					class="cbi-input-textarea"
					style="width:100%; max-width:none; height:420px; min-height:420px; box-sizing:border-box; font-family:monospace; font-size:12px; white-space:pre; overflow:auto; resize:vertical;"
					readonly="readonly"
					wrap="off"
				></textarea>
			</div>
		`;

		// FIX: parse the WebUI listener from the http: section only.
		let realHttpAddress = '0.0.0.0:3008';
		if (yamlContent) {
			const addr = extractHttpAddress(yamlContent);
			if (addr) {
				realHttpAddress = addr;
			}
		}

		let linkIp = window.location.hostname;
		let linkPort = '3008';
		const addrParts = realHttpAddress.split(':');
		if (addrParts.length >= 2) {
			linkPort = addrParts.pop();
			let ipPart = addrParts.join(':').replace(/\[|\]/g, '');
			if (ipPart !== '0.0.0.0' && ipPart !== '') {
				linkIp = ipPart;
			}
		}

		const isServiceEnabled = sections.length > 0 && sections[0].enabled === '1';
		const disabledHint = _('Service is disabled. Please go to "General Settings" to enable it.');

		const webuiBtnHtml = isServiceEnabled
			? `<a class="btn cbi-button cbi-button-link" style="font-weight:bold; display:inline-block; margin-top:5px;" href="http://${linkIp}:${linkPort}" target="_blank">${_('Open AdGuardHome WebUI')}</a>`
			: `<span title='${disabledHint}' style="display:inline-block; margin-top:5px; cursor:not-allowed;">
					<a class="btn cbi-button cbi-button-link" style="font-weight:bold; pointer-events:none; opacity:0.5; margin-top:0;" href="javascript:void(0);">${_('Open AdGuardHome WebUI')}</a>
			   </span>`;

		const httpAddressOpt = mainSect.taboption(
			'dns_redirect',
			form.Value,
			'http_address',
			_('WebUI listener (address:port)'),
			_('Bind to specific interface:port (e.g., 0.0.0.0:3008). Leave as 0.0.0.0 to listen on all interfaces.') + 
			`<br />${webuiBtnHtml}`
		);
		httpAddressOpt.placeholder = '0.0.0.0:3008';
		httpAddressOpt.default = '0.0.0.0:3008';
		httpAddressOpt.datatype = 'hostport';
		httpAddressOpt.rmempty = false;

		httpAddressOpt.cfgvalue = function(section_id) {
			return realHttpAddress;
		};

		const isPasswordEmpty = yamlContent ? /password:[ \t]*(\r?\n|$)/.test(yamlContent) : false;
		const hashPassOpt = mainSect.taboption(
			'dns_redirect',
			form.Value,
			'hashpass',
			_('Change password'),
			_('Enter the password here. Click the Load calculate Module button below and go on.') + 
			'<br /><button class="btn cbi-button cbi-button-apply" type="button" id="btn-agh-calc-hash" style="display:inline-block; margin-top:5px;">' +
				_('... Load calculate Module ...') + 
			'</button>'
		);
		hashPassOpt.default = '';
		hashPassOpt.datatype = 'string';
		hashPassOpt.password = true;
		hashPassOpt.rmempty = true;
		hashPassOpt.placeholder = isPasswordEmpty ? _('Please create a new password.') : '';
		hashPassOpt.cfgvalue = function(section_id) {
			return '';
		};

		const redirectOpt = mainSect.taboption(
			'dns_redirect',
			form.ListValue,
			'redirect',
			`${dnsPort} ` + _('Redirect'),
			_('AdGuardHome redirect mode')
		);
		redirectOpt.value('none', _('No redirect'));
		redirectOpt.value('dnsmasq-upstream', _('As the upstream server of dnsmasq'));
		redirectOpt.value('redirect', _('Redirect port 53 to AdGuardHome'));
		redirectOpt.value('exchange', _('Use port 53 to replace dnsmasq'));
		redirectOpt.default = 'none';
		redirectOpt.rmempty = false;

		const coreVersionOpt = mainSect.taboption(
			'core_update',
			form.ListValue,
			'core_version',
			_('Core Branch'),
			_('Select the branch for the core binary update.')
		);
		coreVersionOpt.value('latest', _('Latest Version'));
		coreVersionOpt.value('beta', _('Beta Version'));
		coreVersionOpt.default = 'latest';
		coreVersionOpt.depends('enable_core_update', '1');
		coreVersionOpt.retain = true;

		const coreUrlOpt = mainSect.taboption(
			'core_update',
			form.ListValue,
			'update_url',
			_('Update URL'),
			_('Select the download link for the core update.')
		);
		coreUrlOpt.value('https://static.adtidy.org/adguardhome/release/AdGuardHome_linux_${Arch}.tar.gz', _('Official Mirror (AdTidy - Recommended)'));
		coreUrlOpt.value('https://github.com/AdguardTeam/AdGuardHome/releases/download/${Cloud_Version}/AdGuardHome_linux_${Arch}.tar.gz', _('GitHub Releases (Original)'));
		coreUrlOpt.default = 'https://static.adtidy.org/adguardhome/release/AdGuardHome_linux_${Arch}.tar.gz';
		coreUrlOpt.rmempty = false;
		coreUrlOpt.depends('enable_core_update', '1');
		coreUrlOpt.retain = true;

		const updateActionOpt = mainSect.taboption(
			'core_update',
			form.DummyValue,
			'_update_action',
			_('Action')
		);
		updateActionOpt.rawhtml = true;
		updateActionOpt.cfgvalue = () => `
			<div id="agh-update-controls" style="display: flex; gap: 10px; margin-bottom: 10px;">
				<button class="btn cbi-button cbi-button-apply" type="button" id="btn-agh-update">${_('Update core version')}</button>
				<button class="btn cbi-button cbi-button-apply" type="button" id="btn-agh-force" style="display: none;">${_('Force update')}</button>
			</div>
			<div id="agh-update-log-container" style="display: none;">
				<textarea id="agh-update-log" class="cbi-input-textarea" style="width: 100%; display: block; font-family: monospace;" rows="10" readonly="readonly"></textarea>
			</div>
		`;
		updateActionOpt.depends('enable_core_update', '1');

		const rendered = await map.render();

		const logContainer = rendered.querySelector('#agh-log-container');
		if (logContainer) {
			const logField = logContainer.closest('.cbi-value-field');
			const logRow = logContainer.closest('.cbi-value');
			const logTitle = logRow?.querySelector('.cbi-value-title');

			if (logRow) {
				logRow.classList.add('agh-log-value');
				logRow.style.display = 'block';
				logRow.style.width = '100%';
				logRow.style.maxWidth = 'none';
			}

			if (logTitle)
				logTitle.style.display = 'none';

			if (logField) {
				logField.style.display = 'block';
				logField.style.width = '100%';
				logField.style.maxWidth = 'none';
				logField.style.paddingLeft = '0';
				logField.style.paddingRight = '0';
			}

			logContainer.style.width = '100%';
			logContainer.style.maxWidth = 'none';
		}

		const logArea = rendered.querySelector('#agh-syslog');
		const refreshLogButton = rendered.querySelector('#btn-agh-log-refresh');
		let logLoading = false;

		const loadLogs = async () => {
			if (!logArea || logLoading)
				return;

			logLoading = true;
			try {
				const text = await fs.exec_direct('/sbin/logread', ['-e', 'AdGuardHome']);
				const lines = text.trim()
					? text.trim().split(/\n/).reverse().slice(0, 50)
					: [];

				logArea.value = lines.join('\n');
				logArea.scrollTop = 0;
			} catch (e) {
				console.error(e);
				logArea.value = _('Unable to load log data: ') + e.message;
			} finally {
				logLoading = false;
			}
		};

		const refreshLogs = async () => {
			if (refreshLogButton)
				refreshLogButton.disabled = true;

			await loadLogs();

			if (refreshLogButton)
				refreshLogButton.disabled = false;
		};

		if (refreshLogButton)
			refreshLogButton.addEventListener('click', refreshLogs);

		refreshLogs();

		poll.add(() => {
			if (logArea && document.body.contains(logArea))
				loadLogs();
		}, POLL_INTERVAL);

		const statusNode = map.findElement('data-field', statusOpt.cbid('status_section'));
		poll.add(updateStatus(statusNode), POLL_INTERVAL);

		// ========== Update status and polling logic ==========
		let updatePollId = null;

		function startLogPolling() {
			if (updatePollId) clearInterval(updatePollId);

			//
			// FIX: the first pollAction tick used to run before rpcd had
			// even spawned the script, so no state/done/error file existed
			// and the UI immediately showed "Already up-to-date" and
			// stopped polling.  We now wait for /var/run/update_core to
			// appear (up to 15s) before making any verdict.
			//
			let stateSeen = false;
			let startTime = Date.now();

			const pollAction = () => {
				const btnU = document.getElementById('btn-agh-update');
				const btnF = document.getElementById('btn-agh-force');
				const logC = document.getElementById('agh-update-log-container');
				const logT = document.getElementById('agh-update-log');

				if (btnU) btnU.disabled = true;
				if (btnF) btnF.style.display = 'inline-block';
				if (logC) logC.style.display = 'block';

				fs.read('/tmp/AdGuardHome_update.log').then((txt) => {
					if (txt && logT) {
						logT.value = txt;
						logT.scrollTop = logT.scrollHeight;
					}
				}).catch(() => {});

				Promise.all([
					fs.stat('/var/run/update_core').catch(() => null),
					fs.stat('/var/run/update_core_done').catch(() => null),
					fs.stat('/var/run/update_core_error').catch(() => null)
				]).then(([isCore, isDone, isError]) => {
					if (isCore) {
						stateSeen = true;
						return;
					}

					if (isDone) {
						clearInterval(updatePollId);
						fs.remove('/var/run/update_core_done').catch(() => {});
						if (btnU) {
							btnU.disabled = false;
							btnU.textContent = _('Updated');
						}
					} else if (isError) {
						clearInterval(updatePollId);
						if (btnU) {
							btnU.disabled = false;
							btnU.textContent = _('Failed');
						}
					} else if (stateSeen) {
						// State file was visible and has now been cleaned
						// up by the script itself: treat as finished.
						clearInterval(updatePollId);
						if (btnU) {
							btnU.disabled = false;
							btnU.textContent = _('Already up-to-date');
						}
					} else if (Date.now() - startTime > 15000) {
						// Never saw the state file at all: the spawn likely
						// failed (ACL, missing script, ...).  Stop polling
						// and surface it instead of spinning forever.
						clearInterval(updatePollId);
						if (btnU) {
							btnU.disabled = false;
							btnU.textContent = _('Failed');
						}
						if (logT) {
							logT.value += _('\n[LuCI] Update task did not start within 15 seconds. Check the rpcd ACL and system log.\n');
						}
					}
					// else: keep waiting for the state file to appear.
				});
			};

			pollAction();
			updatePollId = setInterval(pollAction, 1500);
		}

		function applyUpdate(isForce) {
			const btnU = document.getElementById('btn-agh-update');
			const logC = document.getElementById('agh-update-log-container');
			const logT = document.getElementById('agh-update-log');
			if (btnU) {
				btnU.textContent = _('Checking...');
				btnU.disabled = true;
			}
			
			if (logC) logC.style.display = 'block';
			if (logT) logT.value = _('Checking and preparing...\n');
			
			map.save().then(() => {
				const arg = isForce ? 'force' : '';
				fs.exec('/usr/share/AdGuardHome/update_core.sh', [arg]).catch((err) => {
					console.error('Failed to trigger update script:', err);
				});
				startLogPolling();
			}).catch((err) => {
				console.error('Config save failed:', err);
				if (btnU) {
					btnU.textContent = _('Save Failed');
					btnU.disabled = false;
				}
			});
		}

		rendered.addEventListener('click', (e) => {
			if (e.target && e.target.id === 'btn-agh-update') {
				e.preventDefault();
				applyUpdate(false);
			} else if (e.target && e.target.id === 'btn-agh-force') {
				e.preventDefault();
				applyUpdate(true);
			} 
			else if (e.target && e.target.id === 'btn-agh-calc-hash') {
				e.preventDefault();
				const btn = e.target;

				const inputs = rendered.querySelectorAll('input[type="text"], input[type="password"]');
				let passInput = null;
				for (const el of inputs) {
					if (el.id && el.id.endsWith('.hashpass')) {
						passInput = el;
						break;
					}
				}

				if (!passInput) return;

				if (typeof window.TwinBcrypt === 'undefined') {
					btn.disabled = true;
					btn.textContent = _('Loading...');
					
					const script = document.createElement('script');
					script.src = L.resource('view/adguardhome/twin-bcrypt.min.js');
					script.type = 'text/javascript';
					
					script.onload = () => {
						btn.textContent = _('Click here to Calculate');
						btn.disabled = false;
					};
					script.onerror = () => {
						btn.textContent = _('... Load Error ...');
						btn.disabled = false;
					};
					document.head.appendChild(script);
				} 
				else {
					if (passInput.value) {
						if (passInput.value.startsWith('$2a$') || passInput.value.startsWith('$2y$')) {
							btn.textContent = _('Calculation already DONE !');
							return;
						}
						
						const hash = window.TwinBcrypt.hashSync(passInput.value);
						passInput.value = hash;
						
						passInput.dispatchEvent(new Event('input', { bubbles: true }));
						passInput.dispatchEvent(new Event('change', { bubbles: true }));
						
						btn.textContent = _('... Click Save/Apply ↘️ ...');
					} else {
						btn.textContent = _('... Nothing inputted yet ...');
					}
				}
			}
		});

		Promise.all([
			fs.stat('/var/run/update_core').catch(() => null),
			fs.stat('/var/run/update_core_error').catch(() => null)
		]).then(([isCore, isError]) => {
			if (isCore || isError) {
				const btnU = document.getElementById('btn-agh-update');
				if (btnU) btnU.textContent = _('Checking...');
				startLogPolling();
			}
		});

		return rendered;
	},
});
