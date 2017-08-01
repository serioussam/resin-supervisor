Promise = require 'bluebird'
_ = require 'lodash'
JSONStream = require 'JSONStream'
fs = Promise.promisifyAll(require('fs'))
rimraf = Promise.promisify(require('rimraf'))

logTypes = require '../lib/log-types'
{ checkInt } = require '../lib/validation'
conversions = require '../lib/conversions'
containerConfig = require '../lib/container-config'
constants = require '../lib/constants'

#restartVars = (conf) ->
#	return _.pick(conf, [ 'RESIN_DEVICE_RESTART', 'RESIN_RESTART' ])

module.exports = class Containers
	constructor: ({ @docker, @logger, @images, @reportServiceStatus, @config }) ->
		@containerHasDied = {}

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
		@_killContainer(service.dockerContainerId, service, { removeContainer })
		.then (service) ->
			service.running = false
			return service

	purge: (service, { removeFolder = false } = {}) ->
		path = constants.rootMountPoint + containerConfig.getDataPath(service.appId, service.serviceId)
		path += '/*' if !removeFolder
		rimraf(path)

	getAllByAppId: (appId) =>
		@getAll()
		.filter (service) ->
			service.appId == appId

	stopAllByAppId: (appId) =>
		Promise.map @getAllByAppId(appId), (service) =>
			@kill(service, { removeContainer: false })

	# TO DO: add extended env vars
	create: (service) =>
		@get(service)
		.then ([ container ]) =>
			return container if container?
			@images.get(service.image)
			.then (imageInfo) =>
				conf = conversions.serviceToContainerConfig(service, imageInfo, containerConfig.defaultBinds(service))
				@logger.logSystemEvent(logTypes.installService, { service })
				@reportServiceStatus(service.serviceId, { status: 'Installing' })
				@docker.createContainer(conf)
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
		.then (container) ->
			service.running = true
			service.dockerContainerId = container.Id
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
		.map(conversions.containerToService)

	# Returns a boolean that indicates whether currentService is a valid implementation of target service
	_isEqualExceptForRunningState: (currentService, targetService) =>
		Promise.try =>
			basicProperties = [ 'image', 'buildId', 'containerId', 'networkMode', 'privileged', 'restartPolicy' ]
			basicPropertiesCurrent = _.pick(currentService, basicProperties)
			basicPropertiesTarget = _.pick(targetService, basicProperties)
			if !_.isEqual(basicPropertiesCurrent, basicPropertiesTarget)
				return false

			# So it's the same image, conntainerId, buildId and networkMode.
			# labels, volumes or env may be different, but we need to get information
			# from the image (which must be available since it's a running container)
			@images.get(currentService.image)
			.then (image) ->
				# "Mutation is bad, and it should feel bad" - @petrosagg
				targetServiceCloned = _.cloneDeep(targetService)
				targetServiceCloned.environment = _.assign(conversions.envArrayToObject(image.Config.Env), targetService.environment)
				targetServiceCloned.labels = _.assign(image.Config.Labels, targetService.labels)
				targetServiceCloned.volumes = _.union(_.keys(image.Config.Volumes), targetService.volumes)
				containerAndImageProperties = [ 'labels', 'environment' ]
				# We check that the volumes have the same elements
				if !_.isEmpty(_.difference(targetServiceCloned.volumes, currentService.volumes))
					return false
				return _.isEqual(_.pick(targetServiceCloned, containerAndImageProperties), _.pick(currentService, containerAndImageProperties))

	hasEqualRunningState: (currentService, targetService) ->
		Promise.try ->
			currentService?.running == targetService?.running

	isEqual: (currentService, targetService) =>
		@_isEqualExceptForRunningState(currentService, targetService)
		.then (isEqual) =>
			return false if !isEqual
			@hasEqualRunningState(currentService, targetService)

	needsUpdate: (currentService, targetService) ->
		@isEqual(currentService, targetService)
		.then(_.negate(_.identity))

	onlyNeedsRunningStateChange: (currentService, targetService) =>
		@_isEqualExceptForRunningState(currentService, targetService)
		.then (isEqual) =>
			return false if !isEqual
			@hasEqualRunningState(currentService, targetService)
			.then(_.negate(_.identity))

	# Returns an array with the container(s) matching an service by appId, commit, image and environment
	get: (service) =>
		@getAll()
		.then (services) =>
			return _.filter services, (currentService) =>
				@_isEqualExceptForRunningState(currentService, service)

	getByContainerId: (containerId) =>
		@docker.getContainer(containerId).inspect()
		.then (container) ->
			return conversions.containerToService(container)
		.catchReturn(null)

	waitToKill: (service, timeout) =>
		startTime = Date.now()
		pollInterval = 100
		timeout = checkInt(timeout, positive: true) ? 60000
		checkFileOrTimeout = =>
			fs.statAsync(@killmePath(service))
			.catch (err) ->
				throw err unless (Date.now() - startTime) > timeout
			.then =>
				fs.unlinkAsync(@killmePath(service)).catch(_.noop)
		retryCheck = ->
			checkFileOrTimeout()
			.catch ->
				Promise.delay(pollInterval).then(retryCheck)
		retryCheck()

	killmePath: (service) ->
		return "#{containerConfig.getDataPath(service.appId, service.serviceId)}/resin-kill-me"

	setNoRestart: (service) =>
		@get(service)
		.then ([ cont ]) ->
			@docker.getContainer(cont.dockerContainerId).update(RestartPolicy: {})

	handover: (currentService, targetService) =>
		# We set the running container to not restart so that in case of a poweroff
		# it doesn't come back after boot.
		@setNoRestart(currentService)
		.then =>
			@start(targetService)
		.then =>
			@waitToKill(currentService, targetService.config['RESIN_SUPERVISOR_HANDOVER_TIMEOUT'])
		.then =>
			@kill(currentService)

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

	attachToRunning: =>
		@getAll()
		.map (service) =>
			@logger.attach(@docker, service.dockerContainerId)
