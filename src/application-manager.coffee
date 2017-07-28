Promise = require 'bluebird'
_ = require 'lodash'
TypedError = require 'typed-error'
lockFile = Promise.promisifyAll(require('lockfile'))

constants = require './lib/constants'
process.env.DOCKER_HOST ?= "unix://#{constants.dockerSocket}"
Docker = require './lib/docker-utils'

Containers = require './docker/containers'
Images = require './docker/images'
Networks = require './docker/networks'
Volumes = require './docker/volumes'
Proxyvisor = require './proxyvisor'

ENOENT = (err) -> err.code is 'ENOENT'

tmpLockPath = (app) ->
	appId = app.appId
	return "#{constants.rootMountPoint}/tmp/resin-supervisor/#{appId}/resin-updates.lock"

restartVars = (conf) ->
	return _.pick(conf, [ 'RESIN_DEVICE_RESTART', 'RESIN_RESTART' ])

module.exports = class ApplicationManager
	constructor: ({ @logger, @config, @reportCurrentState, @db, @apiBinder }) ->
		@docker = new Docker()
		@images = new Images({ @docker, @logger, @db, @reportServiceStatus })
		@containers = new Containers({ @docker, @logger, @images, @config, @reportServiceStatus })
		@networks = new Networks({ @docker, @logger })
		@volumes = new Volumes({ @docker, @logger })
		@proxyvisor = new Proxyvisor({ @config, @logger, @db, @docker, @images, @apiBinder, @reportCurrentState })
		@UpdatesLockedError = class UpdatesLockedError extends TypedError
		@volatileState = {}

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

	lockUpdates: (app, { force = false } = {}) ->
		Promise.try ->
			return if !app.appId?
			tmpLockName = tmpLockPath(app)
			@_writeLock(tmpLockName)
			.tap (release) ->
				lockFile.unlockAsync(tmpLockName) if force == true
				lockFile.lockAsync(tmpLockName)
				.catch ENOENT, _.noop
				.catch (err) ->
					release()
					throw new @UpdatesLockedError("Updates are locked: #{err.message}")
			.disposer (release) ->
				Promise.try ->
					lockFile.unlockAsync(tmpLockName)
				.finally ->
					release()

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
			Promise.using @lockUpdates(current.appId, { force }), =>
				@containers.kill(current)
				.then ->
					@containers.purge(current, { removeFolder: true })
		else if !current?
			# Install servicePair.target
			@containers.start(target)
		else
			opts = {
				lock: =>
					@lockUpdates(current.appId, { force })
			}
			# Update service using update strategy
			@containers.update(current, target, opts)

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
					Promise.using @lockUpdates(currentApp, { force }), =>
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

	injectDefaultServiceConfig: (app) ->
		modifiedApp = _.cloneDeep(app)
		modifiedApp.services = []
		Promise.map app.services, (service) ->
			# Extend env vars and push to modifiedApp.services
			_.noop()
		.then ->
			return modifiedApp

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
