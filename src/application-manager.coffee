Promise = require 'bluebird'
_ = require 'lodash'
fs = Promise.promisifyAll(require('fs'))
express = require 'express'
bodyParser = require 'body-parser'

conversions = require './lib/conversions'
constants = require './lib/constants'

process.env.DOCKER_HOST ?= "unix://#{constants.dockerSocket}"
Docker = require './lib/docker-utils'
updateLock = require './lib/update-lock'
{ checkTruthy, checkInt, checkString } = require './lib/validation'

Containers = require './docker/containers'
Images = require './docker/images'
Networks = require './docker/networks'
Volumes = require './docker/volumes'

Proxyvisor = require './proxyvisor'

class ApplicationManagerRouter
	constructor: (@application) ->
		{ @proxyvisor, @eventTracker } = @application
		@router = express.Router()
		@router.use(bodyParser.urlencoded(extended: true))
		@router.use(bodyParser.json())

		@router.post '/v1/restart', (req, res) =>
			appId = checkString(req.body.appId)
			force = checkTruthy(req.body.force)
			@eventTracker.track('Restart container (v1)', { appId })
			if !appId?
				return res.status(400).send('Missing app id')
			@application.getCurrentApp(appId)
			.then (app) ->
				service = app?.services?[0]
				return res.status(400).send('App not found') if !service?
				@application.executeStepAction({
					action: 'restart'
					current: service
					target: service
					serviceId: service.serviceId
				}, { force })
				.then ->
					res.status(200).send('OK')
			.catch (err) ->
				res.status(503).send(err?.message or err or 'Unknown error')

		@router.post '/v1/apps/:appId/stop', (req, res) =>
			appId = checkString(req.params.appId)
			force = checkTruthy(req.body.force)
			if !appId?
				return res.status(400).send('Missing app id')
			@application.getCurrentApp(appId)
			.then (app) ->
				service = app?.services?[0]
				return res.status(400).send('App not found') if !service?
				@application.setTargetVolatileForService(service.serviceId, running: false)
				@application.executeStepAction({
					action: 'stop'
					current: service
					serviceId: service.serviceId
				}, { force })
			.then (service) ->
				res.status(200).json({ containerId: service.dockerContainerId })
			.catch (err) ->
				res.status(503).send(err?.message or err or 'Unknown error')

		@router.post '/v1/apps/:appId/start', (req, res) =>
			appId = checkString(req.params.appId)
			force = checkTruthy(req.body.force)
			if !appId?
				return res.status(400).send('Missing app id')
			@application.getCurrentApp(appId)
			.then (app) ->
				service = app?.services?[0]
				return res.status(400).send('App not found') if !service?
				@application.setTargetVolatileForService(service.serviceId, running: false)
				@application.executeStepAction({
					action: 'start'
					target: service
					serviceId: service.serviceId
				}, { force })
			.then (service) ->
				res.status(200).json({ containerId: service.dockerContainerId })
			.catch (err) ->
				res.status(503).send(err?.message or err or 'Unknown error')

		@router.get '/v1/apps/:appId', (req, res) ->
			appId = checkString(req.params.appId)
			@eventTracker.track('GET app (v1)', appId)
			if !appId?
				return res.status(400).send('Missing app id')
			@application.getCurrentApp(appId)
			.then (app) ->
				service = app?.services?[0]
				return res.status(400).send('App not found') if !service?
				# Don't return data that will be of no use to the user
				appToSend = {
					appId
					containerId: service.dockerContainerId
					env: _.omit(service.environment, constants.privateAppEnvVars)
					commit: app.commit
					buildId: app.buildId
					imageId: service.image
				}
				res.json(appToSend)
			.catch (err) ->
				res.status(503).send(err?.message or err or 'Unknown error')

		@router.post '/v1/purge', (req, res) ->
			appId = checkString(req.body.appId)
			force = checkTruthy(req.body.force)
			if !appId?
				errMsg = "App not found: an app needs to be installed for purge to work.
						If you've recently moved this device from another app,
						please push an app and wait for it to be installed first."
				return res.status(400).send(errMsg)
			@application.getCurrentApp(appId)
			.then (app) ->
				service = app?.services?[0]
				return res.status(400).send('App not found') if !service?
				@application.executeStepAction({
					action: 'purge'
					current: service
					serviceId: service.serviceId
					options:
						removeFolder: false
						kill: true
						restart: true
						log: true
				}, { force })
				.then ->
					res.status(200).json(Data: 'OK', Error: '')
			.catch (err) ->
				res.status(503).send(err?.message or err or 'Unknown error')
		@router.use(@proxyvisor.router)

module.exports = class ApplicationManager
	constructor: ({ @logger, @config, @reportCurrentState, @db }) ->
		@docker = new Docker()
		@images = new Images({ @docker, @logger, @db, @reportServiceStatus })
		@containers = new Containers({ @docker, @logger, @images, @config, @reportServiceStatus })
		@networks = new Networks({ @docker, @logger })
		@volumes = new Volumes({ @docker, @logger })
		@proxyvisor = new Proxyvisor({ @config, @logger, @db, @docker, @images, @reportCurrentState })
		@volatileState = {}
		@_targetVolatilePerServiceId = {}
		@validActions = [
			'kill'
			'start'
			'stop'
			'fetch'
			'removeImage'
			'killAll'
			'purge'
			'restart'
			'cleanup'
			'createNetworkOrVolume'
			'removeNetworkOrVolume'
		].concat(@proxyvisor.validActions)
		@_router = new ApplicationManagerRouter(this)
		@globalAppStatus = {
			status: 'Idle'
			download_progress: null
		}
		@downloadsInProgress = 0
		@router = @_router.router

	reportServiceStatus: (serviceId, updatedStatus) =>
		if @downloadsInProgress > 0 and updatedStatus.download_progress?
			@globalAppStatus.download_progress = updatedStatus.download_progress / @downloadsInProgress
		if serviceId?
			@volatileState[serviceId] ?= {}
			_.assign(@volatileState[serviceId], updatedStatus)
		# TODO: aggregate download progress into device state download progress
		@reportCurrentState(@globalAppStatus)

	init: =>
		@containers.attachToRunning()
		.then =>
			@containers.listenToEvents()

	# Returns the status of applications and their services
	getStatus: =>
		@containers.getAll()
		.then (containers) =>
			apps = _.keyBy(_.map(_.uniq(_.map(containers, 'appId')), (appId) -> { appId }), 'appId')
			oldestContainer = {}
			# We iterate over the current running containers and add them to the current state
			# of the app they belong to.
			_.forEach containers, (container) =>
				appId = container.appId
				apps[appId].services ?= []
				# We use the oldest container in an app to define the current buildId and commit
				if !apps[appId].buildId? or container.createdAt < oldestContainer[appId]
					apps[appId].buildId = container.buildId
					apps[appId].commit = container.commit
					oldestContainer[appId] = container.createdAt

				service = _.pick(container, [ 'serviceId', 'containerId', 'status' ])
				# If there's volatile state relating to this service, we're either downloading
				# or installing it
				if @volatileState[container.serviceId]
					service.status = @volatileState[container.serviceId]
				apps[appId].services.push(service)

			# There may be services that are being installed or downloaded which still
			# don't have a running container, so we make them part of the reported current state
			_.forEach @volatileState, (serviceState) ->
				appId = serviceState.appId
				apps[appId] ?= { appId }
				apps[appId].buildId ?= null
				apps[appId].services ?= []
				service = _.pick(serviceState, [ 'status', 'serviceId' ])
				service.containerId = null
				apps[appId].services.push(service)

			# We return an array of the apps, not an object
			return _.values(apps)

	getDependentState: =>
		@proxyvisor.getCurrentStates()

	_buildApps: (containers, networks, volumes) ->
		apps = _.keyBy(_.map(_.uniq(_.map(containers, 'appId')), (appId) -> { appId }), 'appId')

		# We iterate over the current running containers and add them to the current state
		# of the app they belong to.
		_.forEach containers, (container) ->
			appId = container.appId
			apps[appId].services ?= []
			service = _.omit(container, 'status')
			apps[appId].services.push(service)

		_.forEach networks, (network) ->
			appId = network.appId
			apps[appId] ?= { appId }
			apps[appId].networks ?= {}
			apps[appId].networks[network.name] = network.config

		_.forEach volumes, (volume) ->
			appId = volume.appId
			apps[appId] ?= { appId }
			apps[appId].volumes ?= {}
			apps[appId].volumes[volume.name] = volume.config

		# We return the apps as an array
		return _.values(apps)

	getCurrentForComparison: =>
		Promise.join(
			@containers.getAll()
			@networks.getAll()
			@volumes.getAll()
			(containers, networks, volumes) =>
				# We return the apps as an array
				return @_buildApps(containers, networks, volumes)
		)

	getCurrentApp: (appId) =>
		Promise.join(
			@containers.getAllByAppId(appId)
			@networks.getAllByAppId()
			@volumes.getAllByAppId()
			(containers, networks, volumes) =>
				# We return the apps as an array
				return @_buildApps(containers, networks, volumes)[0]
		)

	getTargetApp: (appId) =>
		Promise.join(
			@db.models('app').where({ appId }).select()
			@config.get('extendedEnvOptions')
			([ app ], opts) ->
				return if !app?
				appDBToStateFn = conversions.appDBToStateAsync(opts, @images)
				return appDBToStateFn(app)
		)

	# Compares current and target services and returns a list of service pairs to be updated/removed/installed.
	# The returned list is an array of objects where the "current" and "target" properties define the update pair, and either can be null
	# (in the case of an install or removal).
	compareServicesForUpdate: (currentServices, targetServices) ->
		Promise.try =>
			removePairs = []
			installPairs = []
			updatePairs = []
			targetServiceIds = _.map(targetServices, 'serviceId')
			currentServiceIds = _.uniq(_.map(currentServices, 'serviceId'))

			toBeRemoved = _.difference(currentServiceIds, targetServiceIds)
			_.forEach toBeRemoved, (serviceId) ->
				servicesToRemove = _.filter(currentServices, (s) -> s.serviceId == serviceId)
				_.map servicesToRemove, (service) ->
					removePairs.push({
						current: service
						target: null
						serviceId
					})

			toBeInstalled = _.difference(targetServiceIds, currentServiceIds)
			_.forEach toBeInstalled, (serviceId) ->
				servicesToInstall = _.filter(targetServices, (s) -> s.serviceId == serviceId)
				_.map servicesToInstall, (service) ->
					installPairs.push({
						current: null
						target: service
						serviceId
					})

			toBeMaybeUpdated = _.intersection(targetServiceIds, currentServiceIds)
			currentServicesPerId = {}
			targetServicesPerId = {}
			_.forEach toBeMaybeUpdated, (serviceId) ->
				currentServiceContainers = _.filter currentServices, (service) ->
					return service.serviceId == serviceId
				targetServicesForId = _.filter targetServices, (service) ->
					return service.serviceId == serviceId
				throw new Error("Target state includes multiple services with serviceId #{serviceId}") if targetServicesForId.length > 1
				targetServicesPerId[serviceId] = targetServicesForId[0]
				if currentServiceContainers.length > 1
					currentServicesPerId[serviceId] = _.maxBy(currentServiceContainers, 'createdAt')
					# All but the latest container for this service are spurious and should be removed
					_.forEach _.without(currentServiceContainers, currentServicesPerId[serviceId]), (service) ->
						removePairs.push({
							current: service
							target: null
							serviceId
							isSpurious: true
						})
				else
					currentServicesPerId[serviceId] = currentServiceContainers[0]

			Promise.filter toBeMaybeUpdated, (serviceId) =>
				return @containers.needsUpdate(currentServicesPerId[serviceId], targetServicesPerId[serviceId])
			.map (serviceId) =>
				@containers.onlyNeedsRunningStateChange(currentServicesPerId[serviceId], targetServicesPerId[serviceId])
				.then (onlyStartOrStop) ->
					updatePairs.push({
						current: currentServicesPerId[serviceId]
						target: targetServicesPerId[serviceId]
						isRunningStateChange: onlyStartOrStop
					})
			.then ->
				return { removePairs, installPairs, updatePairs }

	compareNetworksOrVolumesForUpdate: (model, { current, target }, appId) ->
		Promise.try ->
			outputPairs = []
			currentNames = _.keys(current)
			targetNames = _.keys(target)
			toBeRemoved = _.difference(currentNames, targetNames)
			_.forEach toBeRemoved, (name) ->
				outputPairs.push({
					current: {
						name
						appId
						config: current[name]
					}
					target: null
				})
			toBeInstalled = _.difference(targetNames, currentNames)
			_.forEach toBeInstalled, (name) ->
				outputPairs.push({
					current: null
					target: {
						name
						appId
						config: target[name]
					}
				})
			toBeUpdated = _.filter _.intersection(targetNames, currentNames), (name) ->
				!model.isEqual(current[name], target[name])
			_.forEach toBeUpdated, (name) ->
				outputPairs.push({
					current: {
						name
						appId
						config: current[name]
					}
					target: {
						name
						appId
						config: target[name]
					}
				})
			return outputPairs

	hasCurrentNetworksOrVolumes: (service, networkPairs, volumePairs) ->
		hasNetwork = _.some networkPairs, (pair) ->
			pair.current.name == service.network_mode
		return true if hasNetwork
		hasVolume = _.some service.volumes, (volume) ->
			name = _.split(volume, ':')[0]
			_.some volumePairs, (pair) ->
				pair.current.name == name
		return true if hasVolume
		return false

	# TODO: account for volumes-from, networks-from, links, etc
	# TODO: support networks instead of only network_mode
	_dependenciesMetForServiceStart: (target, networkPairs, volumePairs, pendingPairs, stepsInProgress) ->
		# for dependsOn, check no install or update pairs have that service
		dependencyUnmet = _.some target.dependsOn ? [], (dependency) ->
			_.find(pendingPairs, (pair) -> pair.target?.serviceName == dependency)? or _.find(stepsInProgress, (step) -> step.target?.serviceName == dependency)?
		return false if dependencyUnmet
		# for networks and volumes, check no network pairs have that volume name
		if _.find(networkPairs, (pair) -> pair.target.name == target.network_mode)?
			return false
		if _.find(stepsInProgress, (step) -> step.model == 'network' and step.target.name == target.network_mode)?
			return false
		volumeUnmet = _.some target.volumes, (volumeDefinition) ->
			sourceName = volumeDefinition.split(':')[0]
			_.find(volumePairs, (pair) -> pair.target.name == sourceName)? or _.find(stepsInProgress, (step) -> step.model == 'volume' and step.target.name == sourceName)?
		return !volumeUnmet

	_nextStepsForNetworkOrVolume: ({ current, target }, currentApp, changingPairs, dependencyComparisonFn, force, model) ->
		# Check none of the currentApp.services use this network or volume
		if current?
			dependencies = _.filter currentApp.services, (service) ->
				dependencyComparisonFn(service, current)
			if _.isEmpty(dependencies)
				return [{
					action: 'removeNetworkOrVolume'
					model
					current
				}]
			else
				# If the current update doesn't require killing the services that use this network/volume,
				# we have to kill them before removing the network/volume (e.g. when we're only updating the network config)
				steps = []
				_.forEach dependencies, (dependency) ->
					if !_.some(changingPairs, (pair) -> pair.serviceId == dependency.serviceId)
						steps.push({
							action: 'kill'
							serviceId: dependency.serviceId
							current: dependency
							options:
								force: Boolean(force)
						})
				return steps
		else if target?
			return [
				{
					action: 'createNetworkOrVolume'
					model
					target
				}
			]

	_nextStepsForNetwork: ({ current, target }, currentApp, changingPairs, force) =>
		dependencyComparisonFn = (service, current) ->
			service.network_mode == current.name
		@_nextStepsForNetworkOrVolume({ current, target }, currentApp, changingPairs, dependencyComparisonFn, force, 'network')

	_nextStepsForVolume: ({ current, target }, currentApp, changingPairs, force) ->
		# Check none of the currentApp.services use this network or volume
		dependencyComparisonFn = (service, current) ->
			_.some service.volumes, (volumeDefinition) ->
				sourceName = volumeDefinition.split(':')[0]
				sourceName == current.name
		@_nextStepsForNetworkOrVolume({ current, target }, currentApp, changingPairs, dependencyComparisonFn, force, 'volume')

	_stopOrStartStep: (current, target, force) ->
		if target.running
			return {
				action: 'start'
				serviceId: target.serviceId
				current
				target
			}
		else
			return {
				action: 'stop'
				serviceId: target.serviceId
				current
				target
				options:
					force: Boolean(force)
			}

	_fetchOrStartStep: (current, target, needsDownload, fetchOpts, dependenciesMetFn) ->
		if needsDownload
			return {
				action: 'fetch'
				serviceId: target.serviceId
				current
				target
				options: fetchOpts
			}
		else if dependenciesMetFn()
			return {
				action: 'start'
				serviceId: target.serviceId
				current
				target
			}
		else
			return null

	_strategySteps: {
		'download-then-kill': (current, target, force, needsDownload, fetchOpts, dependenciesMetFn) ->
			if needsDownload
				return {
					action: 'fetch'
					serviceId: target.serviceId
					current
					target
					options: fetchOpts
				}
			else if dependenciesMetFn()
				# We only kill when dependencies are already met, so that we minimize downtime
				return {
					action: 'kill'
					serviceId: target.serviceId
					current
					target
					options:
						removeImage: false
						force: Boolean(force)
				}
			else
				return null
		'kill-then-download': (current, target, force, needsDownload, fetchOpts, dependenciesMetFn) ->
			return {
				action: 'kill'
				serviceId: target.serviceId
				current
				target
				options:
					removeImage: false
					force: Boolean(force)
			}
		'delete-then-download': (current, target, force, needsDownload, fetchOpts, dependenciesMetFn) ->
			return {
				action: 'kill'
				serviceId: target.serviceId
				current
				target
				options:
					removeImage: true
					force: Boolean(force)
			}
		'hand-over': (current, target, force, needsDownload, fetchOpts, dependenciesMetFn, timeout) ->
			if needsDownload
				return {
					action: 'fetch'
					serviceId: target.serviceId
					current
					target
					options: fetchOpts
				}
			else if dependenciesMetFn()
				return {
					action: 'handover'
					serviceId: target.serviceId
					current
					target
					options:
						timeout: timeout
						force: Boolean(force)
				}
			else
				return null
	}

	_nextStepForService: ({ current, target, isRunningStateChange = false }, updateContext, fetchOpts) ->
		{ networkPairs, volumePairs, installPairs, updatePairs, targetApp, stepsInProgress, availableImages } = updateContext
		if _.find(stepsInProgress, (step) -> step.serviceId == target.serviceId)?
			# There is already a step in progress for this service, so we wait
			return null
		dependenciesMet = =>
			@_dependenciesMetForServiceStart(target, networkPairs, volumePairs, installPairs.concat(updatePairs), stepsInProgress)

		needsDownload = !_.some availableImages, (image) ->
			_.includes(image.NormalisedRepoTags, target.image)
		if isRunningStateChange
			# We're only stopping/starting it
			return @_stopOrStartStep(current, target, targetApp.config['RESIN_SUPERVISOR_OVERRIDE_LOCK'])
		else if !current?
			# Either this is a new service, or the current one has already been killed
			return @_fetchOrStartStep(current, target, needsDownload, fetchOpts, dependenciesMet)
		else
			strategy = checkString(target.labels['io.resin.update.strategy'])
			validStrategies = [ 'download-then-kill', 'kill-then-download', 'delete-then-download', 'hand-over' ]
			strategy = 'download-then-kill' if !_.includes(validStrategies, strategy)
			timeout = checkInt(target.labels['io.resin.update.handover_timeout'])
			return @_strategySteps[strategy](current, target, targetApp.config['RESIN_SUPERVISOR_OVERRIDE_LOCK'], needsDownload, fetchOpts, dependenciesMet, timeout)

	_nextStepsForAppUpdate: (currentApp, targetApp, availableImages = [], stepsInProgress = []) =>
		emptyApp = { services: [], volumes: {}, networks: {}, config: {} }
		if !targetApp?
			targetApp = emptyApp
		if !currentApp?
			currentApp = emptyApp
		appId = targetApp.appId ? currentApp.appId
		fetchOpts = {
			delta: checkTruthy(targetApp.config['RESIN_SUPERVISOR_DELTA']) ? false
			deltaRequestTimeout: checkInt(targetApp.config['RESIN_SUPERVISOR_DELTA_REQUEST_TIMEOUT'], positive: true) ? 30 * 60 * 1000
			deltaTotalTimeout: checkInt(targetApp.config['RESIN_SUPERVISOR_DELTA_TOTAL_TIMEOUT'], positive: true) ? 24 * 60 * 60 * 1000
		}
		Promise.join(
			@compareNetworksOrVolumesForUpdate(@networks, { current: currentApp.networks, target: targetApp.networks }, appId)
			@compareNetworksOrVolumesForUpdate(@volumes, { current: currentApp.volumes, target: targetApp.volumes }, appId)
			@compareServicesForUpdate(currentApp.services, targetApp.services)
			(networkPairs, volumePairs, { removePairs, installPairs, updatePairs }) =>
				steps = []
				# All removePairs get a 'kill' action
				_.forEach removePairs, ({ current, isSpurious = false }) ->
					steps.push({
						action: 'kill'
						options:
							removeImage: !isSpurious
							isRemoval: !isSpurious
							force: true
						current
						target: null
						serviceId: current.serviceId
					})
				# next step for install pairs in download - start order, but start requires dependencies, networks and volumes met
				# next step for update pairs in order by update strategy. start requires dependencies, networks and volumes met.
				_.forEach installPairs.concat(updatePairs), (pair) =>
					step = @_nextStepForService(pair, { networkPairs, volumePairs, installPairs, updatePairs, stepsInProgress, availableImages, targetApp }, fetchOpts)
					steps.push(step) if step?
				# next step for network pairs - remove requires services killed, create kill if no pairs or steps affect that service
				_.forEach networkPairs, (pair) =>
					pairSteps = @_nextStepsForNetwork(pair, currentApp, removePairs.concat(updatePairs), targetApp.config['RESIN_SUPERVISOR_OVERRIDE_LOCK'])
					steps = steps.concat(pairSteps) if !_.isEmpty(pairSteps)
				# next step for volume pairs - remove requires services killed, create kill if no pairs or steps affect that service
				_.forEach volumePairs, (pair) =>
					pairSteps = @_nextStepsForVolume(pair, currentApp, removePairs.concat(updatePairs), targetApp.config['RESIN_SUPERVISOR_OVERRIDE_LOCK'])
					steps = steps.concat(pairSteps) if !_.isEmpty(pairSteps)
				return steps
		)

	setTarget: (apps, dependent , trx) =>
		setInTransaction = (trx) =>
			Promise.try =>
				if apps?
					appsForDB = _.map apps, (app) ->
						conversions.appStateToDB(app)
					Promise.map appsForDB, (app) =>
						@db.upsertModel('app', app, { appId: app.appId }, trx)
					.then ->
						trx('app').whereNotIn('appId', _.map(appsForDB, 'appId')).del()
			.then =>
				if dependent?.apps?
					appsForDB = _.map dependent.apps, (app) ->
						conversions.dependentAppStateToDB(app)
					Promise.map appsForDB, (app) =>
						@db.upsertModel('dependentAppTarget', app, { appId: app.appId }, trx)
					.then ->
						trx('dependentAppTarget').whereNotIn('appId', _.map(appsForDB, 'appId')).del()
			.then =>
				if dependent?.devices?
					devicesForDB = _.map dependent.devices, (app) ->
						conversions.dependentDeviceTargetStateToDB(app)
					Promise.map devicesForDB, (device) =>
						@db.upsertModel('dependentDeviceTarget', device, { uuid: device.uuid }, trx)
					.then ->
						trx('dependentDeviceTarget').whereNotIn('uuid', _.map(devicesForDB, 'uuid')).del()
		Promise.try =>
			if trx?
				setInTransaction(trx)
			else
				@db.transaction(setInTransaction)
		.then =>
			@_targetVolatilePerServiceId = {}

	setTargetVolatileForService: (serviceId, target) ->
		@_targetVolatilePerServiceId[serviceId] ?= {}
		_.assign(@_targetVolatilePerServiceId, target)

	getTargetApps: =>
		@config.get('extendedEnvOptions')
		.then (opts) =>
			appDBToStateFn = conversions.appDBToStateAsync(opts, @images)
			Promise.map(@db.models('app').select(), appDBToStateFn)
		.map (app) =>
			if !_.isEmpty(app.services)
				app.services = _.map app.services, (service) =>
					_.merge(service, @_targetVolatilePerServiceId[service.serviceId]) if @_targetVolatilePerServiceId[service.serviceId]
					return service
			return app

	getDependentTargets: =>
		Promise.props({
			apps: @db.models('dependentAppTarget').select().map(conversions.dependentAppDBToState)
			devices: @db.models('dependentDeviceTarget').select().map(conversions.dependentDeviceTargetDBToState)
		})

	_allServiceAndAppIdPairs: (current, target) ->
		currentAppDirs = _.map current.local.apps, (app) ->
			_.map app.services, (service) ->
				return { appId: app.appId, serviceId: service.serviceId }
		targetAppDirs = _.map target.local.apps, (app) ->
			_.map app.services, (service) ->
				return { appId: app.appId, serviceId: service.serviceId }
		return _.union(_.flatten(currentAppDirs), _.flatten(targetAppDirs))

	_staleDirectories: (current, target) ->
		dirs = @_allServiceAndAppIdPairs(current, target)
		dataBase = "#{constants.rootMountPoint}#{constants.dataPath}"
		fs.readdirAsync(dataBase)
		.then (dirContents) ->
			Promise.map dirContents, (appId) ->
				return [] if appId == 'resin-supervisor'
				fs.statAsync("#{dataBase}/#{appId}")
				.then (stat) ->
					return [] if !stat.isDirectory()
					fs.readdirAsync("#{dataBase}/#{appId}/services")
					.then (services) ->
						unused = []
						_.forEach services, (serviceId) ->
							candidate = { appId, serviceId }
							if !_.find(dirs, (d) -> _.isEqual(d, candidate))?
								unused.push(candidate)
						return unused
				.catchReturn([])
		.then(_.flatten)

	_unnecessaryImages: (current, target, available) ->
		# return images that:
		# - are not used in the current state, and
		# - are not going to be used in the target state, and
		# - are not needed for delta source / pull caching or would be used for a service with delete-then-download as strategy
		allImagesForApp = (app) ->
			_.map app.services ? [], (service) ->
				service.image

		currentImages = _.flatten(_.map(current.local?.apps ? [], allImagesForApp))
		targetImages = _.flatten(_.map(target.local?.apps ? [], allImagesForApp))
		availableAndUnused = _.filter available, (image) ->
			!_.some currentImages.concat(targetImages), (imageInUse) ->
				_.includes(image.NormalisedRepoTags, imageInUse)
		imagesToDownload = _.filter targetImages, (imageName) ->
			!_.some available, (availableImage) ->
				_.includes(availableImage.NormalisedRepoTags, imageName)

		deltaSources = _.map imagesToDownload ? [], (imageName) =>
			return @docker.bestDeltaSource(imageName, available)

		_.filter availableAndUnused, (image) ->
			!_.some deltaSources, (deltaSource) ->
				_.includes(image.NormalisedRepoTags, deltaSource)

	_inferNextSteps: (imagesToCleanup, availableImages, current, target, stepsInProgress) =>
		currentByAppId = _.keyBy(current.local.apps ? [], 'appId')
		targetByAppId = _.keyBy(target.local.apps ? [], 'appId')
		nextSteps = []
		if !_.isEmpty(imagesToCleanup)
			nextSteps.push({ action: 'cleanup' })
		imagesToRemove = @_unnecessaryImages(current, target, availableImages)
		_.forEach imagesToRemove, (image) ->
			nextSteps.push({ action: 'removeImage', image })
		@_staleDirectories(current, target)
		.then (staleDirs) ->
			if !_.isEmpty(staleDirs)
				purgeActions = _.map staleDirs, (dir) ->
					return {
						action: 'purge'
						current: dir
						options:
							kill: false
							restart: false
							removeFolder: true
					}
				nextSteps = nextSteps.concat(purgeActions)
		.then =>
			allAppIds = _.union(_.keys(currentByAppId), _.keys(targetByAppId))
			Promise.map allAppIds, (appId) =>
				@_nextStepsForAppUpdate(currentByAppId[appId], targetByAppId[appId], availableImages, stepsInProgress)
				.then (nextStepsForThisApp) ->
					nextSteps = nextSteps.concat(nextStepsForThisApp)
		.then =>
			return @_removeDuplicateSteps(nextSteps, stepsInProgress)

	_removeDuplicateSteps: (nextSteps, stepsInProgress) ->
		withoutProgressDups = _.filter nextSteps, (step) ->
			!_.find(stepsInProgress, (s) -> _.isEqual(s, step))?
		_.uniqWith(withoutProgressDups, _.isEqual)

	_fetchOptions: (target, step) =>
		progressReportFn = (state) =>
			@reportServiceStatus(target.serviceId, state)
		@config.getMany([ 'uuid', 'currentApiKey', 'resinApiEndpoint', 'deltaEndpoint'])
		.then (conf) ->
			return {
				uuid: conf.uuid
				apiKey: conf.currentApiKey
				apiEndpoint: conf.resinApiEndpoint
				deltaEndpoint: conf.deltaEndpoint
				delta: step.options.delta
				deltaRequestTimeout: step.options.deltaRequestTimeout
				deltaTotalTimeout: step.options.deltaTotalTimeout
				progressReportFn
			}


	stopAll: ({ force = false } = {}) =>
		@containers.getAll()
		.map (service) ->
			Promise.using updateLock.lock(service.appId, { force }), =>
				@containers.kill(service, { removeContainer: false })

	# TODO: always force when removing an app - add force to step.options?
	executeStepAction: (step, { force = false } = {}) =>
		if _.includes(@proxyvisor.validActions, step.action)
			return @proxyvisor.applyStep(step)
		if !_.includes(@validActions, step.action)
			return Promise.reject(new Error("Invalid action #{step.action}"))
		if step.options?.force?
			force = force or step.options.force
		actionExecutors =
			stop: =>
				Promise.using updateLock.lock(step.current.appId, { force }), =>
					@containers.kill(step.current, { removeContainer: false })
			kill: =>
				Promise.using updateLock.lock(step.current.appId, { force }), =>
					@containers.kill(step.current)
					.then =>
						@images.remove(step.image) if step.options?.removeImage
					.then =>
						if step.options?.isRemoval
							delete @volatileState[step.current.serviceId] if @volatileState[step.current.serviceId]?
			purge: =>
				appId = step.current.appId
				@logger.logSystemMessage("Purging /data for #{step.current.serviceName ? 'app'}", { appId, service: step.current }, 'Purge /data') if step.options.log
				Promise.using updateLock.lock(step.current.appId, { force }), =>
					Promise.try =>
						@containers.kill(step.current) if step.options.kill
					.then =>
						@containers.purge(step.current, { removeFolder: step.options?.removeFolder })
					.then =>
						@logger.logSystemMessage('Purged /data', { appId, service: step.current }, 'Purge /data success') if step.options.log
						@containers.start(step.current) if step.options.restart
				.catch (err) =>
					@logger.logSystemMessage("Error purging /data: #{err}", { appId, error: err }, 'Purge /data error') if step.options.log
					throw err
			restart: =>
				Promise.using updateLock.lock(step.current.appId, { force }), =>
					Promise.try =>
						@containers.kill(step.current)
					.then =>
						@containers.start(step.target)
			stopAll: =>
				@stopAll({ force })
			start: =>
				@containers.start(step.target)
			handover: =>
				Promise.using updateLock.lock(step.current.appId, { force }), =>
					@containers.handover(step.current, step.target)
			fetch: =>
				@_fetchOptions(step.target, step)
				.then (opts) =>
					@downloadsInProgress += 1
					if @downloadsInProgress == 1
						@globalAppStatus.status = 'Downloading'
						@globalAppStatus.download_progress = 0
						@reportCurrentState(@globalAppStatus)
					@images.fetch(step.target.image, opts)
				.finally =>
					@downloadsInProgress -= 1
					if @downloadsInProgress == 0
						@globalAppStatus.status = 'Idle'
						@globalAppStatus.download_progress = null
						@reportCurrentState(@globalAppStatus)
			removeImage: =>
				@images.remove(step.image)
			cleanup: =>
				@images.cleanup()
			createNetworkOrVolume: =>
				model = if step.model is 'volume' then @volumes else @networks
				model.create(step.target)
			removeNetworkOrVolume: =>
				model = if step.model is 'volume' then @volumes else @networks
				model.remove(step.current)
		actionExecutors[step.action]()

	getRequiredSteps: (currentState, targetState, stepsInProgress) =>
		Promise.join(
			@images.getImagesToCleanup()
			@images.getAll()
			(imagesToCleanup, availableImages) =>
				@_inferNextSteps(imagesToCleanup, availableImages, currentState, targetState, stepsInProgress)
				.then (nextSteps) =>
					@proxyvisor.getRequiredSteps(availableImages, currentState, targetState, nextSteps.concat(stepsInProgress))
					.then (proxyvisorSteps) ->
						return nextSteps.concat(proxyvisorSteps)
		)
