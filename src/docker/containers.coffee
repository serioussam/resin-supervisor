Promise = require 'bluebird'
_ = require 'lodash'
JSONStream = require 'JSONStream'
fs = Promise.promisifyAll(require('fs'))

logTypes = require '../lib/log-types'
osRelease = require '../lib/os-release'
{ checkInt } = require '../lib/validation'
constants = require '../lib/constants'
{ envArrayToObject, containerToService } = require '../lib/conversions'
UpdateStrategies = require '../lib/update-strategies'

validRestartPolicies = [ 'no', 'always', 'on-failure', 'unless-stopped' ]
restartVars = (conf) ->
	return _.pick(conf, [ 'RESIN_DEVICE_RESTART', 'RESIN_RESTART' ])

module.exports = class Containers
	constructor: ({ @docker, @logger, @images, @reportServiceStatus, @config }) ->
		@containerHasDied = {}
		@updateStrategies = new UpdateStrategies()

	killAll: =>
		# Containers haven't been normalized (this is an updated supervisor)
		# so we need to stop and remove them
		Promise.map(@docker.listContainers(), (c) =>
			@docker.getContainer(c).inspect()
			.then (container) =>
				@_killContainer(container.Id, { image: container.Config.Image }, { removeContainer: true })
		)

	_killContainer: (containerId, service = {}, { removeContainer = true }) =>
		@logger.logSystemEvent(logTypes.stopService, { service })
		@reportServiceStatus(service.serviceId, status: 'Stopping') if service.serviceId?
		containerObj = @docker.getContainer(containerId)
		containerObj.stop(t: 10)
		.then ->
			containerObj.remove(v: true) if removeContainer
			return
		# Bluebird throws OperationalError for errors resulting in the normal execution of a promisified function.
		.catch Promise.OperationalError, (err) =>
			# Get the statusCode from the original cause and make sure statusCode its definitely a string for comparison
			# reasons.
			statusCode = '' + err.statusCode
			# 304 means the container was already stopped - so we can just remove it
			if statusCode is '304'
				@logger.logSystemEvent(logTypes.stopServiceNoop, { service })
				if removeContainer
					return containerObj.remove(v: true)
				return
			# 404 means the container doesn't exist, precisely what we want! :D
			if statusCode is '404'
				@logger.logSystemEvent(logTypes.stopRemoveServiceNoop, { service })
				return
			throw err
		.tap =>
			delete @containerHasDied[containerId] if @containerHasDied[containerId]?
		.tap =>
			@logger.logSystemEvent(logTypes.stopServiceSuccess, { service })
		.catch (err) =>
			@logger.logSystemEvent(logTypes.stopServiceError, { service, error: err })
			throw err

	kill: (service, { removeContainer = true } = {}) =>
		Promise.map @get(service), (s) =>
			@_killContainer(s.containerId, service, { removeContainer })

	getAllByAppId: (appId) =>
		@getAll()
		.filter (service) ->
			service.appId == appId

	stopAllByAppId: (appId) =>
		Promise.map @getAllByAppId(appId), (service) =>
			@kill(service, { removeContainer: false })

	create: (service) =>
		@get(service)
		.then ([ container ]) =>
			return container if container?
			@images.get(service.image)
			.then (imageInfo) =>
				containerConfig = conversions.serviceToContainerConfig(service, imageInfo, defaultBinds(service))
				@logger.logSystemEvent(logTypes.installService, { service })
				@reportServiceStatus(service.serviceId, { status: 'Installing' })
				@docker.createContainer(containerConfig)
			.tap =>
				@logger.logSystemEvent(logTypes.installServiceSuccess, { service })
		.catch (err) =>
			@logger.logSystemEvent(logTypes.installServiceError, { service, error: err })
			throw err

	start: (service) =>
		alreadyStarted = false
		@create(service)
		.tap (container) =>
			@logger.logSystemEvent(logTypes.startService, { service })
			@reportServiceStatus(service.serviceId, { status: 'Starting' })
			container.start()
			.catch (err) =>
				statusCode = '' + err.statusCode
				# 304 means the container was already started, precisely what we want :)
				if statusCode is '304'
					alreadyStarted = true
					return

				if statusCode is '500' and err.json.trim().match(/exec format error$/)
					# Provide a friendlier error message for "exec format error"
					@config.get('deviceType')
					.then (deviceType) ->
						throw new Error("Application architecture incompatible with #{deviceType}: exec format error")
				else
					# rethrow the same error
					throw err
			.catch (err) ->
				# If starting the container failed, we remove it so that it doesn't litter
				container.remove(v: true)
				.finally =>
					@logger.logSystemEvent(logTypes.startServiceError, { service, error: err })
					throw err
			.then =>
				@reportServiceStatus(service.serviceId, { buildId: service.buildId })
				@logger.attach(@docker, container.Id)
		.tap =>
			if alreadyStarted
				@logger.logSystemEvent(logTypes.startServiceNoop, { service })
			else
				@logger.logSystemEvent(logTypes.startServiceSuccess, { service })
		.finally =>
			@reportServiceStatus(service.serviceId, { status: 'Idle' })

	# Gets all existing containers that correspond to apps
	getAll: =>
		Promise.map @docker.listContainers(), (container) =>
			@docker.getContainer(container.Id).inspect()
		.then (containers) ->
			return _.filter containers, (container) ->
				labels = container.Config.Labels
				return _.includes(_.keys(labels), 'io.resin.supervised')
		.map(containerToService)

	# Returns a boolean that indicates whether currentService is a valid implementation of target service
	_isEqualExceptForRunningState: (currentService, targetService) =>
		Promise.try =>
			basicProperties = [ 'image', 'buildId', 'containerId', 'networkMode', 'privileged', 'restartPolicy' ]
			basicPropertiesCurrent = _.pick(currentService, basicProperties)
			basicPropertiesTarget = _.pick(targetService, basicProperties)
			if !_.isEqual(basicPropertiesCurrent, basicPropertiesTarget)
				return true

			# So it's the same image, conntainerId, buildId and networkMode.
			# labels, volumes or env may be different, but we need to get information
			# from the image (which must be available since it's a running container)
			@images.get(currentService.image)
			.then (image) ->
				# "Mutation is bad, and it should feel bad" - @petrosagg
				targetServiceCloned = _.cloneDeep(targetService)
				targetServiceCloned.environment = _.assign(envArrayToObject(image.Config.Env), targetService.environment)
				targetServiceCloned.labels = _.assign(image.Config.Labels, targetService.labels)
				targetServiceCloned.volumes = _.union(_.keys(image.Config.Volumes), targetService.volumes)
				containerAndImageProperties = [ 'labels', 'environment' ]
				# We check that the volumes have the same elements
				if !_.isEmpty(_.difference(targetServiceCloned.volumes, currentService.volumes))
					return true
				return !_.isEqual(_.pick(targetServiceCloned, containerAndImageProperties), _.pick(currentService, containerAndImageProperties))

	_hasEqualRunningState: (currentService, targetService) =>

	isEqual: (currentService, targetService) =>
		@_isEqualExceptForRunningState(currentService, targetService)
		.then (isEqual) =>
			return false if !isEqual
			_hasEqualRunningState(currentService, targetService)

	needsRunningStateChange: (currentService, targetService) =>
		@_isEqualExceptForRunningState(currentService, targetService)
		.then (isEqual) =>
			return false if !isEqual
			_hasEqualRunningState(currentService, targetService)
			.then (isEqualRunningState) ->
				return !isEqualRunningState

	# Returns an array with the container(s) matching an service by appId, commit, image and environment
	get: (service) =>
		@getAll()
		.then (services) =>
			return _.filter services, (currentService) =>
				@_isEqualExceptForRunningState(currentService, service)

	getByContainerId: (containerId) =>
		@docker.getContainer(containerId).inspect()
		.then (container) ->
			return containerToService(container)
		.catchReturn(null)

	# starts, stops or restarts a service
	# (only clears container on a restart)
	changeRunningState: (currentService, targetService) =>
		if @needsRestart(currentService, targetService) =>
			@restart(currentService, targetService)
		else
			if targetService.running = false
				@stop(currentService)
			else
				@start(targetService)

	update: (currentService, targetService) =>
		Promise.try =>
			if @isEqual(currentService, targetService)
				return
			else if @needsRunningStateChange(currentService, targetService)
				@changeRunningState(currentService, targetService)
			else
				@updateWithStrategy(currentService, targetService)

	listenToEvents: =>
		@docker.getEvents()
		.then (stream) =>
			stream.on 'error', (err) ->
				console.error('Error on docker events stream:', err, err.stack)
			parser = JSONStream.parse()
			parser.on 'error', (err) ->
				console.error('Error on docker events JSON stream:', err, err.stack)
			parser.on 'data', (data) =>
				if data?.Type? && data.Type == 'container' && data.status in ['die', 'start']
					@getByContainerId(data.id)
					.then (service) =>
						if service?
							if data.status == 'die'
								@logger.logSystemEvent(logTypes.serviceExit, { service })
								@containerHasDied[data.id] = true
							else if data.status == 'start' and @containerHasDied[data.id]
								@logger.logSystemEvent(logTypes.serviceRestart, { service })
								@logger.attach(@docker, data.id)
					.catch (err) ->
						console.error('Error on docker event:', err, err.stack)
			parser.on 'end', =>
				console.error('Docker events stream ended, restarting listener')
				@listenToEvents()
			stream.pipe(parser)
		.catch (err) ->
			console.error('Error listening to events:', err, err.stack)