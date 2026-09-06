'use strict';

'require fs';
'require ui';
'require view';

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(fs.stat('/sbin/logread'), null),
			L.resolveDefault(fs.stat('/usr/sbin/logread'), null)
		]).then(([sbin, usrSbin]) => {
			const logger = sbin?.path || usrSbin?.path;

			if (!logger) {
				ui.addNotification(
					null,
					E('p', {}, _('Unable to load log data: logread not found.'))
				);
				return '';
			}

			return fs.exec_direct(logger, [
				'-e',
				'AdGuardHome'
			]).catch((err) => {
				ui.addNotification(
					null,
					E('p', {}, _('Unable to load log data: ') + err.message)
				);
				return '';
			});
		});
	},

	render(logdata) {
		const loglines = logdata.trim()
			? logdata.trim().split(/\n/).reverse().slice(0, 50)
			: [];

		return E([], [
			E('h2', {}, [
				_('System Log (AdGuard Home)')
			]),

			E('div', {}, [
				_('Showing last 50 lines')
			]),

			E('div', {
				'id': 'content_syslog'
			}, [
				E('textarea', {
					'id': 'syslog',
					'style': 'width: 100%; font-size: 12px; font-family: monospace;',
					'readonly': 'readonly',
					'wrap': 'off',
					'rows': Math.max(loglines.length + 1, 10)
				}, [
					loglines.join('\n')
				])
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
