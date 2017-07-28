EventEmitter = require 'events'

iptables = require './lib/iptables'
network = require './network'

EventTracker = require './event-tracker'
DB = require('./db')
Config = require('./config')
APIBinder = require('./api-binder')
DeviceState = require('./device-state')

module.exports = class Supervisor extends EventEmitter
	constructor: ->
		@db = new DB()
		@config = new Config({ @db })
		@eventTracker = new EventTracker()
		@apiBinder = new APIBinder({ @config, @db })
		@deviceState = new DeviceState({ @config, @db, @eventTracker, @apiBinder })

	normalizeState: =>
		@db.init()
		.then (needsMigration) =>
			# We're updating from an older supervisor, so we need to mark images as supervised and remove all containers
			if needsMigration
				@db.models('legacyData').select()
				.then ({ apps, dependentApps, dependentDevices }) =>
					@deviceState.normalizeLegacy({ apps, dependentApps, dependentDevices })
				.then =>
					@db.finishMigration()
		.then =>
			@config.init() # Ensures uuid, deviceApiKey, apiSecret and logsChannel

	init: =>
		@normalizeState()
		.then =>
			@config.getMany([
				'uuid'
				'listenPort'
				'version'
				'apiSecret'
				'logsChannelSecret'
				'provisioned'
				'resinApiEndpoint'
				'offlineMode'
				'mixpanelToken'
				'mixpanelHost'
				'username'
				'osVersion'
				'osVariant'
				'connectivityCheckEnabled'
			])
		.then (conf) =>
			@eventTracker.init({
				offlineMode: conf.offlineMode
				mixpanelToken: conf.mixpanelToken
				mixpanelHost: conf.mixpanelHost
				uuid: conf.uuid
			})
			.then =>
				@eventTracker.track('Supervisor start')
				@deviceState.init()
			.then =>
				network.startConnectivityCheck(conf.resinApiEndpoint, conf.connectivityCheckEnabled)
				@config.on 'change', (changedConfig) ->
					network.enableConnectivityCheck(changedConfig.connectivityCheckEnabled) if changedConfig.connectivityCheckEnabled?
				# Let API know what version we are, and our api connection info.
				console.log('Updating supervisor version and api info')
				@deviceState.reportCurrentState(
					api_port: conf.listenPort
					api_secret: conf.apiSecret
					os_version: conf.osVersion
					os_variant: conf.osVariant
					supervisor_version: conf.version
					provisioning_progress: null
					provisioning_state: ''
					download_progress: null
					logs_channel: conf.logsChannelSecret
				)
				.then =>
					console.log('Starting periodic check for IP addresses..')
					network.startIPAddressUpdate (addresses) =>
						@deviceState.reportCurrentState(
							ip_address: addresses.join(' ')
						)
				.then =>
					@deviceState.loadTargetFromFile() if !conf.provisioned
				.then =>
					@deviceState.init()
				.then =>
					@deviceState.applyAndFollowTarget()
				.then =>
					# initialize API
					console.log('Starting API server..')
					iptables.rejectOnAllInterfacesExcept(@config.constants.allowedInterfaces, conf.listenPort)
					.then ->
						#apiServer = api(application).listen(conf.listenPort)
						#apiServer.timeout = conf.apiTimeout
						#device.events.on 'shutdown', -> apiServer.close()
				.then =>
					@apiBinder.init() # this will first try to provision if it's a new device
