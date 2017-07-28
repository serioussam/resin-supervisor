Promise = require 'bluebird'
_ = require 'lodash'
Lock = require 'rwlock'
EventEmitter = require 'events'
fs = Promise.promisifyAll(require('fs'))

containerConfig = require './lib/container-config'
constants = require './lib/constants'
validation = require './lib/validation'
conversions = require './lib/conversions'

DeviceConfig = require './device-config'
Logger = require './logger'
ApplicationManager = require './application-manager'


validateLocalState = (state) ->
	if state.name? and !validation.isValidShortText(state.name)
		throw new Error('Invalid device name')
	if state.apps? and !validation.isValidAppsArray(state.apps)
		throw new Error('Invalid apps')
	if state.config? and !validation.isValidEnv(state.config)
		throw new Error('Invalid device configuration')

validateDependentState = (state) ->
	if state.apps? and !validation.isValidDependentAppsObject(state.apps)
		throw new Error('Invalid dependent apps')
	if state.devices? and !validation.isValidDependentDevicesObject(state.devices)
		throw new Error('Invalid dependent devices')

validateState = Promise.method (state) ->
	validateLocalState(state.local) if state.local?
	validateDependentState(state.dependent) if state.dependent?

UPDATE_IDLE = 0
UPDATE_UPDATING = 1
UPDATE_REQUIRED = 2
UPDATE_SCHEDULED = 3

module.exports = class DeviceState extends EventEmitter
	constructor: ({ @db, @config, @eventTracker, @apiBinder }) ->
		@logger = new Logger({ @eventTracker })
		@deviceConfig = new DeviceConfig({ @db, @config, @logger })
		@application = new ApplicationManager({ @config, @logger, @db, @reportCurrentState })
		@on 'error', (err) ->
			console.error('Error in deviceState: ', err, err.stack)
		@_currentVolatile = {}
		_lock = new Lock()
		@_writeLock = Promise.promisify(_lock.async.writeLock)
		@_readLock = Promise.promisify(_lock.async.writeLock)
		@lastSuccessfulUpdate = null
		@failedUpdates = 0

	normalizeLegacy: ({ apps, dependentApps }) =>
		# Old containers have to be killed as we can't update their labels
		@application.killAll()
		.then =>
			Promise.map apps, (app) =>
				@application.images.get(app.imageId)
				.then =>
					@application.images.markAsSupervised(app.imageId)
				.catch ->
					console.error("Ignoring non-available legacy image #{app.imageId}")
		.then =>
			Promise.map dependentApps, (app) =>
				@proxyvisor.images.get(app.imageId)
				.then =>
					@proxyvisor.images.markAsSupervised(app.imageId)
				.catch ->
					console.error("Ignoring non-available legacy dependent image #{app.imageId}")

	init: ->
		@config.getMany([ 'logsChannelSecret', 'pubnub', 'offlineMode', 'loggingEnabled' ])
		.then (conf) =>
			@logger.init({
				pubnub: conf.pubnub
				channel: "device-#{conf.logsChannelSecret}-logs"
				offlineMode: !conf.offlineMode
				enable: conf.loggingEnabled
			})
		.then =>
			@config.on 'change', (changedConfig) =>
				@logger.enable(changedConfig.loggingEnabled) if changedConfig.loggingEnabled?
		.then =>
			@application.init()
		#.then =>
		#	@proxyvisor.init()


	emitAsync: (ev, args) =>
		setImmediate => @emit(ev, args)

	readLockTarget: =>
		@_readLock('target').disposer (release) ->
			release()
	writeLockTarget: =>
		@_writeLock('target').disposer (release) ->
			release()
	writeLockApply: =>
		@_writeLock('apply').disposer (release) ->
			release()

	setTarget: (target) ->
		validateState(target)
		.then =>
			Promise.using @writeLockTarget(), =>
				# Apps, deviceConfig, dependent
				@db.transaction (trx) =>
					Promise.try =>
						@config.set({ name: target.local.name }, trx) if target.local?.name?
					.then =>
						@deviceConfig.setTarget(target.local.config, trx) if target.local?.config?
					.then =>
						if target.local?.apps?
							appsForDB = _.map target.local.apps, (app) ->
								conversions.appStateToDB(app)
							Promise.map appsForDB, (app) =>
								@db.upsertModel('app', app, { appId: app.appId }, trx)
							.then ->
								trx('app').whereNotIn('appId', _.map(appsForDB, 'appId')).del()
					.then =>
						if target.local?.volumes
							Promise.map target.local.volumes, (config, name) =>
								@db.upsertModel('volume', { config, name }, { name }, trx)
							.then ->
								trx('volume').whereNotIn('name', _.keys(target.local.volumes)).del()
					.then =>
						if target.local?.networks
							Promise.map target.local.networks, (config, name) =>
								@db.upsertModel('network', { config, name }, { name }, trx)
							.then ->
								trx('network').whereNotIn('name', _.keys(target.local.networks)).del()
					.then =>
						if target.dependent?.apps?
							appsForDB = _.map target.local.apps, (app) ->
								conversions.dependentAppStateToDB(app)
							Promise.map appsForDB, (app) =>
								@db.upsertModel('dependentAppTarget', app, { appId: app.appId }, trx)
							.then ->
								trx('dependentAppTarget').whereNotIn('appId', _.map(appsForDB, 'appId')).del()
					.then =>
						if target.dependent?.devices?
							devicesForDB = _.map target.dependent.devices, (app) ->
								conversions.dependentDeviceTargetStateToDB(app)
							Promise.map devicesForDB, (device) =>
								@db.upsertModel('dependentDeviceTarget', device, { uuid: device.uuid }, trx)
							.then ->
								trx('dependentDeviceTarget').whereNotIn('uuid', _.map(devicesForDB, 'uuid')).del()

	# BIG TODO: correctly include dependent apps/devices
	getTarget: ->
		Promise.using @readLockTarget(), =>
			Promise.props({
				local: Promise.props({
					name: @config.get('name')
					config: @deviceConfig.getTarget()
					apps: @db.models('app').select().map(conversions.appDBToState)
					networks: @db.models('network').select().then (networks) ->
						_.mapValues(_.keyBy(networks, 'name'), (net) -> net.config )
					volumes: @db.models('volume').select().then (volumes) ->
						_.mapValues(_.keyBy(volumes, 'name'), (v) -> v.config )
				})
				dependent: Promise.props({
					apps: @db.models('dependentAppTarget').select().map(conversions.dependentAppDBToState)
					devices: @db.models('dependentDeviceTarget').select().map(conversions.dependentDeviceTargetDBToState)
				})
			})

	getCurrent: ->
		Promise.join(
			@config.get('name')
			@deviceConfig.getCurrent()
			@application.getStatus()
			@application.getDependentState()
			(name, devConfig, apps, dependent) ->
				return {
					local: {
						name
						config: devConfig
						apps
					}
					dependent
				}
		)

	reportCurrentState: (newState = {}) ->
		_.assign(@_currentVolatile, newState)
		@emitAsync('current-state-change')

	loadTargetFromFile: (appsPath) ->
		appsPath ?= constants.appsJsonPath
		fs.readFileAsync(appsPath, 'utf8')
		.then(JSON.parse)
		.then (stateFromFile) =>
			@setTarget({
				local: stateFromFile
			})
		.catch (err) =>
			@eventTracker.track('Loading preloaded apps failed', { error: err })

	# Triggers an applyTarget call immediately (but asynchronously)
	triggerApplyTarget: (opts) ->
		setImmediate =>
			@applyTarget(opts)

	# Aligns the current state to the target state
	applyTarget: ({ force = false } = {}) =>
		Promise.using @writeLockApply(), =>
			@getTarget()
			.then (target) =>
				@deviceConfig.applyTarget()
				.then =>
					@application.applyTarget(target.local?.apps, { force })
				.then =>
					@proxyvisor.applyTarget(target.dependent)
			.then =>
				@failedUpdates = 0
				@lastSuccessfulUpdate = Date.now()
				@reportCurrent(update_failed: false)
				# We cleanup here as we want a point when we have a consistent apps/images state, rather than potentially at a
				# point where we might clean up an image we still want.
				@emitAsync('apply-target-state-success')
			.catch (err) =>
				@failedUpdates++
				@reportCurrent(update_failed: true)
				@emitAsync('apply-target-state-error', err)
