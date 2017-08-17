Promise = require 'bluebird'
_ = require 'lodash'
url = require 'url'
semver = require 'semver'
semverRegex = require 'semver-regex'
TypedError = require 'typed-error'
PlatformAPI = require 'pinejs-client'
deviceRegister = require 'resin-register-device'
express = require 'express'
bodyParser = require 'body-parser'
Lock = require 'rwlock'
{ request, requestOpts } = require './lib/request'

DuplicateUuidError = message: '"uuid" must be unique.'
ExchangeKeyError = class ExchangeKeyError extends TypedError

REPORT_SUCCESS_DELAY = 1000
REPORT_RETRY_DELAY = 5000

hasDeviceApiKeySupport = (osVersion) ->
	try
		osSemver = semverRegex().exec(osVersion)[0]
		!/^Resin OS /.test(osVersion) or semver.gte(osSemver, '2.0.2')
	catch err
		console.error(osVersion)
		console.error('Unable to determine if device has deviceApiKey support', err, err.stack)
		false

class APIBinderRouter
	constructor: (@apiBinder) ->
		{ @eventTracker } = @apiBinder
		@router = express.Router()
		@router.use(bodyParser.urlencoded(extended: true))
		@router.use(bodyParser.json())
		@router.post '/v1/update', (req, res) =>
			@eventTracker.track('Update notification')
			setImmediate =>
				if @apiBinder.readyForUpdates
					@apiBinder.getAndSetTargetState(req.body.force)
			res.sendStatus(204)

module.exports = class APIBinder
	constructor: ({ @config, @db, @deviceState, @eventTracker }) ->
		@resinApi = null
		@cachedResinApi = null
		@lastReportedState = {}
		@stateForReport = {}
		@lastTarget = {}
		@_targetStateInterval = null
		@reportPending = false
		@_router = new APIBinderRouter(this)
		@router = @_router.router
		_lock = new Lock()
		@_writeLock = Promise.promisify(_lock.async.writeLock)
		@readyForUpdates = false

	_lockGetTarget: =>
		@_writeLock('getTarget').disposer (release) ->
			release()

	init: (startServices = true) ->
		@config.getMany([ 'offlineMode', 'resinApiEndpoint' ])
		.then ({ offlineMode, resinApiEndpoint }) =>
			if offlineMode
				console.log('Offline Mode is set, skipping API binder initialization')
				return
			baseUrl = url.resolve(resinApiEndpoint, '/v2/')
			@resinApi = new PlatformAPI
				apiPrefix: baseUrl
				passthrough: requestOpts
			@cachedResinApi = @resinApi.clone({}, cache: {})
			return if !startServices
			console.log('Ensuring device is provisioned')
			@provisionDevice()
			.then =>
				@config.get('initialConfigReported')
				.then (reported) =>
					if !reported
						console.log('Reporting initial configuration')
						@reportInitialConfig()
			.then =>
				console.log('Starting current state report')
				@startCurrentStateReport()
			.then =>
				@readyForUpdates = true
				console.log('Starting target state poll')
				@startTargetStatePoll()
			return

	fetchDevice: (uuid, apiKey, timeout) =>
		@resinApi.get
			resource: 'device'
			options:
				filter:
					uuid: uuid
			customOptions:
				apikey: apiKey
		.get(0)
		.catchReturn(null)
		.timeout(timeout)

	_exchangeKeyAndGetDevice: (opts) ->
		Promise.try =>
			# If we have an existing device key we first check if it's valid, because if it is we can just use that
			if opts.deviceApiKey?
				@fetchDevice(opts.uuid, opts.deviceApiKey, opts.apiTimeout)
		.then (device) =>
			if device?
				return device
			# If it's not valid/doesn't exist then we try to use the user/provisioning api key for the exchange
			@fetchDevice(opts.uuid, opts.provisioningApiKey, opts.apiTimeout)
			.then (device) ->
				if not device?
					throw new ExchangeKeyError("Couldn't fetch device with provisioning key")
				# We found the device, we can try to register a working device key for it
				request.postAsync("#{opts.apiEndpoint}/api-key/device/#{device.id}/device-key?apikey=#{opts.provisioningApiKey}", {
					json: true
					body:
						apiKey: opts.deviceApiKey
				})
				.spread (res, body) ->
					if res.statusCode != 200
						throw new ExchangeKeyError("Couldn't register device key with provisioning key")
				.timeout(opts.apiTimeout)
				.return(device)

	_exchangeKeyAndGetDeviceOrRegenerate: (opts) =>
		@_exchangeKeyAndGetDevice(opts)
		.tap ->
			console.log('Key exchange succeeded, all good')
		.tapCatch ExchangeKeyError, (err) =>
			# If it fails we just have to reregister as a provisioning key doesn't have the ability to change existing devices
			console.log('Exchanging key failed, having to reregister')
			@config.regenerateRegistrationFields()

	_provision: =>
		@config.get('provisioningOptions')
		.then (opts) =>
			Promise.try ->
				if opts.registered_at? && !opts.deviceId?
					console.log('Device is registered but no device id available, attempting key exchange')
					@_exchangeKeyAndGetDeviceOrRegenerate(opts)
				else
					deviceRegister.register(opts)
					.timeout(opts.apiTimeout)
					.catch DuplicateUuidError, =>
						console.log('UUID already registered, trying a key exchange')
						@_exchangeKeyAndGetDeviceOrRegenerate(opts)
					.tap ->
						opts.registered_at = Date.now()
			.then ({ id }) =>
				opts.deviceId = id
				@config.get('osVersion')
			.then (osVersion) =>
				configToUpdate = {
					registered_at: opts.registered_at
					deviceId: opts.deviceId
				}
				# Delete the provisioning key now, only if the OS supports it
				hasSupport = hasDeviceApiKeySupport(osVersion)
				if hasSupport
					configToUpdate.apiKey = null
				else
					configToUpdate.apiKey = opts.deviceApiKey
				@config.set(configToUpdate)
		.then =>
			@eventTracker.track('Device bootstrap success')

	_provisionOrRetry: (retryDelay) =>
		@eventTracker.track('Device bootstrap')
		@_provision()
		.catch (err) =>
			@eventTracker.track('Device bootstrap failed, retrying', { error: err, delay: retryDelay })
			Promise.delay(retryDelay).then =>
				@_provisionOrRetry(retryDelay)

	provisionDevice: =>
		throw new Error('Trying to provision device without initializing API client') if !@resinApi?
		@config.getMany([
			'provisioned'
			'bootstrapRetryDelay'
		])
		.tap (conf) =>
			if !conf.provisioned
				console.log('New device detected. Bootstrapping..')
				@_provisionOrRetry(conf.bootstrapRetryDelay)
		.tap =>
			@config.getMany([ 'apiKey', 'deviceApiKey'])
			.then ({ apiKey, deviceApiKey }) =>
				if apiKey?
					# Only do a key exchange and delete the provisioning key if we're on a Resin OS version
					# that supports using the deviceApiKey (2.0.2 and above)
					# or if we're in a non-Resin OS (which is assumed to be updated enough).
					# Otherwise VPN and other host services that use an API key will break.
					#
					# In other cases, we make the apiKey equal the deviceApiKey instead.
					@config.get('osVersion')
					.then (osVersion) =>
						hasSupport = hasDeviceApiKeySupport(osVersion)
						if hasSupport or apiKey != deviceApiKey
							console.log('Attempting key exchange')
							@_exchangeKeyAndGetDevice()
							.then =>
								console.log('Key exchange succeeded, starting to use deviceApiKey')
								if hasSupport
									apiKey = null
								else
									apiKey = deviceApiKey
								@config.set({ apiKey })
					.catch (err) ->
						console.error('Error exchanging keys, will ignore since device is already provisioned', err, err.stack)

	provisionDependentDevice: (device) =>
		@config.getMany([
			'offlineMode'
			'provisioned'
			'currentApiKey'
			'apiTimeout'
			'userId'
			'deviceId'
		])
		.then (conf) =>
			throw new Error('Cannot provision dependent device in offline mode') if conf.offlineMode
			throw new Error('Device must be provisioned to provision a dependent device') if !conf.provisioned
			# TODO: when API supports it as per https://github.com/resin-io/hq/pull/949 remove userId
			_.defaults(device, {
				user: conf.userId
				device: conf.deviceId
				uuid: deviceRegister.generateUniqueKey()
				logsChannel: deviceRegister.generateUniqueKey()
				registered_at: Math.floor(Date.now() / 1000)
				status: 'Provisioned'
			})
			@resinApi.post
				resource: 'device'
				body: device
				customOptions:
					apikey: conf.currentApiKey
			.timeout(conf.apiTimeout)

	patchDevice: (id, updatedFields) =>
		@config.getMany([
			'offlineMode'
			'provisioned'
			'currentApiKey'
			'apiTimeout'
		])
		.then (conf) =>
			throw new Error('Cannot update dependent device in offline mode') if conf.offlineMode
			throw new Error('Device must be provisioned to update a dependent device') if !conf.provisioned
			@resinApi.patch
				resource: 'device'
				id: id
				body: updatedFields
				customOptions:
					apikey: conf.currentApiKey
			.timeout(conf.apiTimeout)

	# TODO creates the necessary config vars in the API to match the current device state
	_reportInitialEnv: ->
		Promise.join(
			@deviceState.getCurrentForComparison()
			@getTargetState()
			(currentState, targetState) ->
				targetState.local.config
		)

	reportInitialConfig: (retryDelay) ->
		@_reportInitialEnv()
		.catch (err) ->
			console.error('Error reporting initial configuration, will retry')
			Promise.delay(retryDelay)
			.then =>
				@reportInitialConfig(retryDelay)

	# TODO: switch to v2 endpoint. For now this fetches from v1 and translates the returned state
	getTargetState: ->
		@config.getMany([ 'uuid', 'currentApiKey', 'resinApiEndpoint', 'apiTimeout' ])
		.then ({ uuid, currentApiKey, resinApiEndpoint, apiTimeout }) =>
			endpoint = url.resolve(resinApiEndpoint, "/device/v1/#{uuid}/state")

			requestParams = _.extend
				method: 'GET'
				url: "#{endpoint}?&apikey=#{currentApiKey}"
			, @cachedResinApi.passthrough

			@cachedResinApi._request(requestParams)
			.timeout(apiTimeout)
			.then (state) ->
				state.local ?= {}
				if !state.local.config?
					state.local.config ?= {}
					_.forEach state.local?.apps, (app) ->
						_.merge(state.local.config, app.config ? {})
				state.local.apps = _.map state.local.apps, (app, appId) ->
					newApp = {
						appId
						commit: app.commit
						name: app.name
						buildId: '1'
						networks: {}
						volumes: {}
						config: app.config ? {}
					}
					newApp.services = [
						{
							serviceId: '1'
							serviceName: 'main'
							containerId: '1'
							commit: app.commit
							buildId: app.buildId ? '1'
							image: app.image
							privileged: true
							networkMode: 'host'
							volumes: [
								"resin-data-#{appId}:/data"
							]
							labels: {
								'io.resin.features.kernel_modules': '1'
								'io.resin.features.firmware': '1'
								'io.resin.features.dbus': '1'
								'io.resin.features.supervisor_api': '1'
								'io.resin.features.resin_api': '1'
								'io.resin.update.strategy': newApp.config['RESIN_SUPERVISOR_UPDATE_STRATEGY'] ? 'download-then-kill'
								'io.resin.update.handover_timeout': newApp.config['RESIN_SUPERVISOR_HANDOVER_TIMEOUT'] ? ''
							}
							environment: app.environment ? {}
							restart: 'unless-stopped'
							running: true
						}
					]

					return newApp
				state.dependent ?= {}
				state.dependent.apps = _.map state.dependent.apps, (app, appId) ->
					app.appId = appId
					return app
				state.dependent.devices = _.map state.dependent.devices, (device, uuid) ->
					device.uuid = uuid
					return device
				return state

	# Get target state from API, set it on @deviceState and trigger a state application
	getAndSetTargetState: (force) =>
		Promise.using @_lockGetTarget(), =>
			@getTargetState()
			.then (targetState) =>
				if !_.isEqual(targetState, @lastTarget)
					console.log('Last Target:', JSON.stringify(@lastTarget))
					console.log('New Target:', JSON.stringify(targetState))
					@lastTarget = targetState
					@deviceState.setTarget(targetState)
					.then =>
						@deviceState.triggerApplyTarget({ force })
		.catch (err) ->
			console.error("Failed to get target state for device: #{err}")

	_pollTargetState: =>
		if @_targetStateInterval?
			clearInterval(@_targetStateInterval)
			@_targetStateInterval = null
		@config.get('appUpdatePollInterval')
		.then (appUpdatePollInterval) =>
			@_targetStateInterval = setInterval(@getAndSetTargetState, appUpdatePollInterval)
			@getAndSetTargetState()
			return

	startTargetStatePoll: ->
		throw new Error('Trying to start poll without initializing API client') if !@resinApi?
		@_pollTargetState()
		@config.on 'change', (changedConfig) =>
			@_pollTargetState() if changedConfig.appUpdatePollInterval?

	_getStateDiff: =>
		_.omitBy @stateForReport, (val, key) =>
			_.isEqual(@lastReportedState[key], val)

	# TODO: switch to using the proper endpoint, for now we use the PATCH /device endpoint
	_report: =>
		@config.getMany([ 'currentApiKey', 'deviceId', 'apiTimeout' ])
		.then (conf) =>
			stateDiff = @_getStateDiff()
			if _.size(stateDiff) is 0
				return

			fieldsToReport = [
				'ip_address'
				'status'
				'download_progress'
				'api_port'
				'api_secret'
				'os_version'
				'os_variant'
				'supervisor_version'
				'provisioning_progress'
				'provisioning_state'
				'logs_channel'
				'commit'
			]
			stateToReport = _.pick(stateDiff, fieldsToReport)
			@resinApi.patch
				resource: 'device'
				id: conf.deviceId
				body: stateToReport
				customOptions:
					apikey: conf.currentApiKey
			.timeout(conf.apiTimeout)
			.then =>
				_.merge(@lastReportedState, stateDiff)

	_reportCurrentState: =>
		console.log('reporting current state')
		@reportPending = true
		@deviceState.getCurrentForReport()
		.then (currentDeviceState) =>
			_.merge(@stateForReport, currentDeviceState)
			stateDiff = @_getStateDiff()
			if _.size(stateDiff) is 0
				console.log('report success!')
				@reportPending = false
				return
			@_report()
			.delay(REPORT_SUCCESS_DELAY)
			.then =>
				setImmediate(@_reportCurrentState)
		.catch (err) =>
			@eventTracker.track('Device state report failure', { error: err })
			Promise.delay(REPORT_RETRY_DELAY)
			.then =>
				setImmediate(@_reportCurrentState)

	startCurrentStateReport: =>
		throw new Error('Trying to start state reporting without initializing API client') if !@resinApi?
		# patch to the device(id) endpoint
		@deviceState.on 'current-state-change', =>
			if !@reportPending
				console.log('change!')
				@_reportCurrentState()
		@_reportCurrentState()
