Promise = require 'bluebird'
_ = require 'lodash'
Lock = require 'rwlock'
EventEmitter = require 'events'
fs = Promise.promisifyAll(require('fs'))
express = require 'express'
bodyParser = require 'body-parser'

constants = require './lib/constants'
validation = require './lib/validation'
device = require './lib/device'
updateLock = require './lib/update-lock'

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
	if state.apps? and !validation.isValidDependentAppsArray(state.apps)
		throw new Error('Invalid dependent apps')
	if state.devices? and !validation.isValidDependentDevicesArray(state.devices)
		throw new Error('Invalid dependent devices')

validateState = Promise.method (state) ->
	validateLocalState(state.local) if state.local?
	validateDependentState(state.dependent) if state.dependent?

class DeviceStateRouter
	constructor: (@deviceState) ->
		{ @application } = @deviceState
		@router = express.Router()
		@router.use(bodyParser.urlencoded(extended: true))
		@router.use(bodyParser.json())

		@router.post '/v1/reboot', (req, res) =>
			force = validation.checkTruthy(req.body.force)
			@deviceState.executeStepAction({ action: 'reboot' }, { force })
			.then (response) ->
				res.status(202).json(response)
			.catch (err) ->
				if err instanceof updateLock.UpdatesLockedError
					status = 423
				else
					status = 500
				res.status(status).json({ Data: '', Error: err?.message or err or 'Unknown error' })

		@router.post '/v1/shutdown', (req, res) =>
			force = validation.checkTruthy(req.body.force)
			@deviceState.executeStepAction({ action: 'shutdown' }, { force })
			.then (response) ->
				res.status(202).json(response)
			.catch (err) ->
				if err instanceof updateLock.UpdatesLockedError
					status = 423
				else
					status = 500
				res.status(status).json({ Data: '', Error: err?.message or err or 'Unknown error' })

		@router.use(@application.router)

module.exports = class DeviceState extends EventEmitter
	constructor: ({ @db, @config, @eventTracker }) ->
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
		@stepsInProgress = []
		@applyInProgress = false
		@scheduledApply = null
		@applyContinueScheduled = false
		@shuttingDown = false
		@_router = new DeviceStateRouter(this)
		@router = @_router.router
		@on 'apply-target-state-end', (err) ->
			if err?
				console.log("Apply error #{err}")
			else
				console.log('Apply success!')
		@on 'step-completed', (err) ->
			if err?
				console.log("Step completed with error #{err}")
			else
				console.log('Step success!')
		@on 'step-error', (err) ->
			console.log("Step error #{err}")

	# TODO: migrate /data?
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
				offlineMode: conf.offlineMode
				enable: conf.loggingEnabled
			})
		.then =>
			@config.on 'change', (changedConfig) =>
				@logger.enable(changedConfig.loggingEnabled) if changedConfig.loggingEnabled?
		.then =>
			@application.init()

	emitAsync: (ev, args) =>
		setImmediate => @emit(ev, args)

	readLockTarget: =>
		@_readLock('target').disposer (release) ->
			release()
	writeLockTarget: =>
		@_writeLock('target').disposer (release) ->
			release()
	inferStepsLock: =>
		@_writeLock('inferSteps').disposer (release) ->
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
						@application.setTarget(target.local?.apps, target.dependent, trx)

	# BIG TODO: correctly include dependent apps/devices
	getTarget: ->
		Promise.using @readLockTarget(), =>
			Promise.props({
				local: Promise.props({
					name: @config.get('name')
					config: @deviceConfig.getTarget()
					apps: @application.getTargetApps()
				})
				dependent: @application.getDependentTargets()
			})

	# TODO: adapt to what we will report on the v2 endpoint (use all apps and services)
	getCurrentForReport: ->
		@application.getStatus()
		.then (apps) =>
			theApp = apps[0] ? {}
			theState = {}
			_.merge(theState, @_currentVolatile)
			theState.buildId = theApp.buildId
			theState.commit = theApp.commit
			return theState

	getCurrentForComparison: ->
		Promise.join(
			@config.get('name')
			@deviceConfig.getCurrent()
			@application.getCurrentForComparison()
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

	reportCurrentState: (newState = {}) =>
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

	reboot: (force) =>
		@application.stopAll({ force })
		.then =>
			@logger.logSystemMessage('Rebooting', {}, 'Reboot')
			device.reboot()
			.tap =>
				@emit('shutdown')

	shutdown: (force) =>
		@application.stopAll({ force })
		.then =>
			@logger.logSystemMessage('Shutting down', {}, 'Shutdown')
			device.shutdown()
			.tap =>
				@shuttingDown = true
				@emitAsync('shutdown')

	executeStepAction: (step, { force, targetState }) =>
		Promise.try =>
			if _.includes(@deviceConfig.validActions, step.action)
				@deviceConfig.executeStepAction(step)
			else if _.includes(@application.validActions, step.action)
				@application.executeStepAction(step, { force, targetState })
			else
				switch step.action
					when 'reboot'
						@reboot(force)
					when 'shutdown'
						@shutdown(force)
					when 'noop'
						Promise.resolve()
					else
						throw new Error("Invalid action #{step.action}")

	applyStepAsync: (step, { force, targetState }) =>
		return if @shuttingDown
		@stepsInProgress.push(step)
		setImmediate =>
			@executeStepAction(step, { force, targetState })
			.finally =>
				Promise.using @inferStepsLock(), =>
					_.pullAllWith(@stepsInProgress, [ step ], _.isEqual)
			.then (stepResult) =>
				@emitAsync('step-completed', null, step, stepResult)
				@continueApplyTarget({ force })
			.catch (err) =>
				@emitAsync('step-error', err, step)
				@applyError(err, force)

	applyError: (err, force) =>
		@_applyingSteps = false
		@applyInProgress = false
		@failedUpdates += 1
		@reportCurrentState(update_failed: true)
		if @scheduledApply?
			console.log('Updating failed, but there is already another update scheduled immediately: ', err)
		else
			delay = Math.min((2 ** @failedUpdates) * 500, 30000)
			# If there was an error then schedule another attempt briefly in the future.
			console.log('Scheduling another update attempt due to failure: ', delay, err)
			@triggerApplyTarget({ force, delay })
		@emitAsync('apply-target-state-error', err)
		@emitAsync('apply-target-state-end', err)

	applyTarget: ({ force = false } = {}) =>
		console.log('Applying target state')
		Promise.using @inferStepsLock(), =>
			Promise.join(
				@getCurrentForComparison()
				@getTarget()
				(currentState, targetState) =>
					@deviceConfig.getRequiredSteps(currentState, targetState, @stepsInProgress)
					.then (deviceConfigSteps) =>
						if !_.isEmpty(deviceConfigSteps)
							return deviceConfigSteps
						else
							@application.getRequiredSteps(currentState, targetState, @stepsInProgress)
			)
			.then (steps) =>
				if _.isEmpty(steps) and _.isEmpty(@stepsInProgress)
					console.log('Finished applying target state')
					@applyInProgress = false
					@failedUpdates = 0
					@lastSuccessfulUpdate = Date.now()
					@reportCurrentState(update_failed: false)
					@emitAsync('apply-target-state-success', null)
					@emitAsync('apply-target-state-end', null)
					return
				@reportCurrentState(update_pending: true)
				Promise.map steps, (step) =>
					@applyStepAsync(step, { force })
		.catch (err) =>
			@applyError(err, force)

	continueApplyTarget: ({ force = false } = {}) =>
		return if @applyContinueScheduled
		@applyContinueScheduled = true
		setTimeout( =>
			@applyContinueScheduled = false
			@applyTarget({ force })
		, 1000)
		return

	triggerApplyTarget: ({ force = false, delay = 0 } = {}) =>
		if @applyInProgress
			if !@scheduledApply?
				@scheduledApply = { force, delay }
				@once 'apply-target-state-end', =>
					@triggerApplyTarget(@scheduledApply)
					@scheduledApply = null
			else
				# If a delay has been set it's because we need to hold off before applying again,
				# so we need to respect the maximum delay that has been passed
				@scheduledApply.delay = Math.max(delay, @scheduledApply.delay)
				@scheduledApply.force or= force
			return
		@applyInProgress = true
		setTimeout( =>
			@applyTarget({ force })
		, delay)
		return
