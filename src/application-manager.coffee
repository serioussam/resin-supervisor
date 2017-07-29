Promise = require 'bluebird'
_ = require 'lodash'

conversions = require './lib/conversions'
constants = require './lib/constants'
process.env.DOCKER_HOST ?= "unix://#{constants.dockerSocket}"

Docker = require './lib/docker-utils'

Containers = require './docker/containers'
Images = require './docker/images'
Networks = require './docker/networks'
Volumes = require './docker/volumes'

Proxyvisor = require './proxyvisor'

class Step
	constructor: ({ @action, @current, @target }) ->

module.exports = class ApplicationManager
	constructor: ({ @logger, @config, @reportCurrentState, @db, @apiBinder }) ->
		@docker = new Docker()
		@images = new Images({ @docker, @logger, @db, @reportServiceStatus })
		@containers = new Containers({ @docker, @logger, @images, @config, @reportServiceStatus })
		@networks = new Networks({ @docker, @logger })
		@volumes = new Volumes({ @docker, @logger })
		@proxyvisor = new Proxyvisor({ @config, @logger, @db, @docker, @images, @apiBinder, @reportCurrentState })
		@volatileState = {}
		@validActions = [ 'kill', 'start', 'stop', 'fetch', 'remove', 'killAll', 'purge', 'cleanup' ].concat(@proxyvisor.validActions)

	reportServiceStatus: (serviceId, updatedStatus) =>
		@volatileState[serviceId] ?= {}
		_.assign(@volatileState[serviceId], updatedStatus)
		# TODO: aggregate download progress into device state download progress
		@reportCurrentState()

	init: =>
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
				# We use the oldest container in an app to define the current buildId
				if !apps[appId].buildId? or container.createdAt < oldestContainer[appId]
					apps[appId].buildId = container.buildId
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

	getCurrentForComparison: =>
		Promise.join(
			@containers.getAll()
			@networks.getAll()
			@volumes.getAll()
			(containers, networks, volumes) ->
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

				# We return the apps as an object indexed by appId
				return apps
		)

	compareAppsForUpdate: (currentApps, targetApps) ->
		targetAppIds = _.map(targetApps, 'appId')
		currentAppIds = _.uniq(_.map(currentApps, 'appId'))

		toBeRemoved = _.difference(currentAppIds, targetAppIds)
		toBeInstalled = _.difference(targetAppIds, currentAppIds)

		toBeMaybeUpdated = _.intersection(targetAppIds, currentAppIds)

		return { toBeRemoved, toBeInstalled, toBeMaybeUpdated }

	serviceShouldBeUpdated: (currentService, targetService) =>
		@containers.matches(currentService, targetService)

	topologicalSort: (servicePairs) ->
		unsortedServices = _.cloneDeep(servicePairs)
		sortedServices = []
		pushService = (service, i) ->
			sortedServices.push(service)
			_.pullAt(unsortedServices, [ i ] )

		# Services that will be removed go first
		for service, i in unsortedServices
			if !service.target?
				pushService(service, i)

		while !_.isEmpty(unsortedServices)
			atLeastOneServiceSorted = false
			for service, i in unsortedServices
				dependenciesFulfilled = _.every service.dependsOn, (dependency) ->
					return _.includes(_.map(sortedServices, (pair) -> pair.target?.serviceName), dependency)
				if _.isEmpty(service.dependsOn) or dependenciesFulfilled
					pushService(service, i)
					atLeastOneServiceSorted = true
			throw new Error('Service graph is cyclical') if !atLeastOneServiceSorted

		return sortedServices

	# Compares current and target services and returns a list of service pairs to be updated/removed/installed.
	# The returned list is an array of objects where the "current" and "target" properties define the update pair, and either can be null
	# (in the case of an install or removal).
	# The list is sorted with services to remove first and then a topological sort to account for dependencies between services
	compareServicesForUpdate: (currentServices, targetServices) ->
		Promise.try =>
			servicePairs = []
			targetServiceIds = _.map(targetServices, 'serviceId')
			currentServiceIds = _.uniq(_.map(currentServices, 'serviceId'))

			toBeRemoved = _.difference(currentServiceIds, targetServiceIds)
			_.forEach toBeRemoved, (serviceId) ->
				servicesToRemove = _.filter(currentServices, (s) -> s.serviceId == serviceId)
				_.map servicesToRemove, (service) ->
					servicePairs.push({
						current: service
						target: null
					})

			toBeInstalled = _.difference(targetServiceIds, currentServiceIds)
			_.forEach toBeInstalled, (serviceId) ->
				servicesToInstall = _.filter(targetServices, (s) -> s.serviceId == serviceId)
				_.map servicesToInstall, (service) ->
					servicePairs.push({
						current: null
						target: service
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
				currentServicesPerId[serviceId] = _.maxBy(currentServiceContainers, 'createdAt')
				if currentServiceContainers.length > 1
					# All but the latest container for this service are spurious and should be removed
					_.forEach _.without(currentServiceContainers, currentServicesPerId[serviceId]), (service) ->
						servicePairs.push({
							current: service
							target: null
						})

			toBeUpdated = Promise.filter toBeMaybeUpdated, (serviceId) =>
				return @containers.isEqual(currentServicesPerId[serviceId], targetServicesPerId[serviceId])

			Promise.map toBeUpdated, (serviceId) ->
				servicePairs.push({
					current: currentServicesPerId[serviceId]
					target: targetServicesPerId[serviceId]
				})
			.then =>
				return @topologicalSort(servicePairs)

	compareNetworksOrVolumesForUpdate: (model, { current, target }) ->
		Promise.try ->
			outputPairs = []
			currentNames = _.keys(current)
			targetNames = _.keys(target)
			toBeRemoved = _.difference(currentNames, targetNames)
			_.forEach toBeRemoved, (name) ->
				outputPairs.push({
					current: current[name]
					target: null
				})
			toBeInstalled = _.difference(targetNames, currentNames)
			_.forEach toBeInstalled, (name) ->
				outputPairs.push({
					current: null
					target: target[name]
				})
			toBeUpdated = _.filter _.intersection(targetNames, currentNames), (name) ->
				!model.isEqual(current[name], target[name])
			_.forEach toBeUpdated, (name) ->
				outputPairs.push({
					current: current[name]
					target: target[name]
				})
			return outputPairs

	getAllImages: (appsObj) ->
		allImages = _.map appsObj, (app) ->
			_.map app.services, 'image'
		_.flatten(allImages)

	# servicePair has current and target service (either may be null)
	executeServiceChange: ({ current, target }, { force }) ->
		if !target?
			# Remove servicePair.current
			Promise.using updateLock.lock(current.appId, { force }), =>
				@containers.kill(current)
				.then ->
					@containers.purge(current, { removeFolder: true })
		else if !current?
			# Install servicePair.target
			@containers.start(target)
		else
			# Update service using update strategy
			@containers.update(current, target)

	executeNetworkOrVolumeChange: (model, { current, target }) ->
		if !target?
			# Remove servicePair.current
			model.remove(current)
		else if !current?
			# Install servicePair.target
			model.create(target)
		else
			model.remove(current)
			.then ->
				model.create(target)

	# Clear the default data paths for app
	_purgeAll: (services) ->
		Promise.mapSeries services, (service) =>
			@containers.purge(service, { removeFolder: true })

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

	compareAndUpdate: (currentApp = { networks: {}, volumes: {}, services: [] }, targetApp, force = false) =>
		isRemoval = false
		if !targetApp?
			targetApp = { networks: {}, volumes: {}, services: [] }
			isRemoval = true
		Promise.join(
			@compareNetworksOrVolumesForUpdate(@networks, { current: currentApp.networks, target: targetApp.networks })
			@compareNetworksOrVolumesForUpdate(@volumes, { current: currentApp.volumes, target: targetApp.volumes })
			(networkPairs, volumePairs) =>
				if !_.isEmpty(networkPairs) or !_.isEmpty(volumePairs)
					Promise.using updateLock.lock(currentApp.appId, { force }), =>
						Promise.map currentApp.services, (service) =>
							@containers.kill(service, { removeContainer: false }) if @hasCurrentNetworksOrVolumes(service, networkPairs, volumePairs)
						.then =>
							Promise.mapSeries networkPairs, (networkPair) =>
								@executeNetworkOrVolumeChange(@networks, networkPair)
							Promise.mapSeries volumePairs, (volumePair) =>
								@executeNetworkOrVolumeChange(@volumes, volumePair)
						.then =>
							@getAllByAppId(currentApp.appId)
				else
					return currentApp.services
		)
		.then (currentServices) =>
			@compareServicesForUpdate(currentServices, targetApp.services)
			.then (servicePairBuckets) =>
				# TODO: improve iteration so that it advances to the enxt service as soon as its dependencies are met
				Promise.mapSeries servicePairBuckets, (bucket) =>
					Promise.map (servicePair) =>
						@executeServiceChange(servicePair)
			.then =>
				if isRemoval
					@_purgeAll(currentServices)
					.then =>
						_.forEach currentAppUpdated.services, (service) =>
							@volatileState[service.serviceId] = null

	nextStepsForAppUpdate: (current[appId], target[appId], availableImages, stepsInProgress) =>


	injectDefaultServiceConfig: (app) ->
		modifiedApp = _.cloneDeep(app)
		modifiedApp.services = []
		Promise.map app.services, (service) ->
			# Extend env vars and push to modifiedApp.services
			_.noop()
		.then ->
			return modifiedApp

	pairsWithDependenciesFulfilled: (pairs, completed) =>
		_.filter pairs, (pair) ->
			_.isEmpty(pair.dependencies) or _.all(pair.dependencies, (dep) -> _.includes(completed, dep) )
	
	applyTarget: (targetAppsArray, { force = false } = {}) =>
		Promise.join(
			@getCurrentForComparison()
			Promise.map targetAppsArray, (app) =>
				@injectDefaultServiceConfig(app)
			.then (appsArray) ->
				_.keyBy(appsArray, 'appId')
			(currentApps, targetApps) =>
				@images.cleanup(@getAllImages(currentApps).concat(@getAllImages(targetApps)))
				.then =>
					{ toBeRemoved, toBeInstalled, toBeMaybeUpdated } = @compareAppsForUpdate(currentApps, targetApps)
					Promise.mapSeries toBeRemoved, (appId) =>
						@compareAndUpdate(currentApps[appId], null)
					.then =>
						Promise.mapSeries toBeInstalled, (appId) =>
							@compareAndUpdate(null, targetApps[appId], force)
					.then =>
						Promise.mapSeries toBeMaybeUpdated, (appId) =>
							@compareAndUpdate(currentApps[appId], targetApps[appId], force)
				.then =>
					@images.cleanup(@getAllImages(targetApps))
		)

	setTarget: ({ apps, dependent }, trx) =>
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
		if _.isFunction(trx)
			setInTransaction(trx)
		else
			@db.transaction(setInTransaction)

	getTargetApps: =>
		@config.get('extendedEnvOptions')
		.then (opts) =>
			@db.models('app').select().map(conversions.appDBToState(opts))

	getDependentTargets: =>
		Promise.props({
			apps: @db.models('dependentAppTarget').select().map(conversions.dependentAppDBToState)
			devices: @db.models('dependentDeviceTarget').select().map(conversions.dependentDeviceTargetDBToState)
		})

	canApplyStep: (step, nextSteps, currentImages, current, target) =>
		switch step.action
			when 'fetchImage'
				return !@_downloadInProgress(step.image) and !@_needsKillOrDeleteBeforeDownload(step.image, nextSteps, current, target)
			when 'removeImage'
				return !@_downloadInProgress(step.image) and _.isEmpty(@containers.getByImage(step.image)) and 
			when 'startService'
				return @imageAvailable(step.target.image, currentImages) and @dependenciesFulfilled(current, target)
			when 'stopService'
			when 'removeService'
			when 'cleanup'
				# Cleanup must be the last thing we're doing
				nextSteps.length == 1

	_downloadInProgress: (image) =>
	_needsKillOrDeleteBeforeDownload: (image, nextSteps) =>
		# nextSteps or currentSteps includes a kill of
		# a service that uses this image and with a target that
		# has a kill-then-download or delete-then-download strategy

	_allServiceAndAppIdPairs: (current, target) ->
		currentAppDirs = _.map current, (app) ->
			_.map app.services, (service) ->
				return { appId: app.appId, serviceId: service.serviceId }
		targetAppDirs = _.map current, (app) ->
			_.map app.services, (service) ->
				return { appId: app.appId, serviceId: service.serviceId }
		return _.union(_.flatten(currentAppDirs), _.flatten(targetAppDirs))

	_staleDirectories: (current, target) ->
		dirs = @_allServiceAndAppIdPairs(current, target)
		dataBase = "#{constants.rootMountPoint}#{constants.dataPath}"
		fs.readdirAsync(dataBase)
		.map (appId) ->
			return [] if appId == 'resin-supervisor'
			fs.statAsync("#{dataBase}#{appId}")
			.then (stat) ->
				return [] if !stat.isDirectory()
				fs.readdirAsync("#{{dataBase}#{appId}/services")
				.then (services) ->
					unused = []
					_.forEach services, (serviceId) ->
						candidate = { appId, serviceId }
						if !_.find(dirs, (d) -> _.isEqual(d, candidate))?
							unused.push(candidate)
					return unused
				.catchReturn([])
		.then(_.flatten)

	_inferNextSteps: (imagesToCleanup, availableImages, current, target, stepsInProgress) =>
		nextSteps = []
		if !_.isEmpty(imagesToCleanup)
			nextSteps.push({ action: 'cleanup' })

		imagesToRemove = @_unnecessaryImages(current, target, availableImages)
		_.forEach imagesToRemove, (image) ->
			nextSteps.push({ action: 'remove', image })

		@_staleDirectories(current, target)
		.then (staleDirs) ->
			if !_.isEmpty(staleDirs)
				purgeActions = _.map staleDirs, (dir) ->
					return {
						action: 'purge'
						current: dir
						options:
							kill: false
							removeFolder: true
					}
				nextSteps = nextSteps.concat(purgeActions)
		.then =>
			allAppIds = _.union(_.keys(current), _.keys(target))
			Promise.map allAppIds, (appId) =>
				@nextStepsForAppUpdate(current[appId], target[appId], availableImages, stepsInProgress)
				.then (nextStepsForThisApp) ->
					nextSteps = nextSteps.concat(nextStepsForThisApp)
			.then ->
				return _.filter nextSteps, (step) ->
					!_.find(stepsInProgress, (s) -> _.isEqual(s,step))?

	_fetchOptions: (service) =>
		progressReportFn = (state) =>
			@reportServiceStatus(service.serviceId, state)
		@config.getMany([ 'uuid', 'currentApiKey', 'resinApiEndpoint', 'deltaEndpoint'])
		.then (conf) ->
			return {
				uuid: conf.uuid
				apiKey: conf.currentApiKey
				apiEndpoint: conf.resinApiEndpoint
				deltaEndpoint: conf.deltaEndpoint
				delta: checkTruthy(service.config['RESIN_SUPERVISOR_DELTA'])
				deltaRequestTimeout: checkInt(service.config['RESIN_SUPERVISOR_DELTA_REQUEST_TIMEOUT'], positive: true) ? 30 * 60 * 1000
				deltaTotalTimeout: checkInt(service.config['RESIN_SUPERVISOR_DELTA_TOTAL_TIMEOUT'], positive: true) ? 24 * 60 * 60 * 1000
				progressReportFn
			}

	applyStep: (step, { force = false, currentState = {}, targetState = {}, stepsInProgress = [] } = {}) =>
		if _.includes(@proxyvisor.validActions, step.action)
			return @proxyvisor.applyStep(step)
		isRemoval = !targetState[step.current?.appId]?
		force = force or isRemoval or checkTruthy(targetState[step.current?.appId]?.config?['RESIN_SUPERVISOR_OVERRIDE_LOCK'])
		switch step.action
			when 'stop'
				Promise.using updateLock.lock(step.current.appId, { force }), => 
					@containers.kill(step.current, { removeContainer: false })
			when 'kill'
				Promise.using updateLock.lock(step.current.appId, { force }), => 
					@containers.kill(step.current)
					.then ->
						if isRemoval
							delete @volatileState[step.current.serviceId]
			when 'purge'
				Promise.using updateLock.lock(step.current.appId, { force }), =>
					Promise.try =>
						@containers.kill(step.current) if step.options.kill
					.then =>
						@containers.purge(step.current, { removeFolder: step.options.removeFolder })
			when 'stopAll'
				@containers.getAll()
				.map (service) ->
					matchingTarget = _.find(targetState.apps, (app) -> app.appId == service.appId)
					if matchingTarget?
						force = force or checkTruthy(matchingTarget.config['RESIN_SUPERVISOR_OVERRIDE_LOCK'])
					Promise.using updateLock.lock(service.appId, { force })
						@containers.kill(service, { removeContainer: false })
			when 'start'
				@containers.start(step.target)
			when 'handover'
				Promise.using updateLock.lock(step.current.appId, { force }), => 
					@containers.handover(step.current, step.target)
			when 'fetch'
				@fetchOptions(step.service)
				.then (opts) =>
					@images.fetch(step.image, opts)
			when 'remove'
				@images.remove(step.image)
			when 'cleanup'
				@images.cleanup()

	getRequiredSteps: (currentState, targetState, stepsInProgress) =>
		Promise.join(
			@images.getImagesToCleanup()
			@images.getAll()
			.then (imagesToCleanup, availableImages) =>
				@_inferNextSteps(imagesToCleanup, availableImages, currentState, targetState, stepsInProgress)
		)